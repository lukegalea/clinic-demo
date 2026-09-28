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
  | `OLLAYA_BASE_URL` | Ollaya's base URL, **without** `/v1` (ReqLLM appends `/v1/systemone`) | none; required for `:live` and `:record` |
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

  @doc "Whether the environment names a live Ollaya."
  def live_configured?, do: present?(System.get_env("OLLAYA_BASE_URL"))

  @doc "Ollaya's base URL, or an error naming the missing variable."
  def ollaya_base_url do
    case System.get_env("OLLAYA_BASE_URL") do
      url when is_binary(url) and url != "" -> {:ok, url |> String.trim_trailing("/")}
      _ -> {:error, "OLLAYA_BASE_URL is not set; source ~/.config/system-one/endpoints.env"}
    end
  end

  defp put_transport(opts, :live, _model_id, _tag), do: put_live_base_url(opts)

  defp put_transport(opts, {:record, set}, model_id, tag) do
    {:ok, upstream} = ollaya_base_url()

    opts
    |> Keyword.put(:base_url, Transport.placeholder_base_url())
    |> Keyword.put(:req_http_options,
      plug: {Transport, mode: :record, set: set, upstream: upstream, model: model_id, tag: tag}
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

  defp put_live_base_url(opts) do
    case ollaya_base_url() do
      {:ok, url} -> Keyword.put(opts, :base_url, url)
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp receive_timeout do
    case Integer.parse(env("S1_SPIKE_RECEIVE_TIMEOUT_MS", "60000")) do
      {ms, ""} when ms > 0 -> ms
      _ -> 60_000
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp env(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end
end
