defmodule ClinicDemo.Compliance.AppointmentFactsTest do
  @moduledoc """
  The compliance badge's two halves, tested where each lives:

    * the fact builder — an appointment record becomes the exact triples the
      active bundle's fact schema declares, under the string subject the
      post-compile rules probe;
    * the badge data path — the batched page statuses (the row badge's
      values) and the a2ui row-layout serialization that turns a status into
      the `_badge_compliance_status` payload the catalog's badge anatomy
      renders.
  """

  use ClinicDemo.DataCase, async: true

  alias AshA2ui.Info
  alias ClinicDemo.Compliance
  alias ClinicDemo.Compliance.AppointmentFacts
  alias ClinicDemo.Scheduling

  @staff %{id: "00000000-0000-0000-0000-0000000000cc", role: :veterinarian}

  # --- the fact builder -----------------------------------------------------------

  describe "AppointmentFacts.facts/2" do
    setup do
      Compliance.activate_appointment_bundle!()
      :ok
    end

    test "emits the schema-declared predicates under the string subject" do
      appointment = booked(weight: Decimal.new("4.2"))

      facts = AppointmentFacts.facts(appointment, transition_to: :checked_in)

      assert {"appointment", :transition_to, :checked_in} in facts
      assert {"appointment", :patient_weight_recorded, true} in facts
      # Every booking runs the triage decision, so a fresh row has an answer.
      assert {"appointment", :has_triage_urgency, true} in facts
      assert {"appointment", :has_notes, false} in facts
    end

    test "the weight predicate is false while the patient has no weight on record" do
      appointment = booked(weight: nil)

      assert {"appointment", :patient_weight_recorded, false} in AppointmentFacts.facts(
               appointment,
               transition_to: :checked_in
             )
    end

    test "facts build from a record with :patient not loaded (headless fallback)" do
      appointment = booked(weight: Decimal.new("4.2"))
      bare = Map.put(appointment, :patient, %Ash.NotLoaded{})

      assert {"appointment", :patient_weight_recorded, true} in AppointmentFacts.facts(
               bare,
               transition_to: :checked_in
             )
    end

    test "notes blank is not notes present" do
      appointment = booked(weight: Decimal.new("4.2"))
      appointment = Map.put(appointment, :notes, "")

      assert {"appointment", :has_notes, false} in AppointmentFacts.facts(
               appointment,
               transition_to: :completed
             )
    end
  end

  # --- the badge values ------------------------------------------------------------

  describe "the batched status page" do
    setup do
      Compliance.activate_appointment_bundle!()
      :ok
    end

    test "a visit the bundle would refuse checks in as noncompliant; a clean one as compliant" do
      unweighed = booked(weight: nil)
      clean = booked(weight: Decimal.new("4.2"))

      assert Compliance.appointment_status_page([unweighed, clean]) == [
               :noncompliant,
               :compliant
             ]
    end

    test "a bare record (no preloaded patient) still gets a status, via the fallback load" do
      clean = booked(weight: Decimal.new("4.2"))
      bare = Map.put(clean, :patient, %Ash.NotLoaded{})

      assert Compliance.appointment_status_page([bare]) == [:compliant]
    end
  end

  describe "with no bundle in force" do
    test "absence reads as :no_rules, never as compliance" do
      # No activation in this describe: a fresh sandbox has no active bundle,
      # which is the pre-seed state the demo boots in.
      appointment = booked(weight: Decimal.new("4.2"))

      assert Compliance.appointment_status_page([appointment]) == [:no_rules]
    end
  end

  # --- the badge data path -----------------------------------------------------------

  describe "the row badge on the appointment surfaces" do
    setup do
      Compliance.activate_appointment_bundle!()
      :ok
    end

    test "the resource calculation returns the badge atom through a plain load" do
      appointment = booked(weight: nil)

      assert Ash.load!(appointment, :compliance_status).compliance_status == :noncompliant
    end

    test "the board and schedule row layouts badge the status into the wire payload" do
      appointment = Ash.load!(booked(weight: nil), :compliance_status)

      for surface <- [ClinicDemoWeb.A2ui.BoardUI, ClinicDemoWeb.A2ui.AppointmentUI] do
        layout =
          surface
          |> Info.components()
          |> Enum.find(&(&1.name == :table))
          |> Map.get(:row_layout)

        assert layout.badge == :compliance_status

        assert AshA2ui.RowLayout.badge_data(layout, appointment) == %{
                 "_badge_compliance_status" => "Noncompliant"
               }
      end
    end

    test "retiring the active bundle flips the badge to :no_rules" do
      appointment = booked(weight: Decimal.new("4.2"))
      assert Ash.load!(appointment, :compliance_status).compliance_status == :compliant

      {:ok, bundle} =
        AshCompliance.Domain.active_policy_bundle(Compliance.organization_id(), authorize?: false)

      AshCompliance.Domain.retire_policy_bundle!(bundle, authorize?: false)

      assert Ash.load!(appointment, :compliance_status).compliance_status == :no_rules
    end
  end

  # --- fixtures -----------------------------------------------------------------

  # A booked appointment for a freshly registered patient, optionally
  # weighed. Booking runs the triage decision itself, so the row always has
  # a triage answer — the state the seeded rules exist to police.
  defp booked(opts) do
    weight = Keyword.get(opts, :weight)

    {:ok, vet} =
      Scheduling.hire_clinician(
        %{
          full_name: "Dr. Badge Vet",
          role: :veterinarian,
          license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
        },
        actor: @staff
      )

    {:ok, patient} =
      Scheduling.register_patient(
        %{
          name: "Badge Animal",
          species: :dog,
          owner_email: "badge-#{System.unique_integer([:positive])}@example.com"
        },
        actor: @staff
      )

    if weight, do: Scheduling.record_weight!(patient, weight, actor: @staff)

    appointment =
      Scheduling.book_appointment!(
        %{
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Badge check"
        },
        actor: @staff
      )

    # Fresh read, as every real caller would: the visit process records the
    # triage answer after booking returns, so the returned struct is stale.
    Scheduling.get_appointment!(appointment.id)
  end
end
