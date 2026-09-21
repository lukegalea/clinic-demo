# 07 — The daemon slot: `mix ash_agent.serve`, captured live

**Status: filled.** The DX-2 daemon shipped in `ash_agent_tools` and this
repository now pins the release that carries it (`688fad7`, the `master` tip
of `github.com/lukegalea/ash_agent_tools` — same commit the dependency in
`mix.exs` resolves to). What follows was captured 2026-09-21, in this
repository, with the daemon booted from the demo's own tree and killed again
afterwards (port verified dead; nothing left listening on 4100).

## The tool it replaces, and what it costs

Every `bin/ash-agent` call is a fresh Mix process: compile-only boot, answer,
exit. [05 — waits](05-waits.md) timed it warm: ~1–2 seconds per call, of which
almost all is boot. The daemon pays that boot **once**, then answers from
in-memory compiled state:

```
$ mix ash_agent.serve --port 4100
```

```
ash_agent daemon listening on http://127.0.0.1:4100 (POST-only MCP, read-only)

  boot:   compile-only (application not started)
  watch:  hot reload on lib/ + config/ changes
  loaded: 3 domain(s), 11 resource(s)

  tools:  ash_describe, ash_validate, ash_search, ash_context, ash_forbidden, ash_daemon_status, ash_reload
```

The banner is the whole DX-2 argument in five lines: same compile-only boot
contract as the Mix tasks (`app.config` + configured domains, never
`app.start` — no Phoenix endpoint, no Oban queues), the same discovery
surface (3 domains, 11 resources, matching
[`describe --pretty`](03-ash-agent-answers.md)), and the tool surface renamed
for MCP (`ash_*` prefixed). Full boot log:
[`transcripts/daemon-boot.txt`](transcripts/daemon-boot.txt).

Measured from process launch to first answered request on this machine
(project already compiled, warm cache): **~1.2s, once**. One honest wart in
the log, kept verbatim: this machine has no `inotify-tools`, so the file
watcher cannot bootstrap — the daemon says so, degrades to manual
`ash_reload`, and keeps serving. The optional dependency is genuinely
optional.

## The conversation, verbatim

One JSON-RPC request per `POST` to **`http://127.0.0.1:4100`** — the daemon
mounts its Plug at the root path, not under `/mcp` (the placeholder in the
old `.mcp.json` comment guessed `/mcp`; the daemon as shipped settles it).
Full transcript: [`transcripts/daemon-conversation.txt`](transcripts/daemon-conversation.txt);
pretty per-response captures sit alongside it as
`daemon-initialize.txt`, `daemon-tools-list.txt`,
`daemon-ash-describe-*.txt`, `daemon-ash-validate-book-bad-params.txt`,
`daemon-ash-search-appoint.txt`, `daemon-ash-daemon-status.txt`.

### initialize — protocol negotiation

```
-> {"jsonrpc":"2.0","id":1,"method":"initialize",
    "params":{"protocolVersion":"2024-11-05","capabilities":{},
              "clientInfo":{"name":"capstone-evidence","version":"1.0"}}}
<- {"id":1,"result":{"capabilities":{"tools":{"listChanged":false}},
                     "protocolVersion":"2024-11-05",
                     "serverInfo":{"name":"ash_agent_tools","version":"0.1.0"}},
    "jsonrpc":"2.0"}
```

The client asked for `2024-11-05` and the daemon negotiated **down** to it
rather than answering with its newest revision — older MCP client stacks stay
first-class.

### tools/list — the Mix-task surface, mapped 1:1

```
-> {"jsonrpc":"2.0","id":2,"method":"tools/list"}
<- {"id":2,"tools":["ash_describe","ash_validate","ash_search","ash_context",
                    "ash_forbidden","ash_daemon_status","ash_reload"]}
```

Seven tools. Six of them are the Mix tasks under other names; the seventh,
`ash_daemon_status`, could not exist before — it reports the boot-once ledger
itself (`booted_at`, `compiled_at`, reload count, cache entries, BEAM
memory). `ash_forbidden` is also worth pausing on: the gap log records that
`explain_forbidden/2` is the one function with no Mix task behind it, and the
daemon closes that from the other side — over MCP it is an ordinary tool like
the rest.

### tools/call ash_describe — the same answer as 03, over HTTP

The `complete` contract, asked the way [03](03-ash-agent-answers.md) asks it
through `bin/ash-agent`:

```json
{
  "name": "complete", "type": "update",
  "description": "The visit happened. Clinical notes are mandatory.",
  "accept": [],
  "input": { "required": ["notes"], "optional": [], "private": [] },
  "arguments": [{
    "name": "notes", "type": "string",
    "description": "What was found and what was done.",
    "required?": true, "allow_nil?": false, "public?": true, "default": null,
    "constraints": { "min_length": 10, "max_length": 4000, "trim?": true, "allow_empty?": false },
    "source": { "file": ".../lib/clinic_demo/scheduling/appointment.ex", "line": 215 }
  }],
  "source": { "file": ".../appointment.ex", "line": 208 },
  "returns": { "kind": "record", "type": "Elixir.ClinicDemo.Scheduling.Appointment" },
  "code_interfaces": [{ "name": "complete_appointment", "domain": "Elixir.ClinicDemo.Scheduling",
                        "args": ["notes"], "get?": false, "on_resource?": false }]
}
```

Same JSON the Mix task prints, plus three things `688fad7` added that the
pinned-`b1732ab` tree did not carry: `constraints` on arguments (the ten
characters of clinical notes are now visible *in the contract*, not only in
the error), the domain-declared `code_interfaces`, and — on the resource
level, shown by `ash_describe` without an action — `aggregates` and
`calculations` blocks. Those three additions are the capstone dogfood gaps
(fixed upstream in `f90c70e`); see the README's known-gaps section for what
that did to the gap list.

### tools/call ash_validate — the four-mistakes input, nothing run

The same bad params 03 feeds the Mix task:

```json
{ "valid?": false, "action": "book", "action_type": "create",
  "errors": [
    { "path": "patient_id",   "message": "is invalid" },
    { "path": "clinicianId",  "message": "unknown input \"clinicianId\" for action :book; ...",
      "did_you_mean": ["clinician_id"] },
    { "path": "clinician_id", "message": "is required" },
    { "path": "scheduled_at", "message": "is required" },
    { "message": "Invalid value provided for reason: length must be greater than or equal to 3." },
    { "message": "Invalid value provided for duration_minutes: must be greater than or equal to 5." } ],
  "normalized_inputs": { "reason": "Hi", "duration_minutes": 3 },
  "expected": { "required": ["patient_id","clinician_id","scheduled_at","reason"],
                "optional": [ { "name": "duration_minutes", "type": "integer",
                                "constraints": { "min": 5, "max": 240 } },
                              { "name": "severity", "type": "integer",
                                "constraints": { "min": 1, "max": 5 } } ] } }
```

Byte-for-byte the same class of answer as the Mix task: camelCase key with a
spelling suggestion, malformed UUID, missing requireds, two constraint
violations — and now the optional constraints are in the `expected` block
itself, so an agent no longer learns the five-minute floor by sending a 3.
Nothing ran, exactly as before.

## Timing: boot once vs boot every call

[`transcripts/daemon-timing-vs-mix-task.txt`](transcripts/daemon-timing-vs-mix-task.txt),
captured in the same minute on the same machine:

| Path | Boot | Per call |
|---|---|---|
| `mix ash_agent.serve` daemon | ~1.2s, **once** | 1.1–10.4ms (5 HTTP round trips; the 10ms outlier is a cold describe-cache entry) |
| `bin/ash-agent` Mix task | every call | 1.78–2.36s (3 calls, warm) |

Warm machine, compiled project — the same caveat [05](05-waits.md) carries —
but the ratio is structural, not thermal: the daemon's per-call cost is an
HTTP round trip over in-memory state; the Mix task's is a BEAM boot. The
cold-machine gap is wider than the table shows, because after a branch switch
the Mix task's boot absorbs a recompile while the daemon's boot already did.

`ash_daemon_status` at capture time:

```json
{"status":"ready","domain_count":3,"resource_count":11,"reloads":0,"cache_entries":3,
 "beam_memory_bytes":93389696,
 "booted_at":"2026-09-21T07:22:22Z","compiled_at":"2026-09-21T07:22:22Z"}
```

## The wiring, live

The three-step swap `docs/agents.md` described is done and verified:

1. `.mcp.json` — the `ash_agent` http entry is live under `mcpServers`
   (`http://127.0.0.1:4100`, root path), with the port documented next to it
   and the boot command in the comment.
2. `opencode.json` — `ash_agent` flipped to `"enabled": true`, URL corrected
   from the guessed `…/mcp` to the root path the daemon actually mounts.
3. `.claude/settings.json` — the `bin/ash-agent` allowlist entries **stay**,
   deliberately: the daemon serves MCP clients, while `bin/ash-agent` is what
   a shell, a CI job, or a person pasting into a terminal uses. The two
   surfaces answer with the same JSON; this document's transcripts came from
   both.

The daemon is started by hand — `mix ash_agent.serve --port 4100` — and shows
as disconnected in any client until it is listening. That is the deployment
story on purpose: a dev tool, loopback-only, no auth, POST-only, with an
Origin check against DNS rebinding; nothing here should ever be exposed past
`127.0.0.1`.

## Reproducing

```sh
export ELIXIR_BIN_DIR=/nix/store/<elixir-1.19.5>/bin   # or have mix on PATH
mix compile                                            # the daemon boots compile-only
mix ash_agent.serve --port 4100 &                      # boot once
curl -s -X POST http://127.0.0.1:4100 \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"you","version":"1.0"}}}'
# …tools/list, tools/call as in transcripts/daemon-conversation.txt
kill %1 && ss -ltn | grep 4100   # nothing left listening
```
