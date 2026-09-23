defmodule ClinicDemo.Visits.VisitFacadeTest do
  @moduledoc """
  The `via` delegation behind the board's and the schedule's check-in and
  no-show row actions.

  The claim under test: the surfaces' buttons work *through* the engine.
  A via check-in completes the visit's open `CheckIn` work item, the token
  advances, and it is the engine's invoker that calls the appointment
  action — so after a via check-in there is no open CheckIn task left and
  the appointment is `:checked_in`. Compliance still guards: a weightless
  patient's transition is refused with the rule bundle's gap message.
  """

  use ClinicDemo.DataCase, async: false

  require Ash.Query

  alias ClinicDemo.Scheduling
  alias ClinicDemo.Compliance
  alias ClinicDemo.Visits.HumanTask
  alias ClinicDemo.Visits.Instance
  alias ClinicDemo.Visits.VisitFacade

  @staff %{id: "00000000-0000-0000-0000-0000000000dd", role: :veterinarian}

  setup do
    # The board's rules are in force, as the seeds leave the demo.
    Compliance.activate_appointment_bundle!()
    :ok
  end

  defp roster do
    {:ok, vet} =
      Scheduling.hire_clinician(%{
        full_name: "Dr. Facade Vet",
        role: :veterinarian,
        license_number: "ON-#{:rand.uniform(899_999) + 100_000}"
      })

    {:ok, nurse} = Scheduling.hire_clinician(%{full_name: "Facade Nurse", role: :nurse})

    %{vet: vet, nurse: nurse}
  end

  defp book_with_weight(vet, weight?) do
    {:ok, patient} =
      Scheduling.register_patient(%{
        name: "Facade Animal",
        species: :dog,
        owner_email: "owner-#{System.unique_integer([:positive])}@example.com"
      })

    if weight?, do: {:ok, _} = Scheduling.record_weight(patient, Decimal.new("9.1"))

    {:ok, appointment} =
      Scheduling.book_appointment(
        %{
          # Booked the new way: the patient named as a nested create, as the
          # intake form submits it. (This booking keeps the registered one —
          # the record needs a weight, so it was weighed above.)
          patient_id: patient.id,
          clinician_id: vet.id,
          scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
          reason: "Via delegation drill"
        },
        actor: @staff
      )

    %{patient: patient, appointment: appointment}
  end

  defp via_ctx(appointment, action, actor) do
    %{record: Scheduling.get_appointment!(appointment.id), action: action, actor: actor}
  end

  defp open_check_in_task(appointment) do
    instance =
      Instance
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(subject_id == ^appointment.id)
      |> Ash.read_one!()

    HumanTask
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      instance_id == ^instance.id and node_id == "CheckIn" and status in [:open, :claimed]
    )
    |> Ash.read_one!()
  end

  test "via check_in completes the CheckIn task and leaves it behind" do
    %{nurse: nurse} = roster()
    %{appointment: appointment} = book_with_weight(roster().vet, true)

    assert open_check_in_task(appointment)

    assert {:ok, %Scheduling.Appointment{} = checked_in} =
             VisitFacade.check_in_task(via_ctx(appointment, :check_in, nurse), "board")

    assert checked_in.status == :checked_in

    # The token advanced: no open CheckIn work item is left standing.
    refute open_check_in_task(appointment)
  end

  test "via mark_no_show routes the :no_show outcome through the engine" do
    %{vet: vet, nurse: nurse} = roster()
    %{appointment: appointment} = book_with_weight(vet, true)

    assert {:ok, marked} =
             VisitFacade.check_in_task(via_ctx(appointment, :mark_no_show, nurse), "schedule")

    assert marked.status == :no_show
    refute open_check_in_task(appointment)
  end

  test "compliance still guards: a weightless patient's via check_in is refused" do
    %{vet: vet, nurse: nurse} = roster()
    %{appointment: appointment} = book_with_weight(vet, false)

    assert {:error, error} =
             VisitFacade.check_in_task(via_ctx(appointment, :check_in, nurse), "board")

    message = Exception.message(error)
    assert message =~ "appt.checkin_requires_weight"

    # The transition never happened.
    assert Scheduling.get_appointment!(appointment.id).status == :scheduled
  end

  test "with no open CheckIn task the facade falls back to the direct action" do
    %{vet: vet, nurse: nurse} = roster()
    %{appointment: appointment} = book_with_weight(vet, true)

    # Empty the queue the hard way: the engine path runs once, so the
    # second call finds no open task and takes the fallback.
    assert {:ok, _} = VisitFacade.check_in_task(via_ctx(appointment, :check_in, nurse), "board")

    assert {:error, %Ash.Error.Invalid{}} =
             VisitFacade.check_in_task(via_ctx(appointment, :check_in, nurse), "board")

    # The refusal is the direct action's status guard, not a crash.
    assert Scheduling.get_appointment!(appointment.id).status == :checked_in
  end
end
