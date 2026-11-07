defmodule ClinicDemoWeb.A2ui.RosterUITest do
  @moduledoc """
  The roster surface: the gantt's live-diagram contract (it loads from the
  scheduling tables as the acting person, and an empty week renders the bare
  header rather than an error), plus the surface's declaration contract — the
  report runs `plan_week`, the shifts table reads the scheduling resource with
  its state filter, and the candidates table is read-only (no actions: the
  Worklist's four-eyes sign-off is the approval UI).
  """

  use ClinicDemo.DataCase, async: true

  alias AshA2ui.{Diagram, Info, ResolvedView}
  alias ClinicDemoWeb.A2ui.RosterUI

  # A UUID, because a solve's provenance records who asked in a uuid column.
  @staff %{id: "00000000-0000-0000-0000-0000000000dd", role: :veterinarian}

  test "the surface declares the gantt, the plan-a-week report and the two read-only tables" do
    diagrams = Info.diagrams(RosterUI)
    assert [%Diagram{name: :roster_gantt, source: ClinicDemo.Planning.RosterGantt}] = diagrams

    components = Info.components(RosterUI)
    names = Enum.map(components, &{&1.name, &1.as})
    assert {:report, :plan_a_week} in names
    assert {:table, :shifts} in names
    assert {:table, :candidates} in names

    shifts = Enum.find(components, &(&1.name == :table and &1.as == :shifts))
    assert shifts.resource == ClinicDemo.Scheduling.Shift
    assert :starts_at in shifts.fields

    candidates = Enum.find(components, &(&1.name == :table and &1.as == :candidates))
    assert candidates.resource == ClinicDemo.Planning.Candidate
    assert candidates.row_actions == []
    assert candidates.editable in [nil, []]
  end

  test "the gantt loads over an empty week as the bare header, not an error" do
    view = ResolvedView.resolve(RosterUI, actor: @staff)
    loaded = Diagram.load_all(view, %{}, actor: @staff)

    assert %{roster_gantt: %{source: source, state: state}} = loaded
    assert source =~ ~r/^gantt$/m
    assert source =~ "title Clinic roster"
    refute source =~ "section"
    assert state["error"] == ""
    assert state["markers"] == %{}
  end

  test "the gantt draws the week's placed shifts and uncovered appointments" do
    team = ClinicDemo.PlanningFixtures.team!()
    monday = Date.utc_today() |> Date.beginning_of_week() |> Date.add(7)
    type = ClinicDemo.PlanningFixtures.type!("Wellness exam")

    # One covered appointment (an assignment points at it) and one uncovered.
    covered =
      ClinicDemo.PlanningFixtures.book!(monday, 1, {9, 0}, team.head_vet, type: type)

    _uncovered =
      ClinicDemo.PlanningFixtures.book!(monday, 2, {10, 0}, team.head_vet, type: type)

    # A placed shift covering the first appointment — Shift :place is gated on
    # an applied candidate, so the row is written directly; the gantt only reads.
    ClinicDemo.Scheduling.Shift
    |> Ash.Changeset.for_create(:place,
      role: :veterinarian,
      starts_at: DateTime.new!(monday, ~T[08:00:00], "Etc/UTC"),
      ends_at: DateTime.new!(monday, ~T[16:00:00], "Etc/UTC"),
      candidate_id: Ecto.UUID.generate(),
      clinician_id: team.head_vet.id
    )
    |> Ash.create!(authorize?: false)

    ClinicDemo.Scheduling.Assignment
    |> Ash.Changeset.for_create(:place,
      appointment_id: covered.id,
      role: :veterinarian,
      candidate_id: Ecto.UUID.generate(),
      clinician_id: team.head_vet.id
    )
    |> Ash.create!(authorize?: false)

    view = ResolvedView.resolve(RosterUI, actor: @staff)
    loaded = Diagram.load_all(view, %{}, actor: @staff)
    %{source: source, state: state} = loaded.roster_gantt

    assert source =~ "section Dr. Vera Vale"
    assert source =~ ":shift-"
    assert source =~ "section Uncovered appointments"
    assert source =~ ":crit, appt-"
    assert state["error"] == ""
  end
end
