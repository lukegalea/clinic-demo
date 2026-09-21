defmodule ClinicDemo.Visits.Roster do
  @moduledoc """
  Who a human task is for, answered from the `Clinician` table.

  Candidate specs are opaque to `ash_bpmn` — `kind="role" of="nurse"` means
  whatever this module says it means. Here it means an active clinician with
  that role, read live, so retiring somebody takes them off tomorrow's task
  lists without anybody editing a diagram.

  Two kinds, which is all the visit process needs:

    * `role` — every active clinician in that role.
    * `booked_clinician` — the one person the appointment names. `of` is a FEEL
      path into the subject, and this module resolves it the way the rest of the
      demo does: as a field of the appointment.
  """

  @behaviour AshBpmn.AssignmentResolver

  require Ash.Query

  require Logger

  alias ClinicDemo.Scheduling.Clinician

  @roles ~w(veterinarian technician nurse)

  @impl true
  def candidates(specs, ctx) do
    {:ok, specs |> Enum.flat_map(&resolve(&1, ctx)) |> Enum.uniq()}
  end

  @impl true
  def exclusions(specs, ctx) do
    {:ok, specs |> Enum.flat_map(&exclude(&1, ctx)) |> Enum.uniq()}
  end

  @impl true
  def escalate(task, _ctx) do
    # A real clinic pages somebody. The demo records the intent; the timer
    # worker has already written the event that says the clock ran out.
    Logger.info("escalating visit task #{task.id} (#{task.name})")
    :ok
  end

  defp resolve(%{"kind" => "role", "of" => role}, _ctx) when role in @roles do
    role = String.to_existing_atom(role)

    Clinician
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(active == true and role == ^role)
    |> Ash.read!()
    |> Enum.map(&%{type: :user, id: &1.id})
  end

  defp resolve(%{"kind" => "booked_clinician", "of" => path}, ctx) do
    case subject_field(ctx, path) do
      nil -> []
      id -> [%{type: :user, id: id}]
    end
  end

  defp resolve(_spec, _ctx), do: []

  defp exclude(%{"who" => path}, ctx), do: List.wrap(subject_field(ctx, path))
  defp exclude(_spec, _ctx), do: []

  # `ash_bpmn` never interprets these strings itself. Reading them as a field of
  # the subject is this host's convention, and `to_existing_atom` keeps a string
  # out of the database from minting an atom.
  defp subject_field(ctx, path) do
    field =
      path
      |> to_string()
      |> String.replace_prefix("subject.", "")
      |> String.to_existing_atom()

    case Map.get(ctx, :subject) do
      nil -> nil
      subject -> Map.get(subject, field)
    end
  rescue
    ArgumentError -> nil
  end
end
