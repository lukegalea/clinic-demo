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
  | `OLLAYA_BASE_URL` | Ollaya's base URL; Ollaya speaks the TypeSafe wire | none; required for a live run |
  | `OLLAYA_API_KEY` | Ollaya's key, if `OLLAYA_API_KEY` is set on the server | `"local"` |

  Verifier model ids are passed by name (`laya:typed-decisions`,
  `winnow:e4b`) and resolved against Ollaya.
  """

  @doc "The generative extraction model's spec."
  def extractor do
    provider = provider(env("S1_GEN_PROVIDER", "openai"))
    model = env("S1_GEN_MODEL", "qwen3.8-27b")

    opts =
      [api_key: env("S1_GEN_API_KEY", "local")]
      |> put_base_url(System.get_env("S1_GEN_BASE_URL"))
      |> structured_output(provider)

    {provider, model, opts}
  end

  @doc "A verifier model's spec on Ollaya, by model id."
  def verifier(model_id) do
    opts =
      [api_key: env("OLLAYA_API_KEY", "local")]
      |> put_base_url(System.get_env("OLLAYA_BASE_URL"))

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
