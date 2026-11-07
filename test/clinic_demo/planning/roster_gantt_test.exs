defmodule ClinicDemo.Planning.RosterGanttTest do
  @moduledoc """
  The `/roster` gantt's diagram text, pure: `RosterGantt.gantt/3` takes plain
  bar maps and must emit a mermaid gantt whose sections, bar ids and the
  uncovered-appointments band read honestly. The read side (shifts,
  appointments, assignments) is exercised by the roster surface test and the
  browser demo; this file pins the emitted text.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.Planning.RosterGantt

  @monday ~D[2026-11-09]

  defp shift_bar(id, clinician, hour, hours, opts \\ []) do
    %{
      id: id,
      clinician: clinician,
      label: Keyword.get(opts, :label, "veterinarian shift"),
      start: DateTime.new!(@monday, Time.new!(hour, 0, 0), "Etc/UTC"),
      seconds: hours * 3600
    }
  end

  defp appointment_bar(id, label, hour, minutes) do
    %{
      id: id,
      label: label,
      start: DateTime.new!(@monday, Time.new!(hour, 0, 0), "Etc/UTC"),
      seconds: minutes * 60
    }
  end

  test "an empty week renders the bare header and no sections" do
    source = RosterGantt.gantt(@monday, [], [])

    assert source =~ ~r/^gantt$/m
    assert source =~ "title Clinic roster — week of Monday 2026-11-09"
    assert source =~ "dateFormat X"
    refute source =~ "section"
  end

  test "one clinician and one shift: a section with the bar at its epoch start" do
    bar =
      shift_bar("11111111-1111-1111-1111-111111111111", "Dr. Vera Vale", 8, 8)

    source = RosterGantt.gantt(@monday, [bar], [])

    assert source =~ "section Dr. Vera Vale"
    # 2026-11-09 08:00 UTC as unix seconds, the gantt bar's start.
    start = DateTime.to_unix(DateTime.new!(@monday, ~T[08:00:00], "Etc/UTC"))

    assert source =~
             "veterinarian shift :shift-11111111-1111-1111-1111-111111111111, #{start}, 28800"
  end

  test "one uncovered appointment: a crit bar in the Uncovered appointments section" do
    bar = appointment_bar("22222222-2222-2222-2222-222222222222", "Bella Wellness exam", 10, 30)

    source = RosterGantt.gantt(@monday, [], [bar])

    coverage =
      source
      |> String.split("section Uncovered appointments", parts: 2)
      |> List.last()

    start = DateTime.to_unix(DateTime.new!(@monday, ~T[10:00:00], "Etc/UTC"))

    assert coverage =~
             "Bella Wellness exam :crit, appt-22222222-2222-2222-2222-222222222222, #{start}, 1800"
  end

  test "clinician sections come in first-bar order, coverage section last" do
    early = shift_bar("a1", "Dr. Early Person", 7, 8)
    late = shift_bar("a2", "Dr. Late Person", 9, 8)
    uncovered = appointment_bar("b1", "Nail trim", 12, 30)

    source = RosterGantt.gantt(@monday, [late, early], [uncovered])

    assert source =~
             ~r/section Dr\. Early Person.*section Dr\. Late Person.*section Uncovered appointments/s

    # The early bar sits inside the first section; the late one in the second.
    [_, first, rest] = String.split(source, "section ", parts: 3)
    assert first =~ "veterinarian shift :shift-a1"
    assert rest =~ "veterinarian shift :shift-a2"
    assert rest =~ ":crit, appt-b1"
  end

  test "labels with colons are escaped so the task line survives" do
    bar = shift_bar("c1", "Dr. Semi: Colon", 8, 8)

    source = RosterGantt.gantt(@monday, [bar], [])

    assert source =~ "section Dr. Semi Colon"
    assert source =~ "veterinarian shift :shift-c1"
  end
end
