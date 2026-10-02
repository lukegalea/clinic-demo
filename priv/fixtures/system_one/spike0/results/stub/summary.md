> Provenance: **stub**. These numbers measure the harness, not a model. Do not quote them as model results.

Transport `stub_record:stub`, 3 repeats. Metrics use the first repeat (`r1`); variance uses all repeats.

### Noul: `notes_follow_up`

| spec | N (answered/errors) | AUROC | mean p gold+ / gold− | median p gold+ / gold− | in 0.2–0.8 | ECE (10 bins) | Brier | acc @0.5 | sel @0.9 (cov / acc) | sel @0.8 (cov / acc) | lowest t with acc≥0.95, cov≥0.4 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| laya | 27 (23/4) | 0.783 | 0.777 / 0.482 | 0.896 / 0.419 | 15 | 0.237 | 0.203 | 0.826 | 0.217 / 0.800 | 0.348 / 0.750 | none |
| winnow | 27 (27/0) | 0.800 | 0.799 / 0.478 | 0.893 / 0.439 | 17 | 0.227 | 0.189 | 0.852 | 0.185 / 0.800 | 0.370 / 0.800 | none |

### Choice: `presenting_urgency`

| spec | N (answered/errors) | accuracy | ECE top-p | Brier top-p | sel @0.9 (cov / acc) | sel @0.8 (cov / acc) | band: suggested (acc) | abstained / gold abstain |
|---|---|---|---|---|---|---|---|---|
| laya | 26 (26/0) | 0.731 | 0.065 | 0.197 | 0.000 / – | 0.000 / – | 0 (–) | 4 of 4 (10 abstentions in all) |
| winnow | 26 (26/0) | 0.731 | 0.065 | 0.197 | 0.000 / – | 0.000 / – | 0 (–) | 4 of 4 (10 abstentions in all) |

### Latency, batching and variance

| spec | warm p50 / p95 ms (n) | cold first request ms | both vs separate ms (pairs) | both: mean |Δp|, same choice | repeat stddev p (mean / max) |
|---|---|---|---|---|---|
| laya | 0.000 / 0.000 (147) | 0.000 | 0.000 vs 0.000 (19) | 0.013, 16/19 | 0.009 / 0.017 |
| winnow | 0.000 / 0.000 (159) | 0.000 | 0.000 vs 0.000 (19) | 0.013, 16/19 | 0.008 / 0.017 |

### Context limit (length probes, `r1`)

| item | ≈tokens | gold | laya | winnow |
|---|---|---|---|---|
| n-len-0300-neg | 295 | false | p=0.467 | p=0.467 |
| n-len-0300-pos | 300 | true | p=0.900 | p=0.900 |
| n-len-0900-neg | 891 | false | p=0.453 | p=0.453 |
| n-len-0900-pos | 896 | true | p=0.902 | p=0.902 |
| n-len-1100-neg | 1093 | false | error 422 STATE_TRUNCATED (Ash.Error.Unknown) | p=0.443 |
| n-len-1100-pos | 1098 | true | error 422 STATE_TRUNCATED (Ash.Error.Unknown) | p=0.883 |
| n-len-1600-neg | 1581 | false | error 422 STATE_TRUNCATED (Ash.Error.Unknown) | p=0.467 |
| n-len-1600-pos | 1586 | true | error 422 STATE_TRUNCATED (Ash.Error.Unknown) | p=0.893 |

### Wire

| spec | Result.model values | usage present | errors by kind |
|---|---|---|---|
| laya | `laya:typed-decisions+stub` | 167/167 | Ash.Error.Unknown 422: 12 |
| winnow | `winnow:e4b+stub` | 179/179 |  |

**Verdict (AC-4):** not evaluable: results are not from a live model (provenance stub)
