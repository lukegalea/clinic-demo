defmodule ClinicDemo.Planning.Explain do
  @moduledoc """
  Explains a candidate roster in the clinic's own vocabulary: why each appointment
  is covered by the clinician it is, and why each uncovered one is uncovered.

  Like the validator, it reads the **domain-level problem** and the decoded
  assignments, never the model, so what it says is what the roster means and not
  how the model encoded it. It states facts that hold in the candidate (role,
  shift, booked clinician, preserved from the applied plan) and, for an uncovered
  appointment, the first reason in a fixed order. It does not claim optimality:
  the model's objective weights are not reproduced here, so "why this clinician
  and not another" is never answered with more than the facts above.
  """

  alias ClinicDemo.Planning.SnapshotBuilder

  @type explanation :: %{
          appointment_id: String.t(),
          clinician_id: String.t() | nil,
          covered?: boolean(),
          reasons: [atom()],
          detail: String.t()
        }

  @doc """
  One explanation per appointment of the candidate's run, in appointment order.
  """
  @spec explain(struct(), struct()) :: {:ok, [explanation()]} | {:error, term()}
  def explain(candidate, run) do
    with {:ok, payload} <- SnapshotBuilder.problem_payload(run),
         {:ok, plan} <- Jason.decode(candidate.assignments) do
      problem = payload["problem"]
      covered = Map.new(plan["assignments"], &{&1["appointment_id"], &1})

      previous =
        MapSet.new(
          problem["previous"]["assignments"],
          &{&1["appointment_id"], &1["clinician_id"]}
        )

      {:ok,
       for appointment <- problem["appointments"] do
         case covered[appointment["id"]] do
           nil -> uncovered(appointment, problem)
           assignment -> covered(appointment, assignment, plan, previous)
         end
       end}
    else
      _ -> {:error, :unreadable}
    end
  end

  defp covered(appointment, assignment, plan, previous) do
    clinician_id = assignment["clinician_id"]

    reasons =
      [:required_role_held, :inside_shift] ++
        if(appointment["booked_clinician_id"] == clinician_id, do: [:booked_clinician], else: []) ++
        if(MapSet.member?(previous, {appointment["id"], clinician_id}),
          do: [:preserved_from_applied_plan],
          else: []
        )

    shift = Enum.find(plan["shifts"], &covering?(&1, clinician_id, appointment))

    %{
      appointment_id: appointment["id"],
      clinician_id: clinician_id,
      covered?: true,
      reasons: reasons,
      detail:
        "#{appointment["required_role"]} required; #{clinician_id} is on shift " <>
          "#{shift["starts_at"]}..#{shift["ends_at"]}"
    }
  end

  # The first reason that holds, in order: nobody holds the role, everybody who does
  # is unavailable then, otherwise the clinicians who could were already committed
  # (overlapping appointments or their reserve).
  defp uncovered(appointment, problem) do
    holders =
      for c <- problem["clinicians"], c["role"] == appointment["required_role"], do: c["id"]

    {reason, detail} =
      cond do
        holders == [] ->
          {:no_clinician_with_role, "no active #{appointment["required_role"]} on the roster"}

        Enum.all?(holders, &unavailable?(&1, appointment, problem)) ->
          {:all_qualified_unavailable,
           "every #{appointment["required_role"]} is unavailable at #{appointment["starts_at"]}"}

        true ->
          {:no_capacity, "the qualified clinicians are committed or at their reserve limit"}
      end

    %{
      appointment_id: appointment["id"],
      clinician_id: nil,
      covered?: false,
      reasons: [reason],
      detail: detail
    }
  end

  defp covering?(shift, clinician_id, appointment) do
    {:ok, shift_start, _} = DateTime.from_iso8601(shift["starts_at"])
    {:ok, shift_end, _} = DateTime.from_iso8601(shift["ends_at"])
    {:ok, starts_at, _} = DateTime.from_iso8601(appointment["starts_at"])
    {:ok, ends_at, _} = DateTime.from_iso8601(appointment["ends_at"])

    shift["clinician_id"] == clinician_id and DateTime.compare(shift_start, starts_at) != :gt and
      DateTime.compare(ends_at, shift_end) != :gt
  end

  defp unavailable?(clinician_id, appointment, problem) do
    {:ok, starts_at, _} = DateTime.from_iso8601(appointment["starts_at"])
    {:ok, ends_at, _} = DateTime.from_iso8601(appointment["ends_at"])

    Enum.any?(problem["unavailable"], fn u ->
      {:ok, u_start, _} = DateTime.from_iso8601(u["starts_at"])
      {:ok, u_end, _} = DateTime.from_iso8601(u["ends_at"])

      u["clinician_id"] == clinician_id and DateTime.compare(u_start, ends_at) == :lt and
        DateTime.compare(u_end, starts_at) == :gt
    end)
  end
end
