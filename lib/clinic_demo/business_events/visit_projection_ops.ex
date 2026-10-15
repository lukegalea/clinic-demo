defmodule ClinicDemo.BusinessEvents.VisitProjectionOps do
  @moduledoc """
  The value fold's handlers — the one module both projectors share
  (design §2d): the real projector (BD-3's `ValueProjector`) and the
  scenario projector (`SimValueProjector`) route the same six canonical
  kinds into the same ops vocabulary over the same field set. One fold,
  two targets — which is the whole isolation story: the handlers
  describe *what a visit's events mean*; the projector's declaration
  alone decides *which table the truth lands in*.

  The handler sees the full §1.4 ledger row: `action` (the canonical
  kind), `record_id` (the appointment id), `data` (the mapping's
  canonical output — decimals ride their JSON string form), `occurred_at`
  (truth time), `supersedes_event_id`. Ops are order-deterministic per
  subject — `:set` from the event verbatim, the corrections counter
  incremented only on supersession — so a replay re-derives identical
  periods (the BIZEV-8 property, restated host-side).

  Deliberately absent: `type_id`/`clinician_id`. The canonical booked
  payload carries money and the slot, not dimension ids (the §2b
  mapping's PII-adjacent minimalism); a fold that needs dimensions
  extends the mappings and then this module — the projection never
  reaches back into the raw layer, for real truth or for sims.
  """

  import Decimal, only: [new: 1]

  @doc """
  The ops one canonical visit event folds into the value projection:
  the outcome state, the amounts and instants its kind carries, plus
  the engine's corrections convention.
  """
  @spec ops_for(map()) :: [
          {:set, atom(), term()} | {:increment, atom(), non_neg_integer()}
        ]
  def ops_for(event),
    do: kind_ops(event.action, event) ++ correction_ops(event)

  # ── one clause per canonical kind ──────────────────────────────────────

  defp kind_ops(:visit_booked, event) do
    data = event.data

    [
      {:set, :outcome, :open},
      maybe_set(:expected_amount, amount(data["expected_amount"])),
      maybe_set(:scheduled_at, datetime(data["scheduled_at"]))
    ]
  end

  defp kind_ops(:visit_triaged, event) do
    [
      maybe_set(:urgency, event.data["urgency"]),
      maybe_set(:urgency_band, event.data["urgency_band"])
    ]
  end

  defp kind_ops(:visit_completed, event) do
    # The completion's recognized instant is the event's truth time —
    # the same rule `RecognizeCharge` uses for the charge. A no-type
    # completion carries no amount key and recognizes nothing: no
    # amount, no instant, no silent nil.
    amount = amount(event.data["amount"])

    case amount do
      nil ->
        [{:set, :outcome, :completed}]

      amount ->
        [
          {:set, :outcome, :completed},
          {:set, :recognized_amount, amount},
          {:set, :recognized_at, event.occurred_at}
        ]
    end
  end

  defp kind_ops(:visit_cancelled, _event), do: [{:set, :outcome, :cancelled}]
  defp kind_ops(:visit_no_show, _event), do: [{:set, :outcome, :no_show}]

  defp kind_ops(:charge_written_off, event) do
    # One write-off per visit, ever (the delivery key's ruling) — so the
    # revision is a :set, never an accumulation.
    [{:set, :written_off_amount, amount(event.data["amount"])}]
  end

  defp kind_ops(kind, _event) do
    # A kind this fold routes but cannot digest FAILS LOUDLY (the drain
    # quarantines it in the DeadLetter) instead of folding garbage into
    # the projection — the package's PipelineProjector precedent.
    raise ArgumentError,
          "undigestible #{inspect(kind)}: the value fold has no ops for this kind"
  end

  # ── the engine convention ──────────────────────────────────────────────

  defp correction_ops(%{supersedes_event_id: nil}), do: []

  defp correction_ops(%{supersedes_event_id: id}) when not is_nil(id),
    do: [{:increment, :corrections, 1}]

  # ── the canonical shapes → typed values ────────────────────────────────

  defp maybe_set(_field, nil), do: []
  defp maybe_set(field, value), do: [{:set, field, value}]

  defp amount(nil), do: nil

  defp amount(raw) do
    # The :map attribute round-trips decimals through their JSON string
    # form ("175"); the mapping may also emit plain numbers.
    new(raw)
  end

  defp datetime(nil), do: nil

  defp datetime(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        dt

      other ->
        raise ArgumentError, "undigestible scheduled_at: #{inspect(iso)} (#{inspect(other)})"
    end
  end
end
