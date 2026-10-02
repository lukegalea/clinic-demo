defmodule ClinicDemo.EvidenceSpike.Wire do
  @moduledoc """
  Labelled record/replay in front of ReqLLM (DEC-REPLAY).

  `ash_ai`'s `prompt/2` and `evaluate/2` both take a `req_llm:` option naming
  the module they call `generate_object/4` and `evaluate/4` on. This module is
  that seam. It is **not** an HTTP client. In `:live` and `:record` modes, it
  delegates to ReqLLM unchanged. In `:replay` mode, it answers from a fixture
  set. In `:stub` mode, it answers from `ClinicDemo.EvidenceSpike.Stub`.

  The mode and the fixture set come from application config
  (`config :clinic_demo, ClinicDemo.EvidenceSpike.Wire, mode: ..., set: ...`),
  which the `mix clin34.spike` task sets from its flags.

  ## Fixtures

  A set is one JSONL file under `priv/evidence_spike/fixtures/`. Each line
  holds one exchange: the request key, the model label, the `provenance`
  (`"recorded"` from a live model, or `"stub"` from the synthetic stub), the
  reply object, the usage and the latency. Replay never mixes provenances
  silently, because every observation the runner records carries the
  provenance of the exchange that produced it.

  The request key hashes the operation, the model label, and the exact
  schema or questions and prompt sent. A changed prompt or schema is therefore
  a fixture miss, which replay reports as an error rather than answering from
  a stale reply.

  **Nothing secret is recorded.** The model label is `provider:model-id`
  only. Base URLs and API keys, which live in the tuple model spec's options,
  are never written.

  Every exchange also emits `[:clinic_demo, :evidence_spike, :wire]`
  telemetry, carrying the raw reply. The runner uses that telemetry to keep
  the raw reply on the ledger row, even when the cast then fails.
  """

  alias ClinicDemo.EvidenceSpike.Stub

  @fixture_dir "priv/evidence_spike/fixtures"

  @doc "Same contract as `ReqLLM.generate_object/4`."
  def generate_object(model, context, schema, opts) do
    payload = %{op: "generate_object", messages: messages(context), schema: schema}

    exchange(model, payload, fn ->
      {model, opts} = lift_call_opts(model, opts)
      ReqLLM.generate_object(model, context, schema, opts)
    end)
  end

  @doc "Same contract as `ReqLLM.evaluate/4`."
  def evaluate(model, state, questions, opts) do
    payload = %{op: "evaluate", state: state, questions: questions}

    exchange(model, payload, fn ->
      {model, opts} = lift_call_opts(model, opts)
      ReqLLM.evaluate(model, state, questions, opts)
    end)
  end

  # Options ReqLLM reads only from the call, not from a tuple spec's defaults:
  # for generate_object it warns and drops `:api_key`, and it reads
  # `:openai_structured_output_mode` and `:reasoning_effort` only as top-level
  # call options. Moving them into the call options works for both operations.
  @call_opts [:api_key, :openai_structured_output_mode, :reasoning_effort]

  defp lift_call_opts({provider, id, tuple_opts}, opts) do
    {lifted, rest} = Keyword.split(tuple_opts, @call_opts)
    {{provider, id, rest}, Keyword.merge(lifted, opts)}
  end

  defp lift_call_opts(model, opts), do: {model, opts}

  @doc "The label a model spec is recorded under. Never includes options."
  def model_label({provider, id, _opts}), do: "#{provider}:#{id}"
  def model_label({provider, id}), do: "#{provider}:#{id}"
  def model_label(spec) when is_binary(spec), do: spec
  def model_label(other), do: inspect(other)

  @doc "The stable key for a request payload."
  def key(model, payload) do
    canonical = canonical(Map.put(payload, :model, model_label(model)))
    :crypto.hash(:sha256, JSON.encode!(canonical)) |> Base.encode16(case: :lower)
  end

  @doc "The hash of a JSON schema, as recorded on ledger rows (law 6)."
  def schema_hash(schema),
    do: :crypto.hash(:sha256, JSON.encode!(canonical(schema))) |> Base.encode16(case: :lower)

  @doc "Path of a fixture set."
  def fixture_path(set), do: Path.join(@fixture_dir, "#{set}.jsonl")

  defp config, do: Application.get_env(:clinic_demo, __MODULE__, [])
  defp mode, do: Keyword.get(config(), :mode, :replay)
  defp set, do: Keyword.get(config(), :set, "stub")

  defp exchange(model, payload, live_fun) do
    key = key(model, payload)
    started = System.monotonic_time(:millisecond)

    result =
      case mode() do
        :live -> live(live_fun, model, key, started, false)
        :record -> live(live_fun, model, key, started, true)
        :replay -> replay(key)
        :stub -> stub(model, payload, key, started)
      end

    case result do
      {:ok, entry} ->
        emit(entry)
        {:ok, %{object: entry["object"], usage: entry["usage"], model: entry["model"]}}

      {:error, error} ->
        :telemetry.execute([:clinic_demo, :evidence_spike, :wire], %{latency_ms: 0}, %{
          key: key,
          error: error,
          model: model_label(model)
        })

        {:error, error}
    end
  end

  defp live(live_fun, model, key, started, record?) do
    case live_fun.() do
      {:ok, response} ->
        entry =
          entry(key, model, "recorded", response.object, usage(response), elapsed(started))

        if record?, do: append(entry)
        {:ok, entry}

      {:error, error} ->
        {:error, error}
    end
  end

  defp stub(model, payload, key, started) do
    object = Stub.answer(model_label(model), payload)
    entry = entry(key, model, "stub", object, nil, elapsed(started))
    if Keyword.get(config(), :record_stub?, false), do: append(entry)
    {:ok, entry}
  end

  defp replay(key) do
    case Map.fetch(load(set()), key) do
      {:ok, entry} ->
        {:ok, entry}

      :error ->
        {:error,
         "no fixture for request #{key} in set #{inspect(set())} (#{fixture_path(set())}); " <>
           "the prompt, schema or model changed since it was recorded — re-record it"}
    end
  end

  defp entry(key, model, provenance, object, usage, latency_ms) do
    %{
      "key" => key,
      "model" => model_label(model),
      "provenance" => provenance,
      "object" => object,
      "usage" => usage,
      "latency_ms" => latency_ms,
      "recorded_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }
  end

  defp emit(entry) do
    :telemetry.execute(
      [:clinic_demo, :evidence_spike, :wire],
      %{latency_ms: entry["latency_ms"]},
      %{
        key: entry["key"],
        object: entry["object"],
        model: entry["model"],
        provenance: entry["provenance"],
        usage: entry["usage"]
      }
    )
  end

  defp usage(%{usage: usage}) when is_map(usage),
    do: Map.new(usage, fn {k, v} -> {to_string(k), v} end)

  defp usage(_), do: nil

  defp elapsed(started), do: System.monotonic_time(:millisecond) - started

  defp append(entry) do
    path = fixture_path(set())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(entry) <> "\n", [:append])
    :persistent_term.erase({__MODULE__, set()})
  end

  @doc false
  def load(set) do
    case :persistent_term.get({__MODULE__, set}, nil) do
      nil ->
        entries = read_set(set)
        :persistent_term.put({__MODULE__, set}, entries)
        entries

      entries ->
        entries
    end
  end

  defp read_set(set) do
    case File.read(fixture_path(set)) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Map.new(&decode_entry/1)
      {:error, _} -> %{}
    end
  end

  defp decode_entry(line) do
    entry = JSON.decode!(line)
    {entry["key"], entry}
  end

  @doc false
  # The prompt as it is keyed: role and text per message.
  def messages(%ReqLLM.Context{messages: messages}), do: Enum.map(messages, &message/1)
  def messages(other), do: inspect(other)

  defp message(%{role: role, content: content}) when is_binary(content),
    do: %{role: to_string(role), text: content}

  defp message(%{role: role, content: parts}) when is_list(parts),
    do: %{role: to_string(role), text: Enum.map_join(parts, "", &part_text/1)}

  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(_), do: ""

  # Key order must not change the hash: sort map keys all the way down.
  defp canonical(%_{} = struct), do: struct |> Map.from_struct() |> canonical()

  defp canonical(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> [to_string(k), canonical(v)] end)
    |> Enum.sort()
  end

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp canonical(other), do: other
end
