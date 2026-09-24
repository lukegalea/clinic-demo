# 08 — Tidewave's MCP endpoint, captured live

**Status: filled.** The plug was wired dev-only (inside `if code_reloading?`
in `endpoint.ex`) but no MCP client actually talked to it. As of the CLIN-2
IDE work, `opencode.json` registers it (`type: "remote"`,
`http://127.0.0.1:4000/tidewave/mcp`, `enabled: true`) alongside the
`.mcp.json` entry Claude Code already had, and the endpoint is verified
answering end to end.

What follows was captured 2026-09-23 against the running dev server
(`mix phx.server` in the clinic-demo container, port 4000), with plain
`curl` — streamable-HTTP MCP, no session state (tidewave 0.9 answers
statelessly, no `Mcp-Session-Id` dance).

## initialize

```
POST /tidewave/mcp
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":
 "2025-03-26","capabilities":{},"clientInfo":{"name":"clinic-demo-proof",
 "version":"1.0"}}}
```

Response (abridged): `serverInfo: {"name":"Tidewave MCP Server",
"version":"0.9.0"}`, `protocolVersion: "2025-03-26"`, and the tool surface:
`get_logs`, `get_source_location`, `get_docs`, `project_eval`,
`execute_sql_query`, `browser_eval`, `create_design_canvas`.

## tools/call — project_eval evaluates in the running app

```
POST /tidewave/mcp
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"project_eval",
 "arguments":{"code":"tidewave? = Application.get_env(:clinic_demo, :tidewave?);
 domains = length(Application.get_env(:clinic_demo, :ash_domains));
 resources = ClinicDemo.Scheduling |> Ash.Domain.Info.resources() |> length();
 \"tidewave?=#{tidewave?} · ash_domains=#{domains} ·
 scheduling_resources=#{resources} · node=#{node()}\""}}}
```

```json
{"id":3,"result":{"content":[{"type":"text","text":
 "\"tidewave?=true · ash_domains=5 · scheduling_resources=4 ·
 node=nonode@nohost\""}]},"jsonrpc":"2.0"}
```

That is the runtime loop from [docs/agents.md](../agents.md) answering for
real: the config value, the configured domains, the Scheduling domain's
resources — read from the loaded node, not from source.

The endpoint is genuinely a listener, not an echo: a first probe with a
malformed pipe (`inspect() <> ...` piped) came back as an ArgumentError with
an Elixir 1.20.4 stacktrace through `Tidewave.MCP.Tools.Eval` — real
evaluation, errors and all.

## Notes

- Dev-only by construction: the plug sits inside `if code_reloading?`, so
  test/prod never mount it; there is nothing to verify outside dev.
- `browser_eval`/`create_design_canvas` exist in the surface but are not
  exercised here; the runtime loop this repository documents is
  `project_eval` / `get_docs` / `get_logs` / `execute_sql_query`.
- Loopback tool: the dev server binds 127.0.0.1 and should stay there.
