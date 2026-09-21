# 07 — The daemon slot: PENDING

**Status: pending a parallel lane (DX-2).** The `mix ash_agent.serve` daemon —
a read-only, supervised MCP-over-HTTP server on `127.0.0.1:4100`, started by
its own Mix task rather than mounted in this application — is being wired into
this repository's MCP configuration by another piece of work. When it lands,
its transcripts belong here.

What is already in the tree, waiting for it:

- `.mcp.json` — the commented slot describing the `"ash_agent"` http entry to
  add under `mcpServers`
- `opencode.json` — the `ash_agent` entry, present and `enabled: false`
- `docs/agents.md` — "The daemon slot": the three-step swap (add to
  `.mcp.json`, flip `enabled`, delete the `bin/ash-agent` allowlist entries)

Until then, the `ash_agent_tools` half of the wiring is `bin/ash-agent`, whose
evidence is [03](03-ash-agent-answers.md). The tool surface is the same either
way — describe, validate, search, context, laws — so nothing in these files
needs to change but the transport.

Placeholder for the daemon's own artifacts, to fill in when DX-2 lands:

- [ ] `mix ash_agent.serve` starts and answers `initialize` on
      `http://localhost:4100/mcp`
- [ ] `tools/list` exposes the same surface the Mix tasks wrap
- [ ] a `describe`/`validate` round trip over HTTP, matching `bin/ash-agent`'s
      JSON on stdout
- [ ] the swap steps in `docs/agents.md` performed and verified
