# Evidence

Verification artifacts for the agent wiring this repository ships — captured
2026-09-21, on this machine, against the tree as checked out. Every claim in
`docs/agents.md` and the README's two-servers section that could be exercised
headlessly was exercised; what could not be is written down with the precise
reason it could not be.

The transcripts under `transcripts/` are verbatim (stderr included, noise and
all); the numbered files quote them with the reading. The capture scripts
under `bin/` are the reproducibility: run them and the transcripts happen
again.

| Artifact | What it proves | Manual remainder |
|---|---|---|
| [01 — Serena end to end](01-serena-end-to-end.md) | An MCP conversation with `bin/serena-mcp` over stdio: initialize, `tools/list` (21 tools), symbols overview on `resolver.ex`, `find_symbol decide` with body and line span, `find_referencing_symbols` before and after the cross-file wait (10,137ms in-call, then 38ms), and `rename_symbol` **blocked** — Expert declares no `renameProvider` and answers `textDocument/rename` with -32601 | Re-run the rename stage when Expert grows a `renameProvider`; the diff + revert it was meant to capture was never produced (nothing was edited) |
| [02 — The boundary](02-boundary-negative.md) | `find_symbol` for `complete` returns `[]` across the whole project, while `bin/ash-agent describe … complete` returns the action's full contract — an Ash action is data in a DSL, not a symbol | None |
| [03 — `ash_agent` answers](03-ash-agent-answers.md) | `describe` (contract with types, descriptions, file-and-line), `validate` (camelCase key → `did_you_mean`; `"3"` → `3`; nothing run), `forbidden` (the policies that can deny `:discharge`, with the can-I-actually caveat). Captured against the pre-`688fad7` pin; the dependency bump since populates `code_interfaces`, argument `constraints`, and the resource-level `aggregates`/`calculations` blocks — [07](07-daemon-slot.md) shows the same questions answered by the current tree | None |
| [04 — The Expert fix](04-expert-fix.md) | The installed fork build answers `documentSymbol` for a never-opened file **from the index** and for a nonexistent path with structured `-32600 "Document could not be loaded"`, server still up — the rc.6 crash shape is unreachable | rc.6's crash itself not re-demonstrated (deliberately not installed) |
| [05 — Waits](05-waits.md) | First vs subsequent `bin/ash-agent` calls (1.1s/1.7s warm here; the documented 10–15s is the cold case), a compile riding inside a call with **stdout still pure JSON**, and the ~10s cross-file wait absorbed by the first `find_referencing_symbols` | The cold-machine numbers, by definition not capturable on a warm machine |
| [06 — Environment](06-environment.md) | `uvx`/`expert` present, `mix`/`xmllint` absent with their documented provisions (`ELIXIR_BIN_DIR`, libxml2 on PATH); Serena CLI flags in `bin/serena-mcp` all still exist on `main` (`--project-file` deprecated, unused); the `trusted_project_path_patterns` step that silently gates the activation command | None; re-check flag drift when Serena is bumped |
| [07 — The daemon slot](07-daemon-slot.md) | `mix ash_agent.serve --port 4100` booted from this repository (pinned at `688fad7`, which ships the daemon): `initialize` with protocol down-negotiation, `tools/list` (7 `ash_*` tools), `ash_describe`/`ash_validate` round trips matching the Mix tasks' JSON — and the clock: boot paid once (~1.2s) against a fresh boot per `bin/ash-agent` call (~2s warm), per-call round trips in single-digit milliseconds. Wiring flipped live in `.mcp.json`/`opencode.json`; daemon killed after capture, port verified dead | The cold-machine numbers, by definition; hot reload (no `inotify-tools` here — the daemon degrades to `ash_reload` and says so) |

## The one blocked item, stated plainly

`rename_symbol` — the move `docs/agents.md`'s walkthrough opens with — cannot
be demonstrated against any Expert build today. Serena sent the LSP rename;
Expert answered `Method not found (-32601)`, and its initialize capabilities
confirm there is no `renameProvider` to call. The failure is in the language
server, not in Serena, not in `bin/serena-mcp`, and not in this repository's
configuration. It is logged in `.agents/logs/tool-gaps.log` with the date, and
[01](01-serena-end-to-end.md) carries the full transcript and capability dump.

## Reproducing

```sh
export ELIXIR_BIN_DIR=/nix/store/iqc2jyh602php9bhy28qi01gk6w0sgb3-elixir-1.19.5/bin
export PATH="$(ls -d /nix/store/*libxml2*-bin/bin | head -1):$PATH"   # for mix test

mix compile
elixir bin/expert-smoke.exs ~/.local/bin/expert
elixir docs/evidence/bin/expert-unopened.exs ~/.local/bin/expert
elixir docs/evidence/bin/serena-mcp-smoke.exs probe
elixir docs/evidence/bin/serena-mcp-smoke.exs read
bin/ash-agent describe ClinicDemo.Scheduling.Appointment complete --pretty
```

`serena-mcp-smoke.exs rename` is safe to run: on today's Expert it fails
without editing anything, and if Expert ever implements rename, capture
`git diff` afterwards and `git checkout -- .` to revert.
