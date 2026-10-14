defmodule ClinicDemo.Scheduling.Changes.RecognizeCharge do
  @moduledoc """
  The finance half of a write-up: a completed visit with a catalogue type
  recognizes its charge, in the same transaction as the completion itself.

  Three properties worth naming:

  **Same transaction, same instant.** The charge is created in an
  `after_action` hook, so a visit and its money exist together or not at
  all — a write-up that completed while its charge failed is a revenue hole
  nobody would notice until month-end. The charge's `as_of` is the
  completion's own `as_of`, so `recognized_at` lands where the visit's
  history says the write-up happened, and the temporal reads agree: the
  revenue as of T includes exactly the visits written up by T.

  **One charge per visit, ever.** The seeds (and any temporal replay) may
  walk `:complete` twice for one appointment — a back-dated write-up plus
  the re-assert that gives the present its final state. The clinic charges
  for the visit, not for each retelling of it, so the hook steps aside when
  a charge for the appointment already exists. (`:complete` can otherwise
  only run once: the state machine has no way back out of `:completed`.)

  **No type, no charge.** Visits booked without a catalogue entry simply
  recognize nothing — the demo's pre-catalogue visits, and any manual
  booking the front desk skipped the price list on.
  """

  use Ash.Resource.Change

  alias ClinicDemo.Finance
  alias ClinicDemo.Scheduling.AppointmentType

  # Temporal safety (declared): the hook reads no clock of its own — the
  # charge's instant is the write's `as_of`, already resolved onto the
  # changeset, and the catalogue lookup is a non-temporal read of the same
  # row the caller's booking pointed at. Nothing here decides anything from
  # "now".
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, appointment ->
      recognize(changeset, appointment)
    end)
  end

  defp recognize(_changeset, %{appointment_type_id: nil} = appointment), do: {:ok, appointment}

  defp recognize(changeset, appointment) do
    if Finance.charge_for(appointment.id) do
      {:ok, appointment}
    else
      create_charge(changeset, appointment)
    end
  end

  defp create_charge(changeset, appointment) do
    type = Ash.get!(AppointmentType, appointment.appointment_type_id, authorize?: false)

    # The as_of rides the changeset build, not the create call: a
    # changeset's temporal instant is settled when the action validates,
    # and re-passing it later is refused (`OptionAlreadySet`) rather than
    # silently rewritten.
    Finance.Charge
    |> Ash.Changeset.for_create(
      :recognize,
      %{
        amount: type.base_price,
        appointment_id: appointment.id,
        recognized_at: recognition_instant(changeset)
      },
      as_of: changeset.as_of
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, _charge} -> {:ok, appointment}
      {:error, reason} -> {:error, reason}
    end
  end

  # The completion's own instant — `as_of` when the write was back-dated
  # (the seeded history), now when it was not. Same rule the temporal
  # machinery itself uses to start the period.
  defp recognition_instant(changeset) do
    case changeset.as_of do
      %DateTime{} = as_of -> as_of
      _ -> DateTime.utc_now()
    end
  end
end
