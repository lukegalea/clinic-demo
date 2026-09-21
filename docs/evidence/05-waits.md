# 05 — Waits, demonstrated with a clock

Every wait in `docs/agents.md`'s table, timed on this machine (2026-09-21),
with the honest caveat that this is a warm machine: `_build` populated, disk
cache hot. The structural claims hold at any temperature; the seconds do not.
Transcripts: [`transcripts/ash-agent-timing-first.txt`](transcripts/ash-agent-timing-first.txt),
[`transcripts/ash-agent-timing-second.txt`](transcripts/ash-agent-timing-second.txt),
[`transcripts/ash-agent-timing-stale-build.txt`](transcripts/ash-agent-timing-stale-build.txt).

## A `bin/ash-agent` call, first and subsequent

Each invocation is a fresh `mix` process, so every call pays a boot; the
"first call" cost is whatever is not yet in the OS cache.

```
$ bin/ash-agent describe --pretty        # first call in the shell
{ ...11 resources... }
real	0m1.117s

$ bin/ash-agent describe ClinicDemo.Scheduling.Appointment complete --pretty
{ ...the complete contract... }
real	0m1.680s
```

One to two seconds here, against the documented 10–15 — the documented number
is the cold-machine case, and the third transcript is what makes the
difference visible.

## The wait that is a compile riding in the call

Elixir 1.19 tracks recompilation by content checksum, so a `touch` is a no-op;
a real edit is not:

```
$ echo "# scratch edit ..." >> lib/clinic_demo/decisions/resolver.ex
$ bin/ash-agent describe --pretty
{ ...same JSON, still pure... }
real	0m1.453s
--- stderr (the compiler output, routed away from stdout by the task):
Compiling 1 file (.ex)
```

The compile happened inside the call, on this machine for the price of one
file; after a branch switch it is the whole diff, and that is where the
documented seconds go. What the demo exists to show survives at any speed:
**stdout stayed pure JSON while the compiler worked** — the contract that lets
an agent parse the answer without knowing whether a build just happened.

## The Serena side of the table

From the same session's transcripts
([01](01-serena-end-to-end.md), [04](04-expert-fix.md)):

| Wait | Documented | Observed |
|---|---|---|
| Serena `initialize` (warm `.expert/`) | a minute or more, first contact | 1.8–2.0s |
| First symbol question (Expert boot + index) | as long as `mix compile` takes | 12.5s (`get_symbols_overview`) |
| `documentSymbol` before indexing done | `null`, poll again | `null` at 10s intervals, symbols on the 3rd ask |
| Cross-file references, first call | ~10s, Serena's own number | 10,137ms — absorbed inside the call |
| Cross-file references, after a deliberate 12s wait | right | 38ms, identical answer |
| `find_symbol` for an Ash action | — | 486ms for a correct `[]` |

The last two are the pair worth teaching: the wait is real, it is inside the
first `find_referencing_symbols` call rather than in front of it, and the way
to experience it is a ten-second silence that must not be mistaken for a hang.
