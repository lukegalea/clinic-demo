defmodule ClinicDemo.AI.Interpreter do
  @moduledoc """
  Turns a natural-language request into a *plan* — something the console can
  show, or answer with.

  This is the only part of the agent flow that involves a model, and it is
  deliberately the *smallest* part. It produces a plan; it never performs
  anything. Every plan this module can return is a read — a declared surface, a
  composed one, or an answer in words — so there is no execution, authorization
  or audit step to trust: the console renders the plan through the same
  policy-filtered reads the rest of the app uses, which is why the agent flow
  is testable end to end without an API key.

  ## Structured output, not tool calling

  The model is asked for a **structured value** (`ClinicDemo.AI.Intent`) rather
  than being handed tools. Two reasons:

    * A model holding a mutation tool can perform the mutation. A model
      returning a struct cannot, no matter what the prompt says or what a user
      injects into it.
    * The return type *is* the schema. Ash derives the JSON schema from the
      TypedStruct, so there is no separate schema to keep in sync — the same
      "model your domain, derive the rest" property as everywhere else.

  ## Without an API key

  `interpret/1` returns a clear error naming the environment variable the
  *configured* model needs. It does not fall back to pattern matching: a
  fallback that silently half-works is worse than an honest failure, because it
  produces a demo that appears to prove something it does not.

  The provider follows `ClinicDemo.AI.model/0`, which `AI_INTERPRETER_MODEL`
  sets — so switching provider is a deployment concern and never a code change.
  """

  alias AshA2ui.Dynamic.Error
  alias ClinicDemo.AI.Answer
  alias ClinicDemo.AI.RequestClassifier
  alias ClinicDemoWeb.A2ui.Surfaces

  @typedoc """
  What the console should do about a request.

  A tagged tuple rather than a single struct, because the three outcomes are
  not variations on one thing: two render a surface (one from the registry,
  one composed and then validated) and one is words to put in the result
  banner. Collapsing them would mean threading a "which kind am I" flag
  through code that pattern-matching decides for free.
  """
  @type plan ::
          {:surface, map()}
          | {:designed, struct(), String.t()}
          | {:answer, String.t()}

  @doc """
  Interprets `request` and returns `{:ok, plan}` or `{:error, message}`.
  """
  @spec interpret(String.t()) :: {:ok, plan()} | {:error, String.t()}
  def interpret(request) do
    with {:ok, intent} <- infer_intent(request) do
      plan(intent, request)
    end
  end

  @doc """
  Turns an already-inferred intent into a plan.

  Public because it is the seam the tests need. The model call is the one part of
  this flow that cannot run without a provider; everything after it is ordinary
  code, and the moduledoc's claim that the flow is exercised without an API key
  depends on that half being reachable. Applications should call `interpret/1`.
  """
  @spec plan(ClinicDemo.AI.Intent.t(), String.t()) :: {:ok, plan()} | {:error, String.t()}
  def plan(intent, request), do: to_plan(intent, request)

  defp to_plan(%{kind: :show_surface} = intent, _request) do
    case Surfaces.fetch(intent.surface) do
      nil ->
        # The model named a surface that does not exist. Listing the real names
        # rather than apologising, because the next thing the person will do is
        # ask again and they need to know what to ask for.
        {:error,
         "I read that as a request to show #{inspect(intent.surface)}, which is not one of " <>
           "the surfaces here. Available: #{Enum.join(Surfaces.names(), ", ")}."}

      surface ->
        {:ok, {:surface, surface}}
    end
  end

  defp to_plan(%{kind: :design_surface}, request) do
    design(request)
  end

  # A question is answered by a second prompt call, the same way a designed
  # table is composed by one: the classifier only has to notice that this is a
  # question, and the answering call carries the catalogue and the resource
  # descriptions it needs to stay grounded.
  defp to_plan(%{kind: :ask_question}, request) do
    answer(request)
  end

  defp to_plan(%{kind: kind}, _request) do
    {:error,
     "I understood that as #{inspect(kind)}, which this console does not support. " <>
       "It can show one of the declared surfaces (#{Enum.join(Surfaces.names(), ", ")}), " <>
       "compose a table for you, or answer a question about this clinic."}
  end

  # Composition is a second model call, not a bigger first one. The classifier's
  # job is to notice that nothing declared fits, which is a small judgement over
  # a short list; composing a spec needs the whole schema of every allowlisted
  # resource in its prompt. Putting both in one call would pay for the second
  # prompt on every request, including the ones answered by a declared surface.
  defp design(request) do
    with {:ok, spec} <- compose(request),
         {:ok, surface} <-
           AshA2ui.Dynamic.resolve(spec, allowlist: Surfaces.dynamic_allowlist()) do
      {:ok, {:designed, surface, surface.title || "Composed table"}}
    else
      # `AshA2ui.Dynamic.resolve/2` fails with a LIST of `%Error{}`;
      # `compose/1` fails with a message it has already written. Those two are
      # the whole failure space, so there is no catch-all -- one would be
      # unreachable, and Dialyzer says so.
      {:error, errors} when is_list(errors) ->
        {:error, refusal_message(errors)}

      {:error, message} when is_binary(message) ->
        {:error, message}
    end
  end

  # Structured refusals from the same verifiers the compile-time DSL runs, shown
  # rather than swallowed: "that field does not exist" is a useful thing for a
  # person to read, and it is the evidence that the spec was checked rather than
  # rendered.
  #
  # One clause, no empty-list case: a refusal always carries at least one error,
  # which Dialyzer proves rather than this asserting.
  defp refusal_message(errors) do
    "I composed a table but the server refused it:\n" <>
      Enum.map_join(Error.messages(errors), "\n", &"  - #{&1}")
  end

  defp compose(request) do
    case RequestClassifier.compose_surface(request) do
      {:ok, %ClinicDemo.AI.SurfaceSpec{spec: json}} when is_binary(json) ->
        decode_spec(json)

      {:ok, %{"spec" => json}} when is_binary(json) ->
        decode_spec(json)

      {:ok, other} ->
        {:error, "The model returned #{inspect(other)} rather than a table spec."}

      {:error, error} ->
        {:error, "Could not compose a table: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not compose a table: #{Exception.message(error)}"}
  end

  defp answer(request) do
    case RequestClassifier.answer_question(request) do
      {:ok, %Answer{text: text}} when is_binary(text) ->
        {:ok, {:answer, text}}

      {:ok, %{"text" => text}} when is_binary(text) ->
        {:ok, {:answer, text}}

      {:ok, other} ->
        {:error, "The model returned #{inspect(other)} rather than an answer."}

      {:error, error} ->
        {:error, "Could not answer that: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not answer that: #{Exception.message(error)}"}
  end

  # The spec travels as JSON text -- see `ClinicDemo.AI.SurfaceSpec` for why
  # it cannot be a free-form `:map` return -- so the last mile is decoding it
  # back into the map the surface composer expects.
  defp decode_spec(json) do
    case Jason.decode(json) do
      {:ok, spec} when is_map(spec) ->
        {:ok, spec}

      {:ok, other} ->
        {:error, "The spec JSON decoded to #{inspect(other)} rather than an object."}

      {:error, error} ->
        {:error, "The spec was not valid JSON: #{Exception.message(error)}"}
    end
  end

  defp infer_intent(request) do
    case key_status() do
      :ok -> run_prompt(request)
      {:error, message} -> {:error, message}
    end
  end

  # Asks ReqLLM about the provider we are actually going to call, rather than
  # reimplementing its lookup or guessing the provider.
  #
  # Both halves of that were wrong before. `ReqLLM.Keys.get/1` resolves in three
  # places -- an explicit `:api_key`, `config :req_llm`, and the environment
  # variable -- and checking only the middle one reported "no provider
  # configured" for a key supplied exactly as the error message instructs, since
  # a `dotenv` step puts `.env` into the environment rather than into
  # application config. The provider list was then hardcoded to Anthropic and
  # OpenAI even though the model is configurable, so pointing `:interpreter_model`
  # at any other provider reported the same thing with its key correctly set.
  defp key_status do
    model = ClinicDemo.AI.model()

    # The `String.trim/1` step is the load-bearing one. An empty key is *found* by
    # `ReqLLM.Keys.get/1` and reported as configured, so without it the request
    # goes out and fails with "ANTHROPIC_API_KEY was found but is empty" -- a
    # provider error where the honest answer is that nothing is configured.
    #
    # That is the state a fresh checkout is in, not an exotic one: `.env.example`
    # ships `ANTHROPIC_API_KEY=` with nothing after it, so `cp .env.example .env`
    # sets the variable and leaves it blank. Whitespace counts too -- a key pasted
    # with a trailing newline is blank for every purpose except `byte_size/1`.
    with {:ok, %{provider: provider}} <- ReqLLM.model(model),
         {:ok, key, _source} <- ReqLLM.Keys.get(provider),
         true <- String.trim(key) != "" do
      :ok
    else
      _ -> {:error, not_configured_message(model)}
    end
  end

  defp not_configured_message(model) do
    # Naming the variable the configured model actually needs, rather than a
    # fixed pair, so the instruction is never wrong for the current config.
    env_var =
      case ReqLLM.model(model) do
        {:ok, %{provider: provider}} -> ReqLLM.Keys.env_var_name(provider)
        _ -> "ANTHROPIC_API_KEY"
      end

    """
    No API key is configured for `#{model}`, so natural-language requests \
    cannot be interpreted. Set #{env_var} in .env and restart, or point \
    AI_INTERPRETER_MODEL at a provider you do have a key for.

    The rest of this console -- the surface buttons below -- does not depend \
    on a provider and works without one.\
    """
  end

  defp run_prompt(request) do
    case RequestClassifier.interpret_request(request) do
      {:ok, intent} -> {:ok, intent}
      {:error, error} -> {:error, "Could not interpret that request: #{Exception.message(error)}"}
    end
  rescue
    error -> {:error, "Could not interpret that request: #{Exception.message(error)}"}
  end
end
