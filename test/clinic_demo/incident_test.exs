defmodule ClinicDemo.IncidentTest do
  @moduledoc """
  The planted incident (CLIN-33), end to end: a nurse's booking fails with a
  confusing error, the trace names why, and the documented fix makes the same
  request succeed.

  The three acceptance criteria are `describe` blocks named for their ids (the
  repo's convention, see `UPD-EXTRACT-VERIFY/AC-1`), and each runs the *same*
  documented request from `ClinicDemo.Incident.Fixture`:

    * `CLIN-33/AC-1` — incident on: the request fails with the planted symptom.
    * `CLIN-33/AC-2` — `AshAgentTools.Trace.explain/2` over that request's
      spans names the planted cause.
    * `CLIN-33/AC-3` — the documented fix (`ClinicDemo.Incident.disable!/0`):
      the request succeeds.

  `async: false` because the switch is application env: ExUnit runs every
  synchronous module after the asynchronous ones, so no concurrent test ever
  sees the incident on, and `on_exit` puts the switch back regardless.
  """

  use ClinicDemo.DataCase, async: false

  alias ClinicDemo.Events.Event
  alias ClinicDemo.Incident
  alias ClinicDemo.Incident.Fixture
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.Appointment
  alias ClinicDemo.Trace

  setup do
    on_exit(&Incident.disable!/0)
    %{fixture: Fixture.prepare!()}
  end

  defp book_traced(fixture),
    do: Trace.capture("book_appointment", fn -> Fixture.book(fixture) end)

  defp event_log,
    do: Event |> Ash.Query.sort(:id) |> Ash.Query.load(:what) |> Ash.read!(authorize?: false)

  describe "CLIN-33/AC-1: incident enabled, the documented request fails with the planted symptom" do
    # ac: CLIN-33/AC-1
    test "the booking is refused with the visit-process error, not a policy error", %{
      fixture: fixture
    } do
      Incident.enable!(:triage_vet_only)

      assert {:error, %Ash.Error.Invalid{} = error} = Fixture.book(fixture)

      # The symptom: the front desk is told the *process* could not start —
      # the action the nurse called passed its own policy.
      assert Exception.message(error) =~ "could not start the visit process"
      assert Exception.message(error) =~ "Forbidden"
    end

    test "the failure commits nothing: no appointment, no event-log row", %{fixture: fixture} do
      Incident.enable!(:triage_vet_only)
      events_before = length(event_log())

      assert {:error, _} = Fixture.book(fixture)

      assert Appointment |> Ash.read!(authorize?: false) |> Enum.empty?()
      assert length(event_log()) == events_before
    end

    test "the person booking is not the problem: a veterinarian's booking fails too", %{
      fixture: fixture
    } do
      Incident.enable!(:triage_vet_only)
      veterinarian = %{id: Ash.UUID.generate(), role: :veterinarian}

      assert {:error, error} = Fixture.book(%{fixture | actor: veterinarian})
      assert Exception.message(error) =~ "could not start the visit process"
    end
  end

  describe "CLIN-33/AC-2: Trace.explain on the failing correlation id names the planted cause" do
    # ac: CLIN-33/AC-2
    test "the report's policy section names the refusing policy and the incident", %{
      fixture: fixture
    } do
      Incident.enable!(:triage_vet_only)

      %{result: {:error, _}, correlation_id: correlation_id, spans: spans} =
        book_traced(fixture)

      report = AshAgentTools.Trace.explain(spans)

      assert report.summary.trace_id == correlation_id
      refute report.truncated?

      # The planted cause, in the report's own words: the policy, the action it
      # sits on, and the switch that makes it apply.
      assert [policy] = report.policy
      assert policy.name == "ash.policy ClinicDemo.Scheduling.Appointment.record_triage"
      assert policy.decision =~ "only a veterinarian may record it"
      assert policy.decision =~ ":triage_vet_only incident is switched on"

      # ...and who was refused: the engine, not the person who booked.
      assert policy.decision =~ "actor ash_bpmn:advance"

      # Innermost first: the refusal, the write it refused, then the two
      # layers the front desk actually saw.
      assert Enum.map(report.errors, & &1.name) == [
               "ash.policy ClinicDemo.Scheduling.Appointment.record_triage",
               "scheduling:appointment.record_triage",
               "scheduling:appointment.book",
               "request book_appointment"
             ]

      assert List.last(report.errors).message =~ "could not start the visit process"
    end
  end

  describe "CLIN-33/AC-3: the documented fix applied, the request succeeds" do
    # ac: CLIN-33/AC-3
    test "rolling the switch back lets the same nurse book the same visit", %{fixture: fixture} do
      Incident.enable!(:triage_vet_only)
      assert {:error, _} = Fixture.book(fixture)

      Incident.disable!()

      %{result: result, spans: spans} = book_traced(fixture)

      assert {:ok, booked} = result
      assert Scheduling.get_appointment!(booked.id).triage_urgency == :urgent

      report = AshAgentTools.Trace.explain(spans)
      assert report.errors == []
      assert report.policy == []
    end
  end

  describe "the walkthrough's other tools" do
    test "explain_forbidden lists the planted policy among those that can deny record_triage" do
      report = AshAgentTools.explain_forbidden(Appointment, :record_triage)

      assert %{condition: condition, checks: checks} =
               Enum.find(report.policies, &(&1.description =~ "veterinarian's judgement"))

      assert "action == :record_triage" in condition
      assert Enum.any?(condition, &(&1 =~ ":triage_vet_only"))
      assert Enum.any?(checks, &(&1 =~ "veterinarian"))
    end

    test "the healthy booking's event log is the reference the failed one is read against", %{
      fixture: fixture
    } do
      events_before = length(event_log())
      assert {:ok, _} = Fixture.book(fixture)

      written =
        event_log()
        |> Enum.drop(events_before)
        |> Enum.map(& &1.what)

      assert "create on Elixir.ClinicDemo.Decisions.Evaluation" in written
      assert "record_triage on Elixir.ClinicDemo.Scheduling.Appointment" in written
    end
  end

  describe "the switch" do
    test "is off by default, and unknown names are inert or refused" do
      refute Incident.active()

      Application.put_env(:clinic_demo, :incident, "not_an_incident")
      refute Incident.active()

      Application.put_env(:clinic_demo, :incident, "triage_vet_only")
      assert Incident.active?(:triage_vet_only)

      assert_raise ArgumentError, ~r/unknown incident/, fn -> Incident.enable!(:nope) end
    end
  end
end
