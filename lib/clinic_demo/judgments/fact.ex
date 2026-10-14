defmodule ClinicDemo.Judgments.Fact do
  @moduledoc """
  The clinic's materialised-facts host — the first `ash_judgments` facts
  table in this app (P4-S4), and **born temporal**: this repo never hosted
  the legacy `AshJudgments.Facts.Fragment` shape, so there is nothing to
  migrate and no archive step (the VPM-51 first-host cut-over posture).

  `AshJudgments.Facts.TemporalFragment` supplies the whole contract: the
  set-evaluator fields (`subject`/`predicate`/`value`, `holds`), the two
  time axes (`valid_at` periods for record validity — one open period per
  `(subject, predicate, scope)` by a PG18 `WITHOUT OVERLAPS` identity —
  and `valid_until` as the domain-validity attribute, so an expired fact
  still reads as a row), the `:materialise`/`:revise`/`:truncate` writes,
  and the as-of containment reads. Supersession is a period split, not
  bookkeeping: history is preserved in closed periods and a plain read is
  the as-of-now read.

  `AshJudgments.Facts.Materialiser` is the sole writer — admission policy
  (human-wins, omission-supersedes, review-writes-nothing) is its job; the
  period mechanics are temporal's. Writes ride the central event log, so
  replaying the audit trail rebuilds the periods identically — the
  equivalence property the package pins, now with a clinic-hosted table
  under it.
  """

  use Ash.Resource,
    domain: ClinicDemo.Judgments,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshEvents.Events],
    fragments: [AshJudgments.Facts.TemporalFragment]

  postgres do
    table "judgment_facts"
    repo ClinicDemo.Repo
  end

  events do
    event_log(ClinicDemo.Events.Event)
    create_timestamp :recorded_at
  end
end
