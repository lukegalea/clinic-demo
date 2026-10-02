defmodule ClinicDemo.SystemOneSpike.Models do
  @moduledoc """
  Resolves the spike's model specs. This is the only place the spike reads
  endpoint details.

  ReqLLM does not read `TYPESAFE_BASE_URL`, so Ollaya is reached with a **tuple
  model spec**: `{:typesafe, model_id, base_url: ..., api_key: ...}`. Ollaya
  speaks the TypeSafe wire (`POST /v1/systemone`) on port 11435.

  The action resolves its spec from the action input's context, through
  `for_input/2`:

      context: %{system_one_spike: %{spec: :laya, transport: :live}}

  `transport` picks how the request leaves the process:

    * `:live` — straight to Ollaya. Nothing is written.
    * `{:record, set}` — to Ollaya through `ClinicDemo.SystemOneSpike.Transport`,
      which writes each exchange to the fixture set.
    * `{:replay, set}` — answered from the fixture set. No network.
    * `:stub` — answered by `ClinicDemo.SystemOneSpike.Stub`. No network.
    * `{:stub_record, set}` — as `:stub`, and the exchanges are written to the
      set with provenance `"stub"`. This is how the committed stub set is made.
    * `{:plug, plug}` — any Req plug. Tests use it to inspect the request.

  In every mode the request is built and the reply decoded by ReqLLM's own
  TypeSafe provider. Only the bytes on the wire are substituted.

  ## Environment

  The operator writes these to `~/.config/system-one/endpoints.env`.
  `scripts/spike0-live.sh` sources that file. The mix task never reads it.

  | Variable | Meaning | Default |
  |---|---|---|
  | `OLLAYA_BASE_URL` | CPU host's base URL, **without** `/v1` (ReqLLM appends `/v1/systemone`) | none; required for `:live` and `:record` |
  | `S1_OLLAYA_GPU_BASE_URL` | GPU host's base URL, same shape as `OLLAYA_BASE_URL` | required when a run model routes to `GPU` |
  | `S1_OLLAYA_ROUTES` | Per-model host map, comma-separated `model=CPU\\|GPU`, e.g. `nli:latest=CPU,winnow:e4b=GPU` | unset: every model uses `OLLAYA_BASE_URL` |
  | `OLLAYA_API_KEY` | Ollaya's key, if the server wants one | `"local"` |
  | `S1_SPIKE_RECEIVE_TIMEOUT_MS` | Per-request timeout. A cold load can exceed 10 s | `60000` |

  Nothing here is recorded. Fixtures carry the model id only.
  """

  alias ClinicDemo.SystemOneSpike.Transport

  @specs %{
    laya: "laya:typed-decisions",
    winnow: "winnow:e4b"
  }

  @doc "The spec names the spike knows, in run order."
  def names, do: [:laya, :winnow]

  @doc "The Ollaya model id behind a spec name."
  def model_id(name), do: Map.fetch!(@specs, name)

  @doc "An allow-listed spec name from a string (the value comes from a CLI flag)."
  def parse_name("laya"), do: {:ok, :laya}
  def parse_name("winnow"), do: {:ok, :winnow}
  def parse_name(other), do: {:error, "unknown spec #{inspect(other)}; expected laya or winnow"}

  @doc """
  The model resolver `evaluate/2` calls, with the action input and context.

  Raises when the context names no spec, because silently falling back to a
  default model would make a result file lie about which model answered it.
  """
  def for_input(%{context: context}, _action_context) do
    case context do
      %{system_one_spike: %{spec: name} = spike} ->
        spec(name, Map.get(spike, :transport, :live), Map.get(spike, :tag, "r1"))

      _ ->
        raise ArgumentError,
              "ClinicDemo.SystemOneSpike actions need context: %{system_one_spike: %{spec: :laya | :winnow}}"
    end
  end

  @doc "The tuple spec for a spec name and transport."
  def spec(name, transport \\ :live, tag \\ "r1") do
    model_id = model_id(name)

    opts =
      [api_key: env("OLLAYA_API_KEY", "local"), receive_timeout: receive_timeout()]
      |> put_transport(transport, model_id, tag)

    {:typesafe, model_id, opts}
  end

  @doc "Whether every spec resolves to a base URL for live calls."
  def live_configured? do
    @specs
    |> Map.values()
    |> Enum.all?(&match?({:ok, _}, resolve_base_url(&1)))
  end

  @doc """
  Ollaya's base URL for a model id, with any trailing `/` trimmed.

  When `S1_OLLAYA_ROUTES` is set (comma-separated `model=CPU|GPU` entries), the
  model's entry picks the host: `GPU` reads `S1_OLLAYA_GPU_BASE_URL`, `CPU`
  reads `OLLAYA_BASE_URL`. When the variable is unset, every model uses
  `OLLAYA_BASE_URL` — the single-host behaviour replay, stub and CI rely on.

  Raises, naming the model and the variable, when the routes are set but name
  no host for the model, or when the host it routes to is not set: a result
  file must never lie about which host answered.
  """
  def ollaya_base_url(model_id) do
    case resolve_base_url(model_id) do
      {:ok, url} -> url
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp resolve_base_url(model_id) do
    case System.get_env("S1_OLLAYA_ROUTES") do
      routes when is_binary(routes) and routes != "" ->
        case route_target(routes, model_id) do
          {:ok, "CPU"} ->
            host_url("OLLAYA_BASE_URL")

          {:ok, "GPU"} ->
            host_url("S1_OLLAYA_GPU_BASE_URL")

          {:ok, other} ->
            {:error,
             "S1_OLLAYA_ROUTES routes #{model_id} to #{inspect(other)}; expected CPU or GPU"}

          :missing ->
            {:error,
             "S1_OLLAYA_ROUTES is set but has no entry for #{model_id}; " <>
               "add #{model_id}=CPU or #{model_id}=GPU"}
        end

      _ ->
        host_url("OLLAYA_BASE_URL")
    end
  end

  # `nli:latest=CPU,winnow:e4b=GPU` for a model id becomes `{:ok, "CPU"}` or
  # `:missing`. Entries for other models are ignored.
  defp route_target(routes, model_id) do
    routes
    |> String.split(",", trim: true)
    |> Enum.find_value(:missing, &entry_target(&1, model_id))
  end

  # `nli:latest=CPU` matches a model id, or it does not. Malformed entries
  # yield nil, which the find_value default turns into `:missing`.
  defp entry_target(entry, model_id) do
    case String.split(String.trim(entry), "=", parts: 2) do
      [model, target] when model != "" and target != "" ->
        if String.trim(model) == model_id, do: {:ok, String.upcase(String.trim(target))}

      _ ->
        nil
    end
  end

  defp host_url(var) do
    case System.get_env(var) do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> {:error, "#{var} is not set; source ~/.config/system-one/endpoints.env"}
    end
  end

  defp put_transport(opts, :live, model_id, _tag), do: put_live_base_url(opts, model_id)

  defp put_transport(opts, {:record, set}, model_id, tag) do
    opts
    |> Keyword.put(:base_url, Transport.placeholder_base_url())
    |> Keyword.put(:req_http_options,
      plug:
        {Transport,
         mode: :record, set: set, upstream: ollaya_base_url(model_id), model: model_id, tag: tag}
    )
  end

  defp put_transport(opts, {:replay, set}, model_id, tag) do
    opts
    |> Keyword.put(:base_url, Transport.placeholder_base_url())
    |> Keyword.put(:req_http_options,
      plug: {Transport, mode: :replay, set: set, model: model_id, tag: tag}
    )
  end

  defp put_transport(opts, :stub, model_id, tag) do
    opts
    |> Keyword.put(:base_url, Transport.placeholder_base_url())
    |> Keyword.put(:req_http_options,
      plug: {Transport, mode: :stub, model: model_id, tag: tag}
    )
  end

  defp put_transport(opts, {:stub_record, set}, model_id, tag) do
    opts
    |> Keyword.put(:base_url, Transport.placeholder_base_url())
    |> Keyword.put(:req_http_options,
      plug: {Transport, mode: :stub, record_stub?: true, set: set, model: model_id, tag: tag}
    )
  end

  # Any other plug, for tests that inspect the request on the wire.
  defp put_transport(opts, {:plug, plug}, _model_id, _tag) do
    opts
    |> Keyword.put(:base_url, Transport.placeholder_base_url())
    |> Keyword.put(:req_http_options, plug: plug)
  end

  defp put_live_base_url(opts, model_id) do
    Keyword.put(opts, :base_url, ollaya_base_url(model_id))
  end

  defp receive_timeout do
    case Integer.parse(env("S1_SPIKE_RECEIVE_TIMEOUT_MS", "60000")) do
      {ms, ""} when ms > 0 -> ms
      _ -> 60_000
    end
  end

  defp env(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end
end
