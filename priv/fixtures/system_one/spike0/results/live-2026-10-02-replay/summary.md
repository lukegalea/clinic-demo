> Provenance: **recorded**: answers came from the HTTP endpoint named in `environment.txt` beside this file. Check it is the pinned Ollaya before quoting.

Transport `replay:live-2026-10-02`, 3 repeats. Metrics use the first repeat (`r1`); variance uses all repeats.

### Noul: `notes_follow_up`

| spec | N (answered/errors) | AUROC | mean p gold+ / gold− | median p gold+ / gold− | in 0.2–0.8 | ECE (10 bins) | Brier | acc @0.5 | sel @0.9 (cov / acc) | sel @0.8 (cov / acc) | lowest t with acc≥0.95, cov≥0.4 |
|---|---|---|---|---|---|---|---|---|---|---|---|
| laya | 27 (23/4) | 0.983 | 0.703 / 0.434 | 0.697 / 0.402 | 22 | 0.269 | 0.170 | 0.739 | 0.000 / – | 0.043 / 1.000 | 0.650 (cov 0.478) |

### Choice: `presenting_urgency`

| spec | N (answered/errors) | accuracy | ECE top-p | Brier top-p | sel @0.9 (cov / acc) | sel @0.8 (cov / acc) | band: suggested (acc) | abstained / gold abstain |
|---|---|---|---|---|---|---|---|---|
| laya | 26 (26/0) | 0.462 | 0.276 | 0.298 | 0.000 / – | 0.000 / – | 0 (–) | 0 of 4 (0 abstentions in all) |

### Latency, batching and variance

| spec | warm p50 / p95 ms (n) | cold first request ms | both vs separate ms (pairs) | both: mean |Δp|, same choice | repeat stddev p (mean / max) |
|---|---|---|---|---|---|
| laya | 215.100 / 481.600 (147) | 212.700 | 521.300 vs 366.500 (19) | 0.039, 11/19 | 0.000 / 0.000 |

### Context limit (length probes, `r1`)

| item | ≈tokens | gold | laya |
|---|---|---|---|
| n-len-0300-neg | 295 | false | p=0.402 |
| n-len-0300-pos | 300 | true | p=0.783 |
| n-len-0900-neg | 891 | false | p=0.553 |
| n-len-0900-pos | 896 | true | p=0.753 |
| n-len-1100-neg | 1093 | false | error 422 (Ash.Error.Unknown) |
| n-len-1100-pos | 1098 | true | error 422 (Ash.Error.Unknown) |
| n-len-1600-neg | 1581 | false | error 422 (Ash.Error.Unknown) |
| n-len-1600-pos | 1586 | true | error 422 (Ash.Error.Unknown) |

### Wire

| spec | Result.model values | usage present | errors by kind |
|---|---|---|---|
| laya | `laya:typed-decisions` | 167/167 | Ash.Error.Unknown 422: 12 |

**Verdict (AC-4):** no-go or go-with-conditions (see doc)
