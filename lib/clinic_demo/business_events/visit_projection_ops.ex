defmodule ClinicDemo.BusinessEvents.VisitProjectionOps do
  @moduledoc """
  The scenario fold's handlers (BPSim BD-5): the ops vocabulary the sim
  projector applies over the sim value projection's field set.

  The original plan was one shared handler module for both projectors;
  BD-3's `ValueProjector` landed its own inline handlers instead, and the
  two folds deliberately stay separate — adoption would have meant
  rewriting the merged, equivalence-gate-bearing real fold for no
  sim-side gain. The divergence, stated so nobody has to guess:

    * **Corrections** — this fold increments `:corrections` on
      supersession (the engine's convention); the real fold leaves the
      counter idle. Sim events never supersede, so the clause is
      dormant here either way.
    * **`recognized_at`** — this fold sets it only beside a recognized
      amount (a no-type completion recognizes nothing, no instant);
      the real fold sets it on every completion.
    * **Coercion** — this fold parses the canonical shapes itself and
      fails loudly on a kind it cannot digest; the real fold leans on
      Ash's casts and answers only its own kinds.

  What both folds share is the source contract: the §1.4 ledger row —
  `action` (the canonical kind), `record_id` (the appointment id),
  `data` (the mapping's canonical output — decimals ride their JSON
  string form), `occurred_at` (truth time), `supersedes_event_id`. Ops
  are order-deterministic per subject, so a replay re-derives identical
  periods either way (the BIZEV-8 property, host-side).
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
