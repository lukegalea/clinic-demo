defmodule ClinicDemoWeb.RevenueSimTest do
  @moduledoc """
  BD-6's LiveView set (design §2g; the BD-6 UX spec's hooks): the knob →
  generate → run → overlay round trip, the overlay's run isolation,
  deep links carrying `as_of` + `run` together, at-rest parity, and badge
  presence.

  The world is deterministic by construction: one back-dated completed
  visit gives the rates a 100% completion cell, and one future scheduled
  visit (same type, same clinician) is the run's only draw — at the
  saturating multiplier every p is 1, so the run always completes the
  visit, exactly, and the overlay's numbers are pinned.
  """

  use ClinicDemoWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

  alias ClinicDemo.BusinessEvents
  alias ClinicDemo.BusinessEvents.Ledger
  alias ClinicDemo.BusinessEvents.Scenarios
  alias ClinicDemo.BusinessEvents.ValueProjector
  alias ClinicDemo.Finance
  alias ClinicDemo.Scheduling
  alias ClinicDemo.Scheduling.AppointmentType

  @staff %{id: "00000000-0000-0000-0000-0000000000d7", role: :veterinarian}

  setup do
    # The projection's events only emit when the mapping rules are
    # deployed (the seeds' install! order, at test scale), and the
    # generator needs the same active mappings.
    BusinessEvents.install!()

    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Sim Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Sim Animal",
          species: :dog,
          owner_email: "sim-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    type =
      AppointmentType
      |> Ash.Changeset.for_create(:create, %{
        name: "Sim Test Visit #{System.unique_integer([:positive])}",
        base_price: Decimal.new("120"),
        default_duration_minutes: 30
      })
      |> Ash.create!(authorize?: false)

    completed_history(patient, vet, type)
    future_visit(patient, vet, type)

    %{vet: vet, patient: patient, type: type}
  end

  defp days_from_now(days),
    do: DateTime.utc_now() |> DateTime.add(days * 86_400, :second) |> DateTime.truncate(:second)

  # The history the rates learn from: three completed visits (the rate
  # chain's `@min_observations 3` floor, cleared). Three completions, zero
  # losses → the clinic-wide completion rate is 1.0, so the saturating
  # multiplier draws the future visit's completion deterministically.
  defp completed_history(patient, vet, type) do
    for days <- [40, 30, 20] do
      completed_visit(patient, vet, type, days)
    end
  end

  defp completed_visit(patient, vet, type, days) do
    booked_at = days_from_now(-(days + 25))
    triaged_at = days_from_now(-(days + 4))
    checked_in_at = days_from_now(-days) |> DateTime.add(-1800, :second)
    completed_at = days_from_now(-days)

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type.id,
          scheduled_at: days_from_now(-(days - 5)),
          duration_minutes: 30,
          reason: "Sim history walk #{days}",
          severity: 2
        },
        actor: @staff,
        as_of: booked_at
      )

    version = Scheduling.get_appointment!(appointment.id, as_of: triaged_at)
    Scheduling.record_appointment_triage!(version, :urgent, actor: @staff, as_of: triaged_at)

    Scheduling.record_weight(patient, Decimal.new("5.0"), actor: @staff)

    version = Scheduling.get_appointment!(appointment.id, as_of: checked_in_at)
    Scheduling.check_in_appointment!(version, actor: @staff, as_of: checked_in_at)

    version = Scheduling.get_appointment!(appointment.id, as_of: completed_at)

    Scheduling.complete_appointment!(version, "Sim history write-up.",
      actor: @staff,
      as_of: completed_at
    )

    # The engine's wall-clock triage write (inside the booking) opened a
    # period at "now" with the pre-walk state; without the present-tense
    # re-assert the visit's CURRENT version would still read :scheduled and
    # the rates would see no evidence (the seeds' own re-assert mechanic).
    open = Scheduling.get_appointment!(appointment.id)

    if open.status == :scheduled do
      open = Scheduling.check_in_appointment!(open, actor: @staff)
      Scheduling.complete_appointment!(open, "Sim history write-up.", actor: @staff)
    end

    appointment
  end

  defp future_visit(patient, vet, type) do
    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          appointment_type_id: type.id,
          scheduled_at: days_from_now(7),
          duration_minutes: 30,
          reason: "Sim future walk",
          severity: 2
        },
        actor: @staff
      )

    appointment
  end

  # ── knob → generate → run → overlay ─────────────────────────────────────

  describe "the scenario round trip" do
    test "knob → generate → the overlay lands as navigation, badged", %{conn: conn} = world do
      {:ok, view, html} = live(conn, ~p"/revenue")

      # At rest: no overlay, no badge, no cyan — the resting page is
      # BD-4's page plus the quiet panel.
      refute html =~ ~s(data-testid="sim-overlay")
      refute html =~ "SIMULATION ·"
      assert html =~ "No scenarios yet — set a multiplier and generate one."

      # The knob: ×1.20, assign only (no patch, no run yet).
      assert render_change(view, "multiplier", %{"scenario" => %{"multiplier" => "1.20"}})
      html = render(view)
      refute String.contains?(html, "run=scenario")

      # Generate: the click guards itself, the async lands, the patch
      # carries the new run.
      render_click(view, "generate")
      # The generate async includes the sim drain (seconds at demo scale);
      # render_async/1's 100ms default is for render-only asyncs.
      render_async(view, 30_000)

      url = assert_patch(view)
      # The label draft prefills on knob change — generate uses it (the
      # spec's §4.4 prefill behavior). The badge carries the same run.
      assert String.contains?(url, "run=")

      html = render(view)

      assert html =~ ~s(data-testid="sim-overlay")
      assert html =~ ~s(data-testid="sim-badge")
      assert html =~ "SIMULATION ·"

      # The drawn visit was completed (the 100% cell at the saturating
      # knob) — its $120 shows in the run's weekly answer.
      assert html =~ "$120"
    end

    test "the ?run= deep link mounts projecting, and the badge carries the run", %{
      conn: conn
    } do
      {:ok, result} = generate_run("1.20", nil)

      future = days_from_now(14) |> DateTime.to_iso8601()
      {:ok, _view, html} = live(conn, "/revenue?as_of=#{future}&run=#{result.run}")

      assert html =~ ~s(data-testid="sim-overlay")
      assert html =~ "SIMULATION · #{result.run}"
      assert html =~ "Projecting — SIM"
    end
  end

  # ── the cursor states ───────────────────────────────────────────────────

  describe "the cursor states" do
    test "future cursor without a run is boringly honest", %{conn: conn} = world do
      ValueProjector.drain(:clinic)

      future = days_from_now(14) |> DateTime.to_iso8601()
      {:ok, _view, html} = live(conn, "/revenue?as_of=#{future}")

      assert html =~ "no scenario selected"
      refute html =~ ~s(data-testid="sim-overlay")
      refute html =~ "SIMULATION ·"
    end

    test "a run + a future cursor project: the chip reads SIM and the cursor numbers show", %{
      conn: conn
    } do
      {:ok, result} = generate_run("1.20", nil)

      future = days_from_now(14) |> DateTime.to_iso8601()
      {:ok, _view, html} = live(conn, "/revenue?as_of=#{future}&run=#{result.run}")

      assert html =~ "Projecting — SIM"
      assert html =~ "Sim recognized"
      assert html =~ "Sim visits remaining after"
    end

    test "history scrub stays history even with a run selected", %{conn: conn} = world do
      {:ok, result} = generate_run("1.20", nil)

      past = days_from_now(5) |> DateTime.to_iso8601()
      {:ok, _view, html} = live(conn, "/revenue?as_of=#{past}&run=#{result.run}")

      assert html =~ "history"
      # The overlay badge rides the forecast card (with a run), but the
      # status chip answers for the cursor.
      assert html =~ "history"
    end
  end

  # ── the edge cases ──────────────────────────────────────────────────────

  describe "the edge cases" do
    test "an unknown run degrades to the live forecast with a flash", %{conn: conn} = world do
      # The stale run degrades as a live_redirect back to the live page,
      # the flash riding the redirect tuple (a follow-up mount of /revenue
      # renders sim-less: no overlay to lie).
      assert {:error, {:live_redirect, %{to: "/revenue", flash: flash}}} =
               live(conn, "/revenue?run=ghost-run")

      assert flash["info"] =~ "That scenario run no longer exists"

      {:ok, _view, html} = live(conn, ~p"/revenue")
      refute html =~ ~s(data-testid="sim-overlay")
    end

    test "run isolation: two runs project their own labels", %{conn: conn} = world do
      {:ok, cautious} = generate_run("0.0", nil)
      {:ok, optimistic} = generate_run("1.20", nil)

      # ×0.0 draws zero completions; ×1.2 (100% cell) draws the visit.
      cautious_summary = Finance.sim_run_summary(cautious.run)
      optimistic_summary = Finance.sim_run_summary(optimistic.run)

      assert Decimal.eq?(cautious_summary.horizon_expected, Decimal.new(0))
      assert Decimal.eq?(optimistic_summary.horizon_expected, Decimal.new("120"))

      # The overlay answers for the selected run, never a blend.
      future = days_from_now(14) |> DateTime.to_iso8601()

      {:ok, _view, html} = live(conn, "/revenue?as_of=#{future}&run=#{optimistic.run}")
      assert html =~ "SIMULATION · #{optimistic.run}"
      assert html =~ "$120"

      {:ok, _view, html} = live(conn, "/revenue?as_of=#{future}&run=#{cautious.run}")
      assert html =~ "SIMULATION · #{cautious.run}"
      refute html =~ "$120"
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────

  defp generate_run(multiplier, label) do
    {:ok,
     Scenarios.generate!(multiplier: Decimal.new(multiplier), label: label, horizon_weeks: 4)}
  end
end
