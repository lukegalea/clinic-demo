defmodule ClinicDemo.AI.RequestClassifier do
  @moduledoc """
  Holds the prompt-backed actions that interpret a console request.

  A resource with **no data layer**, because there is nothing to store. Ash puts
  generic actions on resources rather than domains, so this exists to give the
  actions a home — it is not an entity in the domain model, and it deliberately
  has no attributes, no table and no policies.
  """

  use Ash.Resource,
    domain: ClinicDemo.AI,
    extensions: [AshAi]

  # `prompt/2` is a macro in AshAi.Actions, not a function in AshAi, and it is
  # not auto-imported by the extension.
  import AshAi.Actions, only: [prompt: 2]

  alias ClinicDemoWeb.A2ui.Surfaces

  code_interface do
    define :interpret_request, args: [:request]
    define :compose_surface, args: [:request]
    define :answer_question, args: [:request]
  end

  actions do
    action :interpret_request, ClinicDemo.AI.Intent do
      description """
      Classify a console request written in natural language.

      Returns an intent describing what was asked for. Performs nothing: every
      kind it can name resolves to a read, and the read happens afterwards,
      filtered by the requesting human.
      """

      argument :request, :string, allow_nil?: false

      # A capture, not a call. `prompt/2` is a macro and its arguments are
      # evaluated while this module compiles, so `ClinicDemo.AI.model()`
      # baked whatever config existed at *build* time into the action -- a
      # release could never be repointed at another provider, which is the one
      # thing `:interpreter_model` exists to allow. AshAi resolves a 0-arity
      # function per call instead.
      run prompt(
            &ClinicDemo.AI.model/0,
            # `tools: false` is load-bearing, not a default. A model holding a
            # mutation tool can perform the mutation regardless of what the
            # prompt says or what a user injects into their request. Denying
            # tools here makes that structurally impossible rather than merely
            # discouraged.
            tools: false,
            prompt: """
            You classify requests for the staff console of a veterinary clinic
            application.

            Supported request kinds:

              - :show_surface -- the request is answered by showing one of the
                tables this application already declares. PREFER THIS whenever
                one of them fits, even loosely: a declared surface has been
                designed, its columns were chosen deliberately, and the board
                surfaces were arranged around how the clinic works. Put the
                surface's name in `surface`, copied exactly from this list:

            <%= ClinicDemoWeb.A2ui.Surfaces.catalogue() %>

                Examples: "show me the patients" -> :show_surface, surface
                "patients". "what's on the schedule" -> :show_surface, surface
                "schedule". "anything urgent right now?" -> :show_surface,
                surface "emergencies".

              - :design_surface -- the request is for a table, but no declared
                surface answers it: it asks for particular columns, a filter, a
                grouping, or a resource with no surface of its own. A second
                step composes it; you only have to notice that none of the
                above fits.

                Example: "appointments, just patient and triage urgency,
                sorted by time" -> :design_surface.

              - :ask_question -- the request asks a QUESTION about this clinic
                application that words can answer: what a status means, what
                the triage table decides, which process runs after booking. A
                second step answers it from the same catalogue below; you only
                have to notice it is a question, not a request for a table.

                Example: "what makes an appointment an emergency?" ->
                :ask_question.

              - :unknown -- anything else.

            Extract names EXACTLY as the user wrote them. Do not guess,
            correct, or complete them: the application resolves them against
            records the requesting user is allowed to see, and a "corrected"
            value silently targets the wrong record.

            Request: <%= @input.arguments.request %>
            """
          )
    end

    action :compose_surface, ClinicDemo.AI.SurfaceSpec do
      description """
      Compose an ad-hoc A2UI surface spec for a request no declared surface
      answers.

      Returns a spec, which is not a UI: the server resolves every resource,
      field and action name in it against an allowlist, runs the same verifiers
      the compile-time DSL runs, and only then builds anything. A spec naming a
      field that does not exist is refused with an error, not rendered blank.
      """

      argument :request, :string, allow_nil?: false

      # Same reasoning as `:interpret_request` -- and `tools: false` matters more
      # here, not less. This action's whole job is to emit a description of a
      # table, and a model holding a mutation tool could perform one on the way.
      run prompt(
            &ClinicDemo.AI.model/0,
            tools: false,
            prompt: """
            You compose declarative table specifications for a veterinary clinic
            application. You do not write UI: you name a resource, the fields to
            show, and how to sort and search them. The server validates every
            name you use and builds the actual interface.

            Return ONLY an object with a single key "spec", whose value is the
            JSON text of one table specification matching this schema:

            <%= ClinicDemo.AI.RequestClassifier.spec_schema_json() %>

            The resources you may use, with their real field and action names:

            <%= ClinicDemo.AI.RequestClassifier.resource_descriptions() %>

            Rules that are not negotiable, because breaking them produces an
            error rather than a surface:

              - Use ONLY field names that appear in the descriptions above. Never
                invent one, never guess a plural or a synonym.
              - `resource` must be one of the names above, exactly.
              - One table component is almost always right. Give it a `read_action`
                that exists on the resource.

            Request: <%= @input.arguments.request %>
            """
          )
    end

    action :answer_question, ClinicDemo.AI.Answer do
      description """
      Answer, in words, a question about this clinic application.

      Grounded: the answer may use only the surface catalogue and the resource
      descriptions given in the prompt. It reads nothing live, changes nothing,
      and says so when the answer is not in its sources.
      """

      argument :request, :string, allow_nil?: false

      # `tools: false` for the same reason as the other two actions -- and
      # because a question is exactly where an injected instruction would most
      # like a helpful-sounding tool call to hide.
      run prompt(
            &ClinicDemo.AI.model/0,
            tools: false,
            prompt: """
            You answer questions about a veterinary clinic application, for the
            staff who use its console.

            Answer ONLY from what appears in these two sources:

            The surfaces this application declares, with what each shows:

            <%= ClinicDemoWeb.A2ui.Surfaces.catalogue() %>

            The resources beneath those surfaces, with their real field and
            action names:

            <%= ClinicDemo.AI.RequestClassifier.resource_descriptions() %>

            If the answer is not in those sources, say exactly that. Do not
            invent clinic policy, do not guess at field meanings, and do not
            promise a table -- the console will offer to compose one separately
            if that is what is wanted.

            Return ONLY an object with a single key "text", whose value is the
            answer in one or two plain sentences a person can read at a glance.

            Question: <%= @input.arguments.request %>
            """
          )
    end
  end

  @doc """
  The surface spec's JSON schema, as text for a prompt.

  Generated by `ash_a2ui` from the allowlist rather than written here, so the
  vocabulary the model is given and the vocabulary the server accepts are the
  same object. A hand-written copy would drift the first time the DSL gained a
  key, and the symptom would be a model producing specs the server refuses.
  """
  def spec_schema_json do
    Surfaces.dynamic_allowlist()
    |> AshA2ui.Dynamic.spec_schema()
    |> JSON.encode!()
  end

  @doc """
  The allowlisted resources described in words -- fields, types, enum values,
  actions, relationships.

  Also generated. A model cannot compose against -- or answer questions about --
  fields it cannot see, and this is the difference between a spec that resolves
  and one that names `full_name` on a resource that calls it `name`.

  Encoded to JSON here rather than interpolated raw: `describe_resources/1`
  returns a list of maps, and EEx's `<%= %>` calls `to_string/1` on whatever it
  is given, which raises on a list of maps rather than rendering one.
  """
  def resource_descriptions do
    Surfaces.dynamic_allowlist()
    |> AshA2ui.Dynamic.describe_resources()
    |> JSON.encode!()
  end
end
