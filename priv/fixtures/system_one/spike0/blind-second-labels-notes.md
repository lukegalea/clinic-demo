# S1-21 second (blind) labels — FINAL before unblinding

- Set: `live-2026-10-02` (53 items), ticket S1-21, protocol: S1-25 eval-sets programme design v1 §2.
- Second labeller: Oracle agent (opencode, glm-5.3), 2026-10-02.
- Inputs read: sanitised projection `{id, question, state}` of `priv/fixtures/system_one/spike0/items.jsonl`
  (label fields `gold`, `labeller`, `second_label`, `author_notes`, `stratum`, `approx_tokens` stripped
  before reading; verified 0 occurrences). Question definitions read from
  `lib/clinic_demo/system_one_spike.ex`. No other artefact read. Labels below produced strictly from
  inputs + rubric.
- Label layers: `answer` = the question's own answer space (what `gold` must be scored in);
  `disposition` = design §1 five-value layer (`supports|contradicts|insufficient|not_applicable|wrong_scope`).

## notes_follow_up (27 items)

Predicate: "Do notes record a concrete follow-up plan for this patient: a recheck, a medication
course with an end, or a referral?" — true: "A specific follow-up for this patient is planned";
false: "No follow-up, follow-up explicitly declined, or only general advice."

| id | answer | disposition | confidence | note |
|---|---|---|---|---|
| n-pos-01 | true | supports | high | recheck booked 14d + drops course with end |
| n-pos-02 | true | supports | high | bloods repeated 8w, booked at desk |
| n-pos-03 | true | supports | high | referral letter sent (referral listed in predicate) |
| n-pos-04 | true | supports | high | suture removal booked + meloxicam 5d course with end |
| n-pos-05 | true | supports | high | 14d antibiotic course with end date + nurse phone check |
| n-pos-06 | true | supports | high | T4 recheck 3w, booked online |
| n-neg-01 | false | contradicts | high | complete routine record, no plan anywhere |
| n-neg-02 | false | contradicts | high | nail trim only |
| n-neg-03 | false | contradicts | high | "General advice only" (false criterion verbatim) |
| n-neg-04 | false | contradicts | high | microchip only |
| n-neg-05 | false | contradicts | high | healthy puppy, advice only |
| n-neg-06 | false | contradicts | high | resolved, discharged |
| n-hard-01 | false | contradicts | high | explicit "no recheck needed; nothing further" |
| n-hard-02 | false | contradicts | high | recheck belongs to Pepper (other animal); Nutmeg "needs nothing further" |
| n-hard-03 | false | contradicts | high | recheck cancelled today, declined rebook |
| n-hard-04 | false | contradicts | medium | conditional return-if-worse = advice, nothing scheduled |
| n-hard-05 | false | contradicts | high | template line unedited; "nothing is planned" in text |
| n-hard-06 | false | contradicts | high | referral explicitly declined |
| n-hard-07 | false | contradicts | medium | vague monitoring ("keep an eye"), annual mention ≠ planned recheck |
| n-len-0300-pos | true | supports | high | deciding sentence last: "recheck booked in two weeks" |
| n-len-0900-pos | true | supports | high | same |
| n-len-1100-pos | true | supports | high | same |
| n-len-1600-pos | true | supports | high | same |
| n-len-0300-neg | false | contradicts | high | "no recheck needed; discharged" |
| n-len-0900-neg | false | contradicts | high | same |
| n-len-1100-neg | false | contradicts | high | same |
| n-len-1600-neg | false | contradicts | high | same |

No `insufficient` in this family from my reading: every note is a complete-enough consult record to
decide the predicate (the false criterion explicitly folds "no follow-up / general advice" into
false, so the answer space cannot express the insufficient/contradicts split — noted as a
materials-forced vocabulary limitation).

## presenting_urgency (26 items)

Options per resource: emergency | urgent | soon | routine | insufficient_information.

| id | answer | disposition | confidence | note |
|---|---|---|---|---|
| c-emer-01 | emergency | supports:emergency | high | collapse + pale gums |
| c-emer-02 | emergency | supports:emergency | high | active 5-min seizure |
| c-emer-03 | emergency | supports:emergency | high | dark chocolate = toxin ingestion |
| c-emer-04 | emergency | supports:emergency | high | blocked tom cat = cannot urinate |
| c-urg-01 | urgent | supports:urgent | high | repeated vomiting, can't keep water |
| c-urg-02 | urgent | supports:urgent | high | non-weight-bearing = significant pain |
| c-urg-03 | urgent | supports:urgent | high | not eating 2 days, hiding (senior) |
| c-urg-04 | urgent | supports:urgent | high | eye injury (squinting, cloudy) |
| c-soon-01 | soon | supports:soon | high | mild otitis signs this week |
| c-soon-02 | soon | supports:soon | high | small non-bothersome lump, chronic |
| c-soon-03 | soon | supports:soon | high | intermittent mild limp, weeks, still running |
| c-soon-04 | soon | supports:soon | high | dandruff/scratching, otherwise fine |
| c-rout-01 | routine | supports:routine | high | booster |
| c-rout-02 | routine | supports:routine | high | nail trim (routine description verbatim) |
| c-rout-03 | routine | supports:routine | high | pre-holiday health check |
| c-rout-04 | routine | supports:routine | high | second puppy vaccination |
| c-hard-01 | soon | supports:soon | medium | bleeding STOPPED; mild resolved injury ≠ emergency; reactive not elective → soon. candidate disagreement |
| c-hard-02 | soon | supports:soon | medium | owner panic irrelevant; two sneezes, otherwise normal = mild sign → soon. candidate disagreement |
| c-hard-03 | emergency | supports:emergency | high | open-mouth breathing + blue tongue = dyspnoea/cyanosis |
| c-hard-04 | emergency | supports:emergency | medium | neonate, cold, not feeding = immediately life-threatening; urgency carried by age_band. candidate disagreement |
| c-hard-05 | soon | supports:soon | medium-high | routine request hides 1-month PU/PD in senior = chronic sign → soon |
| c-hard-06 | emergency | supports:emergency | medium | rabbit anorexia + no droppings ~1d = GI stasis; species-conditioned severity per question scope. candidate disagreement |
| c-abst-01 | insufficient_information | insufficient | high | "Something's not right." |
| c-abst-02 | insufficient_information | insufficient | high | "Please call me back." |
| c-abst-03 | insufficient_information | insufficient | high | "Follow-up from last time." — no urgency content |
| c-abst-04 | insufficient_information | insufficient | high | "As discussed." |

## Contamination ledger (pre-unblinding, honest record)

1. Item ids encode design stratum (`n-pos-*`, `c-emer-*`, `c-abst-*`, …). Unavoidable (join key).
   Mitigated by judging from text only; id-text conflicts, if any, will be reported.
2. The pointer doc (spike-0.md) reveals the stratum table (aggregate: 6/6/7/8 noul, 16/6/4 choice,
   "abstain (gold insufficient_information)" named for the last 4) and aggregate model metrics.
   Aggregate only; no per-item first label seen.
3. `gold`/`author_notes`/`stratum`/`labeller`/`second_label` stripped before reading inputs;
   sanitizer verified (0 matches).
4. `build_items.exs`, `results/**`, `replay/**` NOT opened at label time.

— Labels FINAL at write time. Unblinding permitted after this file exists.
