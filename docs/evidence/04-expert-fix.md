# 04 — The Expert fix, and the never-opened document

`bin/serena-mcp` puts a build of the `fix/document-symbol-crashes` fork
(commit `537338b`) on PATH ahead of the v0.1.0-rc.6 release Serena would
otherwise download. rc.6's defect: `Expert.EngineApi.document_symbols/2`
pattern-matched its document argument as `%Document{}` and raised a
`FunctionClauseError` for any document it could not resolve — which is every
file Serena indexes without opening first. These two transcripts show what the
installed build does instead. Full transcripts:
[`transcripts/expert-smoke.txt`](transcripts/expert-smoke.txt),
[`transcripts/expert-unopened.txt`](transcripts/expert-unopened.txt).

## The conversation Serena has — by hand

```
$ elixir bin/expert-smoke.exs ~/.local/bin/expert
binary   .../.local/bin/expert
root     .../capstone-demo
file     lib/clinic_demo/scheduling/appointment.ex
initialize sent, waiting (Expert compiles the project on first contact)
initialize ok
documentSymbol is still empty; waiting 10s (11 left)
documentSymbol is still empty; waiting 10s (10 left)
bash: cannot set terminal process group (-1): Inappropriate ioctl for device
bash: no job control in this shell
bash: cannot set terminal process group (-1): Inappropriate ioctl for device
bash: no job control in this shell
bash: cannot set terminal process group (-1): Inappropriate ioctl for device
bash: no job control in this shell
Mix requires the Hex package manager to fetch dependencies
documentSymbol returned 1 top-level symbol(s):
  ClinicDemo.Scheduling.Appointment (0 children)
OK

real	0m23.250s
```

23 seconds, of which twenty are the two 10-second polls: `documentSymbol`
answers `null`, not an error, while indexing runs, and the script keeps asking
rather than concluding the file has no symbols — the same patience Serena
builds in. (The `bash:` and Hex lines are noise from Expert shelling out to
Mix during its startup, inherited on stderr; they are part of the record
because a silence punctuated by exactly this noise is what these waits look
like from outside.)

## The rc.6 crash shape, against the fixed build

`docs/evidence/bin/expert-unopened.exs` initializes, opens one file and waits
until symbols come back (so the engine is provably done indexing), and *then*
asks for documents it never opened:

```
$ elixir docs/evidence/bin/expert-unopened.exs ~/.local/bin/expert
initialize ok
-- didOpen lib/clinic_demo/scheduling/appointment.ex; polling documentSymbol until symbols return (indexing done)
   documentSymbol null; waiting 10s (11 left)
   documentSymbol null; waiting 10s (10 left)
indexing complete: 1 top-level symbol(s) for the opened file
-- documentSymbol unopened (exists, never didOpen'd): .../lib/clinic_demo/rules.ex
   <- result: [{"children":[... @decision_key, @decision_name, @decision_path, @process_key, ...,
                "def install!(opts \\\\ [])", "defp install_document(...)", "defp compile!(...)", ...],
                "kind":2,"name":"ClinicDemo.Rules", ...}]
-- documentSymbol nonexistent path: .../lib/clinic_demo/no/such/module.ex
   <- structured error (server still up): {"code":-32600,"data":null,"message":"Document could not be loaded"}
-- documentSymbol opened again (server health check): .../lib/clinic_demo/scheduling/appointment.ex
   <- result: [{"children":[],"kind":2,"name":"ClinicDemo.Scheduling.Appointment", ...}]
OK
```

Three cases, three honest answers, one server that never stopped:

1. **Exists, never opened** — answered in full, straight from the index: every
   module attribute and function of `ClinicDemo.Rules`, with ranges. This is
   better than the empty list the fix commit's clause provides: the engine
   resolves unopened files that live in the index, so the case Serena hits in
   practice (files it indexes without opening) does not even reach the
   fallback.
2. **Does not exist** — a structured JSON-RPC error, `-32600 "Document could
   not be loaded"`, while the server stays up. This is precisely the input
   that crashed rc.6 with a `FunctionClauseError`. One layer earlier than the
   widened clause, the request pipeline refuses an unloadable document
   outright — either way, no crash shape is reachable from a symbol question.
3. **The opened file, again** — still answers. The error was about the
   document, not about a server falling over.

## What is not proven here

That rc.6 still crashes — deliberately not installed and not tested; the xfail
in Serena's own suite plus the code path described in `docs/agents.md` stand
in for it. And that the fork's fixes are in every Expert a user might have:
they are only as good as the binary `bin/serena-mcp` finds on PATH.
