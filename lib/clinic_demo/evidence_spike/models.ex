defmodule ClinicDemo.EvidenceSpike.Models do
  @moduledoc """
  The model specs for the spike, read from the environment on each call.

  ReqLLM does not read a base-URL environment variable for these providers,
  so a local endpoint is passed as a **tuple model spec**:
  `{provider, model_id, base_url: ..., api_key: ...}`. These are the only places
  the spike reads endpoint details. Nothing here is recorded: fixtures carry
  only `provider:model_id` (`ClinicDemo.EvidenceSpike.Wire.model_label/1`).

  ## Environment

  The operator puts these in `~/.config/system-one/endpoints.env`. The mix
  task does not read that file itself. `scripts/clin34-live.sh` sources it.

  | Variable | Meaning | Default |
  |---|---|---|
  | `S1_GEN_PROVIDER` | ReqLLM provider for the generative model (`openai` for llama-server, LM Studio or any OpenAI-compatible server; `ollama` for Ollama) | `openai` |
  | `S1_GEN_BASE_URL` | Its base URL, including `/v1` | none; required for a live run |
  | `S1_GEN_MODEL` | Its model id as the server names it | `qwen3.8-27b` |
  | `S1_GEN_API_KEY` | Its key, if the server wants one | `"local"` |
  | `S1_GEN_REASONING_EFFORT` | Sent to the generative server as ReqLLM's canonical `reasoning_effort` call option (`none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`, `default`). Splash reasons by default and reasoning tokens count against `max_tokens`, so `none` turns that off. | none; server default |
  | `OLLAYA_BASE_URL` | The CPU host's Ollaya base URL; Ollaya speaks the TypeSafe wire. Also the default for every verifier. | none; required for a live run |
  | `OLLAYA_API_KEY` | Ollaya's key, if `OLLAYA_API_KEY` is set on the server | `"local"` |
  | `S1_OLLAYA_ROUTES` | Per-model host routing, comma-separated `model=CPU\|GPU` (e.g. `laya:typed-decisions=CPU,winnow:e4b=GPU`). Set, every verifier must have an entry or `verifier/1` raises. Unset, every verifier stays on `OLLAYA_BASE_URL` (the old single-host behaviour, so replay/stub/CI are unaffected). | none |
  | `S1_OLLAYA_GPU_BASE_URL` | The GPU host's base URL, used for models routed `GPU` (winnow and jevk5 run there, on its CPU, because only that host has llama.cpp) | none; required when a route says `GPU` |

  Verifier model ids are passed by name (`laya:typed-decisions`,
  `winnow:e4b`) and resolved against Ollaya, on the host `S1_OLLAYA_ROUTES`
  names for them.

  `S1_GEN_REASONING_EFFORT` rides ReqLLM's **native** `reasoning_effort`
  option — no custom plug was needed. Like `openai_structured_output_mode`,
  it is read only as a top-level call option, so `Wire` lifts it out of the
  tuple spec into the call options, and the OpenAI ChatAPI encoder puts it in
  the request body.
  """

  @doc "The generative extraction model's spec."
  def extractor do
    provider = provider(env("S1_GEN_PROVIDER", "openai"))
    model = env("S1_GEN_MODEL", "qwen3.8-27b")

    opts =
      [api_key: env("S1_GEN_API_KEY", "local")]
      |> put_base_url(System.get_env("S1_GEN_BASE_URL"))
      |> structured_output(provider)
      |> reasoning_effort()

    {provider, model, opts}
  end

  @doc "A verifier model's spec, on the Ollaya host its route names."
  def verifier(model_id) do
    opts =
      [api_key: env("OLLAYA_API_KEY", "local")]
      |> put_base_url(verifier_base_url(model_id))

    {:typesafe, model_id, opts}
  end

  @doc "Whether the environment names both live endpoints."
  def live_configured? do
    present?(System.get_env("S1_GEN_BASE_URL")) and present?(System.get_env("OLLAYA_BASE_URL"))
  end

  # An allow-list, not String.to_atom/1: the value comes from the environment.
  defp provider("openai"), do: :openai
  defp provider("ollama"), do: :ollama
  defp provider("lmstudio"), do: :lmstudio
  defp provider("vllm"), do: :vllm

  defp provider(other),
    do:
      raise(
        ArgumentError,
        "S1_GEN_PROVIDER must be openai, ollama, lmstudio or vllm, got #{inspect(other)}"
      )

  # Force response_format json_schema on OpenAI-compatible servers. Under the
  # default (:auto), ReqLLM sends a forced tool call for a model id LLMDB does
  # not know (checked against the wire in test/clinic_demo/evidence_spike).
  # llama-server compiles a json_schema response format, enums included, to a
  # grammar. `Wire` moves this into the call options, which is the only place
  # ReqLLM reads it.
  defp structured_output(opts, :openai),
    do: Keyword.put(opts, :openai_structured_output_mode, :json_schema)

  defp structured_output(opts, _provider), do: opts

  # Per-model host routing (endpoints probe, 2026-09-29): the small ONNX
  # encoders live on the CPU host; winnow and jevk5 live on the GPU host,
  # on its CPU, because only that host has llama.cpp. With the routes
  # variable unset this is the old single-host behaviour, verbatim, so
  # replay, stub and CI runs never need a URL.
  defp verifier_base_url(model_id) do
    routes = System.get_env("S1_OLLAYA_ROUTES")

    if present?(routes) do
      case route(routes, model_id) do
        :cpu -> required_url("OLLAYA_BASE_URL")
        :gpu -> required_url("S1_OLLAYA_GPU_BASE_URL")
      end
    else
      System.get_env("OLLAYA_BASE_URL")
    end
  end

  # An allow-list keyed by the trimmed model id; a set variable without an
  # entry for the model, or a host value other than CPU/GPU, fails loud.
  defp route(routes, model_id) do
    entries =
      routes
      |> String.split(",", trim: true)
      |> Map.new(fn entry ->
        case String.split(entry, "=", trim: true) do
          [id, host] ->
            {String.trim(id), String.upcase(String.trim(host))}

          _ ->
            raise(
              ArgumentError,
              "S1_OLLAYA_ROUTES entry #{inspect(entry)} is not model=CPU or model=GPU"
            )
        end
      end)

    case Map.fetch(entries, model_id) do
      {:ok, "CPU"} ->
        :cpu

      {:ok, "GPU"} ->
        :gpu

      {:ok, other} ->
        raise(
          ArgumentError,
          "S1_OLLAYA_ROUTES entry for #{model_id} must be CPU or GPU, got #{inspect(other)}"
        )

      :error ->
        raise(
          ArgumentError,
          "S1_OLLAYA_ROUTES is set but has no entry for #{model_id}; " <>
            "add #{model_id}=CPU or #{model_id}=GPU"
        )
    end
  end

  # A routed verifier must land somewhere real: an unset host URL would send
  # ReqLLM to its own default, silently the wrong host.
  defp required_url(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" ->
        String.trim_trailing(value, "/")

      _ ->
        raise ArgumentError,
              "#{name} must be set: S1_OLLAYA_ROUTES routes a verifier to that host"
    end
  end

  # Splash reasons by default, and reasoning tokens count against max_tokens
  # (endpoints probe, 2026-09-29); "none" turns it off. ReqLLM carries
  # `reasoning_effort` natively as a canonical call option and the OpenAI
  # encoder puts it in the request body — no custom plug needed. `Wire` lifts
  # it out of the tuple spec, because ReqLLM reads it only from the call.
  defp reasoning_effort(opts) do
    case System.get_env("S1_GEN_REASONING_EFFORT") do
      value when is_binary(value) and value != "" ->
        Keyword.put(opts, :reasoning_effort, effort(value))

      _ ->
        opts
    end
  end

  # An allow-list with literal atoms, not String.to_atom/1: the value comes
  # from the environment.
  defp effort("none"), do: :none
  defp effort("minimal"), do: :minimal
  defp effort("low"), do: :low
  defp effort("medium"), do: :medium
  defp effort("high"), do: :high
  defp effort("xhigh"), do: :xhigh
  defp effort("max"), do: :max
  defp effort("default"), do: :default

  defp effort(other),
    do:
      raise(
        ArgumentError,
        "S1_GEN_REASONING_EFFORT must be none, minimal, low, medium, high, xhigh, max or default, " <>
          "got #{inspect(other)}"
      )

  defp put_base_url(opts, url) do
    if present?(url), do: Keyword.put(opts, :base_url, String.trim_trailing(url, "/")), else: opts
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp env(name, default) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end
end
