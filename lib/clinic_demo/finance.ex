defmodule ClinicDemo.Finance do
  @moduledoc """
  The clinic's money: charges recognized by completed visits, and the reads
  the revenue view is built on.

  One resource today — `Finance.Charge`, recognized by an after-action hook
  on `Appointment.complete` (same transaction, same `as_of` instant). This
  module is also the context layer for the feature: the code interface the
  hook and the surfaces call, plus the read helpers that turn the temporal
  stores into the plain rows `Finance.Forecast` and `RevenueLive` consume.
  The helpers are ordinary Ash reads — no raw SQL — grouped in Elixir, which
  at the demo's scale (a few thousand rows) is simpler and honest.

  Revenue-at-T is an as-of read, exactly like the board's time travel: a
  charge exists from its `recognized_at` (its period's lower bound) onward,
  so `list_charges(as_of: t)` answers "what had the clinic recognized by
  instant t".
  """

  use Ash.Domain

  require Ash.Query

  alias ClinicDemo.Finance.Charge
  alias ClinicDemo.Scheduling.Appointment

  resources do
    resource ClinicDemo.Finance.Charge do
      define :list_charges, action: :read
      define :get_charge, action: :read, get_by: [:id]
      define :recognize_charge, action: :recognize
      define :write_off_charge, action: :write_off
    end
  end

  @doc """
  Recognized revenue by calendar month: the paid charges whose
  `recognized_at` falls in each of the last `months` calendar months,
  oldest first. The running month counts — a partial month is shown as
  one, the way the clinic actually experiences it.

  Read as of now, so a charge back-dated by the seeds sits in the month its
  recognition took effect at. A month with no charges still gets a row
  (zero total), so the chart's x-axis does not depend on the data's shape.
  """
  @spec revenue_by_month(pos_integer()) :: [
          %{month: Date.t(), total: Decimal.t(), count: non_neg_integer()}
        ]
  def revenue_by_month(months) when is_integer(months) and months > 0 do
    month_starts =
      for offset <- (months - 1)..0 do
        Date.utc_today() |> Date.beginning_of_month() |> shift_month(-offset)
      end

    window_start = DateTime.new!(hd(month_starts), ~T[00:00:00], "Etc/UTC")

    charges =
      Charge
      |> Ash.Query.filter(status == :paid and recognized_at >= ^window_start)
      |> Ash.read!(authorize?: false)

    for month <- month_starts do
      from = DateTime.new!(month, ~T[00:00:00], "Etc/UTC")
      to = DateTime.new!(shift_month(month, 1), ~T[00:00:00], "Etc/UTC")

      in_month = Enum.filter(charges, &(&1.recognized_at >= from and &1.recognized_at < to))

      total =
        Enum.reduce(in_month, Decimal.new(0), &Decimal.add(&2, &1.amount))

      %{month: month, total: total, count: length(in_month)}
    end
  end

  # Calendar-month shift without third-party date libs: walk `months` month
  # boundaries from the first of `date`'s month. Negative goes back.
  defp shift_month(%Date{} = date, months) do
    total = date.year * 12 + (date.month - 1) + months
    year = div(total, 12)
    month = rem(total, 12) + 1
    %Date{year: year, month: month, day: 1}
  end

  @doc """
  The lifecycle outcomes behind the forecast's rates: every appointment with
  a catalogue type, as plain rows.

  A row carries the three dimensions a rate cell is keyed on (type,
  clinician, weekday) plus which state the visit reached — `:completed`,
  `:cancelled`, `:no_show`, or `:open` (still ahead of us, so it has no
  outcome to teach the forecast yet).
  """
  @spec historical_outcomes(keyword()) :: [
          %{
            appointment_type_id: Ecto.UUID.t(),
            clinician_id: Ecto.UUID.t(),
            weekday: 1..7,
            outcome: :completed | :cancelled | :no_show | :open
          }
        ]
  def historical_outcomes(opts \\ []) do
    query =
      Appointment
      |> Ash.Query.filter(not is_nil(appointment_type_id))

    query =
      case Keyword.fetch(opts, :since) do
        {:ok, %DateTime{} = since} -> Ash.Query.filter(query, scheduled_at >= ^since)
        :error -> query
      end

    query
    |> Ash.read!(authorize?: false)
    |> Enum.map(fn appointment ->
      %{
        appointment_type_id: appointment.appointment_type_id,
        clinician_id: appointment.clinician_id,
        weekday: Date.day_of_week(DateTime.to_date(appointment.scheduled_at)),
        outcome: outcome(appointment)
      }
    end)
  end

  defp outcome(%{status: :completed}), do: :completed
  defp outcome(%{status: :cancelled}), do: :cancelled
  defp outcome(%{status: :no_show}), do: :no_show
  defp outcome(%{status: _in_flight}), do: :open

  @doc """
  The forecast's positive side: every appointment still `:scheduled` in the
  next `weeks` weeks, with its type (and so its price) resolved.

  `amount` is the price the visit would recognize on completion — read from
  the catalogue now, the same place a real completion would snapshot from.
  """
  @spec scheduled_with_prices(pos_integer()) :: [
          %{
            id: Ecto.UUID.t(),
            appointment_type_id: Ecto.UUID.t(),
            clinician_id: Ecto.UUID.t(),
            scheduled_at: DateTime.t(),
            amount: Decimal.t()
          }
        ]
  def scheduled_with_prices(weeks) when is_integer(weeks) and weeks > 0 do
    now = DateTime.utc_now()
    horizon = DateTime.add(now, weeks * 7 * 24 * 3600, :second)

    Appointment
    |> Ash.Query.filter(status == :scheduled and scheduled_at >= ^now and scheduled_at < ^horizon)
    |> Ash.Query.load(:appointment_type)
    |> Ash.read!(authorize?: false)
    |> Enum.flat_map(fn appointment ->
      case appointment.appointment_type do
        %{base_price: price} = type ->
          [
            %{
              id: appointment.id,
              appointment_type_id: type.id,
              clinician_id: appointment.clinician_id,
              scheduled_at: appointment.scheduled_at,
              amount: price
            }
          ]

        nil ->
          []
      end
    end)
  end

  @doc """
  The one charge a visit recognizes, if it recognizes one. The recognition
  hook's idempotency check: a visit's history may walk `:complete` twice
  (the seeds' back-dated walk re-asserts the stage at the present), and the
  clinic charges for the visit, not for each retelling of it.
  """
  def charge_for(appointment_id) do
    Charge
    |> Ash.Query.filter(appointment_id == ^appointment_id)
    |> Ash.read_one!(authorize?: false)
  end
end
