defmodule ClinicDemo.EvidenceSpike.Extractor do
  @moduledoc """
  The two model rungs of extract-then-verify, as Ash actions.

  A resource with no data layer, like `ClinicDemo.AI.RequestClassifier`: it
  gives two generic actions somewhere to live.

    * `:extract` is an `ash_ai` prompt action. It returns
      `ClinicDemo.EvidenceSpike.Extraction`, so its wire schema is derived from
      that type and its reply is cast back through it. The schema is
      **static**: it is the same for every packet.
    * `:verify` is an `ash_ai` evaluate action returning a Noul. It asks one
      closed question about one proposal: *does atom `a05` state that the
      policy number is `CLV-1234567`?* It sends only the cited atoms, so a
      verification fits laya's 1,024-token context.

  `extract_with_enum/2` is the host-code path. It sends the same schema, with
  `source_ids` narrowed to this packet's atom ids, straight through
  `generate_object/4`, then casts the reply through the same type. Under a
  grammar-constrained decoder, it cannot cite an atom that does not exist.

  Both actions route their model calls through `ClinicDemo.EvidenceSpike.Wire`,
  via `ash_ai`'s `req_llm:` option, so the same code runs live, records
  fixtures, or replays them. The model specs come from
  `ClinicDemo.EvidenceSpike.Models`.
  """

  use Ash.Resource,
    domain: ClinicDemo.EvidenceSpike,
    extensions: [AshAi]

  import AshAi.Actions, only: [prompt: 2, evaluate: 2]

  alias Ash.Resource.Info
  alias ClinicDemo.EvidenceSpike.{Extraction, Models, Wire}

  code_interface do
    define :extract, args: [:packet]
    define :verify, args: [:verifier, :atoms, :field, :value]
  end

  actions do
    action :extract, Extraction do
      description "Propose a value, a status and cited atom ids for every certificate field."

      argument :packet, {:array, :map}, allow_nil?: false

      run prompt(&Models.extractor/0,
            tools: false,
            req_llm: Wire,
            prompt: &__MODULE__.extraction_prompt/2
          )
    end

    action :verify, AshAi.Evaluate.Noul do
      description "Does the cited text state that this field has this value?"

      argument :verifier, :string, allow_nil?: false
      argument :atoms, :map, allow_nil?: false
      argument :field, :atom, allow_nil?: false
      argument :value, :string, allow_nil?: false

      run evaluate(&__MODULE__.verifier_for/1,
            req_llm: Wire,
            state: &__MODULE__.verification_state/2,
            questions: &__MODULE__.verification_question/2
          )
    end
  end

  @field_names %{
    insured_name: "the named insured",
    policy_number: "the policy number",
    insurer: "the insurer",
    coverage_type: "the coverage type",
    effective_date: "the first day of the policy period",
    expiry_date: "the last day of the policy period",
    per_claim_limit: "the each-claim limit",
    aggregate_limit: "the aggregate limit"
  }

  @doc false
  def verifier_for(input), do: Models.verifier(input.arguments.verifier)

  @doc false
  def verification_state(input, _context), do: %{atoms: input.arguments.atoms}

  @doc false
  def verification_question(input, _context) do
    %{
      instructions:
        "Does the text in `atoms` state that #{Map.fetch!(@field_names, input.arguments.field)} " <>
          "is `#{input.arguments.value}`?",
      criteria: %{
        true: "The text states exactly this value for this field.",
        false: "The text states a different value, a different field, or does not say."
      }
    }
  end

  @doc false
  def extraction_prompt(input, _context), do: messages(input.arguments.packet)

  @doc "The chat messages for one packet. Shared by both extraction paths."
  def messages(packet) do
    atoms =
      Enum.map_join(packet, "\n", fn atom ->
        "[#{atom_field(atom, :id)}] #{atom_field(atom, :text)}"
      end)

    ReqLLM.Context.new([
      ReqLLM.Context.system("""
      You read one liability-insurance certificate and propose a value for each field.

      The certificate is given as numbered atoms. For every field:
        - status "found" when exactly one value is stated; give the value and the ids of the atoms you read it from;
        - status "not_found" when the certificate does not state it; value null, no ids;
        - status "ambiguous" when the certificate states conflicting values; value null, cite the conflicting atoms.

      Copy values exactly as printed. Never guess, complete or correct a value. Cite only atom ids that appear below.
      Dates are ISO 8601 (YYYY-MM-DD). Money is a whole number of Canadian dollars with no symbols or separators.
      """),
      ReqLLM.Context.user("Certificate atoms:\n" <> atoms)
    ])
  end

  @doc """
  The static wire schema, exactly as `ash_ai`'s prompt action builds it.

  `AshAi.Actions.Prompt` builds its schema in a private function. This mirrors
  that function: a `result` property, derived from the return type by
  `AshAi.OpenApi`. The unit tests compare the two, so drift fails a test
  rather than skewing a measurement.
  """
  def static_schema do
    # The action's constraints, not `[]`: Ash initialises a TypedStruct's
    # `fields` into the action's return constraints at compile time, and
    # `AshAi.OpenApi` renders an uninitialised TypedStruct as `{}`.
    constraints = return_constraints()

    %{
      "type" => "object",
      "properties" => %{
        "result" =>
          AshAi.OpenApi.resource_write_attribute_type(
            %{name: :result, type: Extraction, constraints: constraints},
            nil,
            :create
          )
      },
      "required" => ["result"],
      "additionalProperties" => false
    }
    |> stringify()
  end

  @doc "The static schema with every `source_ids` narrowed to `ids`."
  def enum_schema(ids) when is_list(ids) and ids != [] do
    update_in(static_schema(), ["properties", "result", "properties"], fn fields ->
      Map.new(fields, fn {name, field} ->
        {name,
         put_in(field, ["properties", "source_ids", "items"], %{"type" => "string", "enum" => ids})}
      end)
    end)
  end

  @doc """
  The host-code path: the per-call atom-id enum through `generate_object/4`.

  Returns `{:ok, %Extraction{}}`, or `{:error, reason}` when the model call or
  the cast fails. The cast is the same one the prompt action applies:
  `Ash.Type.cast_input/3`, then `Ash.Type.apply_constraints/3`.
  """
  def extract_with_enum(packet, ids) do
    with {:ok, %{object: object}} <-
           Wire.generate_object(Models.extractor(), messages(packet), enum_schema(ids), []) do
      cast(Map.get(object, "result", object))
    end
  end

  @doc "The `:extract` action's return constraints, initialised by Ash."
  def return_constraints, do: Info.action(__MODULE__, :extract).constraints

  defp cast(value) do
    constraints = return_constraints()

    with {:ok, cast} <- Ash.Type.cast_input(Extraction, value, constraints),
         {:ok, cast} <- Ash.Type.apply_constraints(Extraction, cast, constraints) do
      {:ok, cast}
    else
      {:error, error} -> {:error, "Failed to cast LLM response: #{inspect(error)}"}
    end
  end

  defp atom_field(atom, key), do: Map.get(atom, key) || Map.get(atom, to_string(key))

  defp stringify(%{} = map), do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)
  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(atom) when is_atom(atom) and atom not in [nil, true, false], do: to_string(atom)
  defp stringify(other), do: other
end
