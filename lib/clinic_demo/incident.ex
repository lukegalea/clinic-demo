defmodule ClinicDemo.Incident do
  @moduledoc """
  The planted incident (CLIN-33): a policy misconfiguration that makes a
  booking fail with a confusing error, behind a switch.

  The demo's debugging chapter (`docs/storyline.md`, "The planted incident")
  needs something real to debug. This module is that something, and it is
  deliberately inert: with no incident switched on nothing in the application
  behaves any differently — the one policy that reads the switch does not
  apply.

  ## The one incident

  `:triage_vet_only` — someone tightened the `Appointment.record_triage` policy
  so that only a veterinarian may write a triage answer. `record_triage` is not
  something a person calls at the front desk: it is the `RecordUrgency` service
  task of the visit process, and the engine runs it as a system actor
  (`AshBpmn.SystemActor`, `:advance`) — not a veterinarian, not even a person.
  So `:book` passes its own policy, the booking transaction starts the visit
  process, the process asks the triage decision, tries to write the answer
  down — and is refused. `StartVisitProcess` reports it as
  `could not start the visit process: ...`, a sentence that points at the
  process engine, not at a policy two layers down. Every booking fails, a
  veterinarian's included, which is the first clue that the person booking is
  not the problem.

  With the switch off, behaviour is exactly the healthy one.

  ## The switch

  Three equivalent ways, all reading the one application-env key:

    * `CLINIC_INCIDENT=triage_vet_only` in the environment, read by
      `config/runtime.exs` when the application boots;
    * `ClinicDemo.Incident.enable!(:triage_vet_only)` and `disable!/0` from
      code (the tests, `iex`);
    * `mix clinic.incident book --incident triage_vet_only` for one
      documented request.

  ## The documented request and the documented fix

  `ClinicDemo.Incident.Fixture` builds the request the docs walk through; the
  documented fix is rolling the switch back (`disable!/0`, or unset the
  environment variable). The durable fix the walkthrough argues for is in the
  evidence document.
  """

  @key :incident

  @incidents %{
    triage_vet_only: %{
      summary:
        "Appointment.record_triage was restricted to veterinarians; the visit process " <>
          "records triage as a system actor, so every booking is refused.",
      symptom: "could not start the visit process",
      cause: "the :triage_vet_only policy on ClinicDemo.Scheduling.Appointment",
      fix: "roll the switch back: ClinicDemo.Incident.disable!/0 or unset CLINIC_INCIDENT"
    }
  }

  @type key :: :triage_vet_only

  @doc "Every incident this application can plant."
  @spec known() :: [key()]
  def known, do: Map.keys(@incidents)

  @doc "What an incident is, what it looks like, and how it is fixed."
  @spec describe(key()) :: %{
          summary: String.t(),
          symptom: String.t(),
          cause: String.t(),
          fix: String.t()
        }
  def describe(key), do: Map.fetch!(@incidents, key)

  @doc """
  The incident currently switched on, or `nil`.

  The environment-variable form arrives as a string; it is matched against the
  known keys rather than turned into an atom, so a mistyped value is inert
  instead of a surprise.
  """
  @spec active() :: key() | nil
  def active do
    case Application.get_env(:clinic_demo, @key) do
      nil -> nil
      key when is_atom(key) -> if Map.has_key?(@incidents, key), do: key
      name when is_binary(name) -> Enum.find(known(), &(Atom.to_string(&1) == name))
    end
  end

  @doc "Whether that incident is the one switched on."
  @spec active?(key()) :: boolean()
  def active?(key), do: active() == key

  @doc "Switches an incident on for this VM."
  @spec enable!(key()) :: :ok
  def enable!(key) do
    unless Map.has_key?(@incidents, key) do
      raise ArgumentError,
            "unknown incident #{inspect(key)}; known: #{inspect(known())}"
    end

    Application.put_env(:clinic_demo, @key, key)
  end

  @doc "Switches every incident off. This is the documented fix."
  @spec disable!() :: :ok
  def disable!, do: Application.delete_env(:clinic_demo, @key)
end
