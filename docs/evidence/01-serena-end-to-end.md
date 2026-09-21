# 01 — Serena end to end, over stdio

Every answer in this file was produced by driving `bin/serena-mcp` the way an
MCP client does: initialize, `notifications/initialized`, then `tools/call`,
one JSON-RPC message per line on stdio. The driver is
[`bin/serena-mcp-smoke.exs`](bin/serena-mcp-smoke.exs) — same shape as
`bin/expert-smoke.exs`, which is not a coincidence, because Serena's Elixir
backend *is* Expert and the conversation underneath is the same one. Full
transcripts: [`transcripts/serena-probe.txt`](transcripts/serena-probe.txt),
[`transcripts/serena-read.txt`](transcripts/serena-read.txt),
[`transcripts/serena-rename.txt`](transcripts/serena-rename.txt).

Serena itself: `uvx --from git+https://github.com/oraios/serena` resolved
`Serena 2.0.0.dev0` from upstream `main`, 2026-09-21, context `claude-code`
(the `bin/serena-mcp` default).

## Handshake and tool surface

```
$ elixir docs/evidence/bin/serena-mcp-smoke.exs probe
[9ms] -> initialize (Serena runs its activation_command, then boots Expert; first contact indexes the project)
[1.9s] <- initialize ok after 1921ms
[1.9s]    serverInfo: {"name":"Serena","version":"2.0.0.dev0","websiteUrl":"https://oraios.github.io/serena"}
[1.9s]    protocolVersion: "2024-11-05"
[1.9s] -> notifications/initialized
[1.9s] <- tools/list (3ms)
[1.9s]    21 tools: replace_content, replace_in_files, replace_symbol_body, insert_after_symbol,
          insert_before_symbol, get_symbols_overview, find_symbol, find_referencing_symbols,
          find_implementations, find_declaration, get_diagnostics_for_file, rename_symbol,
          safe_delete_symbol, write_memory, read_memory, list_memories, delete_memory,
          rename_memory, edit_memory, onboarding, initial_instructions
```

Two things the server log (interleaved on stderr in the transcript) shows
about the wiring while this happens:

```
INFO serena.agent:_run_project_activation_command - Running activation_command for project 'clinic_demo': mix compile
INFO serena.agent:_create_base_toolset - SerenaAgentContext[name='claude-code'] excluded 6 tools:
      create_text_file, read_file, execute_shell_command, find_file, list_dir, search_for_pattern
```

The activation command from `.serena/project.yml` runs, and it only runs
because the project is in `trusted_project_path_patterns` in
`~/.serena/serena_config.yml` — which did not exist on this machine until this
session created it (see [06 — environment](06-environment.md)). Note that
`initialize` answers in ~1.9s; the expensive part is not the handshake, it is
the first symbol question, which boots Expert.

## Symbols overview — lib/clinic_demo/decisions/resolver.ex

```
[1.8s] -> tools/call get_symbols_overview {"relative_path":"lib/clinic_demo/decisions/resolver.ex"}
[14.3s] <- get_symbols_overview lib/clinic_demo/decisions/resolver.ex (12492ms)
[14.3s] {"Module": ["ClinicDemo.Decisions.Resolver"]}
```

12.5 seconds, almost all of it Expert starting and indexing on first contact.
That is the wait `docs/agents.md` documents as "a minute or more on first
contact" — on this machine, with `.expert/` already warm, it is seconds.

## find_symbol `decide`, with body

```
[14.3s] -> tools/call find_symbol {"include_body":true,"name_path_pattern":"decide","relative_path":"lib/clinic_demo/decisions/resolver.ex"}
[14.3s] <- find_symbol decide (include_body) (5ms)
[{"name_path": "ClinicDemo.Decisions.Resolver/decide", "kind": "Function",
  "relative_path": "lib/clinic_demo/decisions/resolver.ex",
  "body_location": {"start_line": 32, "end_line": 47},
  "body": "def decide(ref, inputs, context) do
    with {:ok, definition} <- latest_published(ref) do
      inputs = Map.new(inputs, fn {k, v} -> {k, AshDecisions.Feel.to_feel_value(v)} end)

      case AshDecisions.Evaluator.evaluate(definition, inputs,
             evaluation_resource: Evaluation,
             correlation_id: correlation_id(context)
           ) do
        {:ok, result} ->
          {:ok, %{outputs: outputs(result.outputs), version: result.definition_version}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end"}]
```

Body, file, and line span in one round trip, 5ms once the engine is up.

## find_referencing_symbols `decide/3` — immediate, then after the wait

Serena's Elixir backend hard-codes a cross-file wait
(`_get_wait_time_for_cross_file_referencing`, ~10s) before reference answers
are trustworthy. The immediate call and the deliberate-wait call, back to
back:

```
[14.3s] -> tools/call find_referencing_symbols {"name_path":"decide","relative_path":"lib/clinic_demo/decisions/resolver.ex"}
[24.5s] <- find_referencing_symbols decide (IMMEDIATE) (10137ms)
{"test/clinic_demo/decisions/triage_test.exs": {"Function": [
   {"name_path": "ClinicDemo.Decisions.TriageTest/urgency",
    "body_location": {"start_line": 14, "end_line": 23},
    "content_around_reference": "...  15:    {:ok, %{outputs: outputs}} =
  >  16:      Resolver.decide(
...  17:        \"appointment.triage\","}],
 "Method": [
   {"name_path": "ClinicDemo.Decisions.TriageTest/describe \"an unknown decision\"/test \"is an error rather than a guess\"",
    "body_location": {"start_line": 119, "end_line": 123},
    "content_around_reference": "... 119:    test \"is an error rather than a guess\" do
  > 120:      assert {:error, _} = Resolver.decide(\"appointment.nonsense\", %{}, %{})
... 121:      refute Resolver.exists?(\"appointment.nonsense\")"}]}}

[24.5s] -- sleeping 12000ms before asking again
[36.5s] -> tools/call find_referencing_symbols {"name_path":"decide","relative_path":"lib/clinic_demo/decisions/resolver.ex"}
[36.5s] <- find_referencing_symbols decide (after 12s wait) (38ms)
```

The honest reading, which is slightly better than the one `docs/agents.md`
prepares you for: the immediate call is not *early* on this build — it blocks
for the wait itself (10,137ms, which is Serena's own ten-second number plus
the work) and then answers correctly. The deliberate wait does not change the
answer; it changes who pays for it. Both references are the true ones —
`grep` agrees `decide/3` has exactly two call sites, both in
`test/clinic_demo/decisions/triage_test.exs` (the process engine reaches
`decide/3` through the `AshBpmn.DecisionResolver` behaviour, which is a call
the language server cannot attribute and does not claim to). What a client
must not do is conclude from a 10-second silence that the tool has hung.

## rename_symbol `decide` → `evaluate` — BLOCKED, and the blocker is precise

```
[16.0s] -> tools/call rename_symbol {"name_path":"decide","new_name":"evaluate","relative_path":"lib/clinic_demo/decisions/resolver.ex"}
[16.1s] <- tools/call rename_symbol ERROR after 44ms
Error executing tool rename_symbol: SolidLSPException: Error processing request
textDocument/rename with params:
{'textDocument': {'uri': 'file:///home/lukegalea/capstone-demo/lib/clinic_demo/decisions/resolver.ex'},
 'position': {'line': 32, 'character': 6}, 'newName': 'evaluate'}
(caused by Method not found (-32601))
```

Serena sent the LSP `textDocument/rename` request; Expert answered *Method not
found*. This is not a wiring failure and not a Serena failure — this Expert
build does not implement rename at all. Its `initialize` capabilities (dumped
from the same binary):

```
codeActionProvider codeLensProvider completionProvider definitionProvider
documentFormattingProvider documentSymbolProvider executeCommandProvider
experimental foldingRangeProvider hoverProvider referencesProvider
textDocumentSync workspace workspaceSymbolProvider
```

No `renameProvider`. So the rename → diff → `git checkout -- .` sequence this
document was meant to capture cannot be captured, and nothing was edited —
`git status` stayed clean, no revert was needed. The finding is recorded in
`.agents/logs/tool-gaps.log` (2026-09-21) as an Expert-side gap: until Expert
grows a `renameProvider`, Serena's `rename_symbol` — the flagship move of the
"generic symbol half" — cannot work against any Expert build, and the editing
tools that do work (`replace_symbol_body`, `replace_content`) are text edits,
which is `sed` with extra steps.

What `docs/agents.md`'s walkthrough says about what rename *would* do here
(edit `lib/` and `test/`, not the README's `"appointment.triage"` string)
remains true and remains unverified — there was no WorkspaceEdit to apply.

## Remaining manual step

None for capture. For the rename item: none possible until Expert implements
`textDocument/rename`; re-run `elixir docs/evidence/bin/serena-mcp-smoke.exs
rename` when it does.
