defmodule ClinicDemo.BusinessEvents.ValueProjector do
  @moduledoc """
  The clinic's projector: folds the ledger's value events into the
  temporal `ValueProjection` — one grain per (region, subject), one
  period per truth interval, written `as_of` each event's `occurred_at`.

  The handlers are order-deterministic folds over the §1.4 row (the
  property the replay-equivalence gate stands on): each kind sets exactly
  the truth it carries, and a kind it cannot digest fails loudly (the
  drain quarantines it in the DeadLetter) rather than folding garbage.

    * `visit_booked` — opens the visit: expected value, slot, the two
      forecast dimensions. Outcome `:open`.
    * `visit_triaged` — the decision's weight, banded by the mapping.
    * `visit_completed` — outcome `:completed`, the recognition and its
      instant. The amount is absent-path: a no-type completion sets no
      `recognized_amount` (no charge exists either — the equivalence
      gate's like-for-like depends on this symmetry).
    * `visit_cancelled` / `visit_no_show` — the story's losses.
    * `charge_written_off` — the value revision: money the charge will
      not collect, beside an untouched `:completed` outcome.

  The drain is the package's (`drain/1` here): the per-region commit-order
  feed, the engine's checkpoint keyed `clinic_value_v1.<region>`, batched
  at 200. Called once at seed end and by the tests; idempotent — the
  checkpoint is the cursor.
  """

  use AshDiscreteBusinessEvents.Projections,
    name: "clinic_value_v1",
    event_log: ClinicDemo.BusinessEvents.Ledger,
    projection_resource: ClinicDemo.BusinessEvents.ValueProjection

  grain(fn event -> %{region: event.region, subject: event.record_id} end)

  project("visit_booked", fn event ->
    [
      {:set, :outcome, :open},
      {:set, :expected_amount, event.data["expected_amount"]},
      {:set, :scheduled_at, event.data["scheduled_at"]},
      {:set, :clinician_id, event.data["clinician_id"]},
      {:set, :type_id, event.data["type_id"]}
    ]
  end)

  project("visit_triaged", fn event ->
    [
      {:set, :urgency, event.data["urgency"]},
      {:set, :urgency_band, event.data["urgency_band"]}
    ]
  end)

  project("visit_completed", fn event ->
    base = [
      {:set, :outcome, :completed},
      {:set, :recognized_at, event.occurred_at}
    ]

    # Absent-path: a completion with no recognized amount (no catalogue
    # type) sets nothing — no silent nil, and the month-revenue reads
    # filter on the amount's presence anyway.
    case event.data["amount"] do
      nil -> base
      amount -> [{:set, :recognized_amount, amount} | base]
    end
  end)

  project("visit_cancelled", fn event ->
    outcome_ops(event)
  end)

  project("visit_no_show", fn event ->
    outcome_ops(event)
  end)

  project("charge_written_off", fn event ->
    [{:set, :written_off_amount, event.data["amount"]}]
  end)

  # A terminal event carries its own outcome — the fold reads it off the
  # event, and answers only its own kinds: any other row folds nothing.
  defp outcome_ops(event) do
    if event.action in [:visit_cancelled, :visit_no_show] do
      [{:set, :outcome, terminal(event)}]
    else
      []
    end
  end

  defp terminal(%{action: :visit_cancelled}), do: :cancelled
  defp terminal(%{action: :visit_no_show}), do: :no_show
end
