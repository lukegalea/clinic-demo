# System One eval-set fixtures — store conventions

Labelled evaluation sets for the judgment families (S1-25 programme, design v1:
`ash_enterprise/docs/research/system-one/eval-sets-programme-design.md` — the
public half; schema §1, protocol §2). This directory holds the repo's sets as
JSONL: one file per set, `items.jsonl`, beside the generator that built it and
the labelling records that filled it.

Current set: `spike0/` — 53 items, two families, blind second-labelled
2026-10-02 (53/53 agreement; the record and its caveats live in
`docs/spikes/system-one-spike-0.md` and `spike0/blind-second-labels-notes.md`).

## Row fields

`id`, `question` (the family), `state` (the item input), `gold` (first
rater's label), `labeller`, `second_label` (blind second rater's label),
`second_labeller`, `stratum`, `approx_tokens`, `author_notes`.

## Second-labeller identity is first-class

Every row may carry `second_labeller` naming who produced `second_label`. New
sets write the field explicitly; the loader
(`ClinicDemo.EvalSets.Store.second_labeller/1`) falls back to `ora-4` — the
recorded identity of this repo's only second labelling so far (the S1-21
record; accepted as second labeller of record per the owner's 2026-10-02
proceed-as-recommended sweep). The fallback exists so the committed spike-0
rows — which predate the field — resolve without rewriting fixture data.
Do not rely on the fallback for new sets; set the field.

## Label layers

* **Answer layer** — each question's own answer space (`gold`/`second_label`
  verbatim: `true`/`false`, or the choice options incl.
  `insufficient_information`).
* **Disposition layer** — design §1's five-value evidence-disposition
  vocabulary. Derived mechanically, never guessed: binary `true`/`false` →
  `supports`/`contradicts`; a choice option → `supports`;
  `insufficient_information` → `insufficient`. A new family that does not fit
  extends `Store.disposition/1` explicitly, with the labelling record cited.

## Tooling

    mix clinic_demo.eval_sets.agreement <set-name>   # default: spike0

prints the full §2 agreement block (raw agreement, per-family κ with p_e,
prevalence, per-class specific agreement, PABAK/AC1 under the <10%-rule) and
exits non-zero when the κ-gate fails. The statistics module is
`ClinicDemo.EvalSets.Agreement` (pure, golden-pinned to the spike-0 record);
the design's CRC and audit-alarm arithmetic is `ClinicDemo.EvalSets.RiskControl`.

## Regenerating

`spike0/build_items.exs` writes the PRE-labelling state; the committed
items.jsonl carries the filled second labels applied after the blind round.
Do not regenerate a labelled set's items.jsonl from its generator — treat the
generator as provenance, not as the store.

Everything under this tree is synthetic and CC0-1.0 (see `REUSE.toml`).
