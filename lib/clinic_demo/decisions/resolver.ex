defmodule ClinicDemo.Decisions.Resolver do
  @moduledoc """
  The bridge between the two packages: `ash_bpmn` asks, `ash_decisions` answers.

  A `businessRuleTask` in the visit process carries a decision *reference* and
  nothing else — no rule table, no thresholds, no FEEL. The graph does not know
  what `appointment.triage` is; it knows it wants the answer and which of the
  answer's fields to promote onto the token. This module is where the reference
  becomes a lookup.

  Two things worth pointing out:

    * **No version is pinned.** `latest_published/1` is called on every
      evaluation, which is the opposite of how process definitions behave and is
      deliberate: a process version is a shape, and changing it under a running
      instance can leave a token with nowhere to stand. A decision is a rule, and
      the reason a clinic keeps rules out of code is so that changing one takes
      effect without a deploy.
    * **Every input goes through `AshDecisions.Feel.to_feel_value/2`.** FEEL
      numbers are decimal, so a plain Elixir integer makes `>= 4` a type error,
      which is `null`, which a decision table reads as "no rule matched" — a
      silently empty table with nothing reported anywhere.
  """

  @behaviour AshBpmn.DecisionResolver

  require Logger

  alias ClinicDemo.Decisions.Definition
  alias ClinicDemo.Decisions.Evaluation

  @impl true
  def decide(ref, inputs, context) do
    with {:ok, definition} <- latest_published(ref) do
      inputs = Map.new(inputs, fn {k, v} -> {k, AshDecisions.Feel.to_feel_value(v)} end)

      case AshDecisions.Evaluator.evaluate(definition, inputs,
             evaluation_resource: Evaluation,
             correlation_id: correlation_id(context)
           ) do
        {:ok, result} ->
          {:ok, %{outputs: outputs(result.outputs), version: result.definition_version}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def exists?(ref), do: match?({:ok, _}, latest_published(ref))

  # A single-output decision table answers with the output's value under its
  # name; `ash_bpmn` promotes named scalars, so a bare value is wrapped under
  # the decision's output name rather than guessed at further up.
  defp outputs(%{} = outputs), do: outputs
  defp outputs(value), do: %{"urgency" => value}

  defp latest_published(ref) do
    case Definition.latest_published!(ref) do
      [definition | _] -> {:ok, definition}
      [] -> {:error, "no published decision for #{inspect(ref)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # The instance the question was asked from, so an auditor reading an
  # evaluation row can get back to the visit it decided.
  defp correlation_id(%{instance: %{id: id}}), do: id
  defp correlation_id(_context), do: nil
end
