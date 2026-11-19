defmodule ClinicDemo.Incident.Fixture do
  @moduledoc """
  The documented request of the planted incident, as data.

  Both the incident's tests and `mix clinic.incident book` build their request
  here, so the request in `docs/storyline.md`, the one in
  `docs/evidence/09-trace-explain-incident.md` and the one the tests assert on
  are the same request: **a nurse at the front desk books a routine visit for
  a dog with a veterinarian.**

  The booking is the whole of the demo's front-desk story — it is what
  `README.md` step 8 does — and the nurse is an actor the healthy path has
  always accepted. That is what makes the incident a regression: the first
  suspect is the nurse's permissions, and the first suspect is wrong.

  The fixture writes the veterinarian and the patient it books with, so it runs
  against any database that has the rule documents published
  (`ClinicDemo.Rules.install!/0`) — the test suite's, or a fresh dev database.
  """

  alias ClinicDemo.Scheduling

  # Bare maps, like the seeds and the tests: this demo has no authentication,
  # so the front desk is whoever the caller says it is.
  @admin %{id: "00000000-0000-0000-0000-0000000000a1", role: :veterinarian}
  @front_desk %{id: "00000000-0000-0000-0000-0000000000a2", role: :nurse}

  @type t :: %{
          actor: map(),
          params: map(),
          veterinarian: struct(),
          patient: struct()
        }

  @doc "The actor that books: a nurse at the front desk."
  @spec front_desk() :: map()
  def front_desk, do: @front_desk

  @doc """
  Registers the veterinarian and the patient, and returns the request ready to
  send: `%{actor: front_desk, params: booking_params, ...}`.
  """
  @spec prepare!() :: t()
  def prepare! do
    unique = System.unique_integer([:positive])

    veterinarian =
      Scheduling.hire_clinician!(
        %{
          full_name: "Dr. Incident Vet #{unique}",
          role: :veterinarian,
          license_number: "ON-#{100_000 + rem(unique, 899_999)}"
        },
        actor: @admin
      )

    patient =
      Scheduling.register_patient!(
        %{name: "Biscuit", species: :dog, owner_email: "biscuit-#{unique}@example.com"},
        actor: @admin
      )

    %{
      actor: @front_desk,
      veterinarian: veterinarian,
      patient: patient,
      params: %{
        patient_id: patient.id,
        clinician_id: veterinarian.id,
        scheduled_at: DateTime.add(DateTime.utc_now(), 1, :day),
        reason: "Limping on the right foreleg",
        severity: 2
      }
    }
  end

  @doc "Sends the documented request: `ClinicDemo.Scheduling.book_appointment/2`."
  @spec book(t()) :: {:ok, struct()} | {:error, Exception.t()}
  def book(%{params: params, actor: actor}), do: Scheduling.book_appointment(params, actor: actor)
end
