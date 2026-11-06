defmodule ClinicDemo.Planning.StaffingPolicy do
  @moduledoc """
  Asks the pinned `staffing.policy` decision for everything the roster model takes
  as policy, and returns it as plain data.

  A decision decides; this module only asks. Two kinds of question, one table
  (`priv/decisions/staffing_policy.dmn`):

    * per appointment type: the **required role** (qualification) and the
      **duration policy** in minutes;
    * per weekday: the **reserve capacity** in minutes and the **allowed shift
      patterns** (template names).

  The definition is evaluated at the **version and content hash the binding
  pinned**, never the latest published one: a plan must be replayable against the
  rule it was made with, so a head vet's later edit changes the next plan and not
  this one. A pinned version that no longer matches its hash is `definition_drift`.
  Every evaluation is recorded as a `Decisions.Evaluation` row like any other.
  """

  require Ash.Query

  alias AshDecisions.Evaluator
  alias ClinicDemo.Decisions.{DecisionTable, Evaluation}

  @weekdays ~w(monday tuesday wednesday thursday friday saturday sunday)

  @type t :: %{
          definition: %{key: String.t(), version: integer(), content_hash: String.t()},
          appointment: %{optional(String.t()) => %{role: atom(), duration_minutes: pos_integer()}},
          week: %{pos_integer() => %{reserve_minutes: non_neg_integer(), patterns: [String.t()]}}
        }

  @doc """
  The pinned decision definition: `{:ok, definition}` for the row with the given
  `version` whose content hash matches `content_hash`.
  """
  @spec fetch_definition(String.t(), integer(), String.t()) ::
          {:ok, struct()} | {:error, :definition_unavailable | :definition_drift}
  def fetch_definition(key, version, content_hash) do
    DecisionTable
    |> Ash.Query.filter(key == ^key and version == ^version and status == :published)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{content_hash: ^content_hash} = definition} -> {:ok, definition}
      {:ok, %{}} -> {:error, :definition_drift}
      _ -> {:error, :definition_unavailable}
    end
  end

  @doc """
  Evaluates the policy for the given appointment type names, plus the seven
  weekdays. `{:error, {:no_answer, what}}` when a question has no answer (a table
  gap, never a silent default).
  """
  @spec evaluate(struct(), [String.t() | nil]) :: {:ok, t()} | {:error, term()}
  def evaluate(definition, type_names) do
    with {:ok, appointment} <- appointments(definition, type_names),
         {:ok, week} <- weekdays(definition) do
      {:ok,
       %{
         definition: %{
           key: definition.key,
           version: definition.version,
           content_hash: definition.content_hash
         },
         appointment: appointment,
         week: week
       }}
    end
  end

  defp appointments(definition, type_names) do
    type_names
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, %{}}, fn name, {:ok, acc} ->
      case ask(definition, %{
             "kind" => "appointment",
             "appointmentType" => name || "",
             "weekday" => ""
           }) do
        {:ok, %{"requiredRole" => role, "durationMinutes" => minutes}}
        when role in ["veterinarian", "technician", "nurse"] and not is_nil(minutes) ->
          {:cont,
           {:ok,
            Map.put(acc, name || "", %{
              role: role_atom(role),
              duration_minutes: to_integer(minutes)
            })}}

        _other ->
          {:halt, {:error, {:no_answer, "appointment type #{inspect(name)}"}}}
      end
    end)
  end

  defp weekdays(definition) do
    @weekdays
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, %{}}, fn {name, day}, {:ok, acc} ->
      case ask(definition, %{"kind" => "week", "appointmentType" => "", "weekday" => name}) do
        {:ok, %{"reserveMinutes" => reserve, "shiftPatterns" => patterns}}
        when not is_nil(reserve) and is_binary(patterns) ->
          {:cont,
           {:ok,
            Map.put(acc, day, %{
              reserve_minutes: to_integer(reserve),
              patterns: patterns(patterns)
            })}}

        _other ->
          {:halt, {:error, {:no_answer, "weekday #{name}"}}}
      end
    end)
  end

  defp ask(definition, inputs) do
    inputs = Map.new(inputs, fn {k, v} -> {k, AshDecisions.Feel.to_feel_value(v)} end)

    case Evaluator.evaluate(definition, inputs, evaluation_resource: Evaluation) do
      {:ok, %{outputs: %{} = outputs}} -> {:ok, outputs}
      {:ok, _other} -> :error
      {:error, _reason} -> :error
    end
  end

  # The role names are the three the decision may answer; a closed map, never an
  # atom minted from a decision's output.
  defp role_atom("veterinarian"), do: :veterinarian
  defp role_atom("technician"), do: :technician
  defp role_atom("nurse"), do: :nurse

  defp patterns(""), do: []
  defp patterns(csv), do: csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp to_integer(%Decimal{} = d), do: d |> Decimal.round() |> Decimal.to_integer()
  defp to_integer(n) when is_integer(n), do: n
end
