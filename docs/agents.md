# Agent wiring

Two MCP servers, side by side, because there are two kinds of question and
neither tool can answer the other's.

| Server | Answers | Reached by |
|---|---|---|
| [Serena](https://github.com/oraios/serena) | Where is this function, who calls it, rename it everywhere, is it safe to delete | `bin/serena-mcp`, over an Elixir language server |
| `ash_agent_tools` | What does this action accept, what are this attribute's constraints, what is declared at this line, what could forbid this call | the MCP daemon (`mix ash_agent.serve`, port 4100), or `bin/ash-agent` in a shell |

## Why two

A language server sees Elixir. It sees `defmodule ClinicDemo.Scheduling.Appointment`
and it sees the functions inside it, and for renaming a function or finding
every caller of one there is nothing better.

It does not see any of this:

```elixir
update :complete do
  description "The visit happened. Clinical notes are mandatory."

  argument :notes, :string do
    allow_nil? false
    constraints min_length: 10
  end

  change set_attribute(:status, :completed)
end
```

To Expert that is a call to `update/2` with a block. There is no symbol named
`complete`, no symbol named `notes`, and nothing anywhere that says the
argument is required, is a string, or must be ten characters. `find_symbol`
cannot find an action, because an action is not a symbol — it is data in a
DSL, assembled at compile time and readable only by asking the compiled
module.

That is what `ash_agent_tools` asks, and why the two servers are complementary
rather than redundant. Serena is the generic half. `ash_agent` is the half
that knows what this application is.

The split is worth stating as a rule, because an agent that guesses wrong
wastes a round trip either way:

- **A name, a function, a module, a caller** → Serena.
- **An action, an attribute, an argument, a relationship, a policy, a line
  number in a resource** → `bin/ash-agent`.

## Setting it up

### 1. Elixir on PATH

Both halves need it. `bin/ash-agent` runs Mix; Serena shells out to
`elixir --version` before it will start its Elixir backend at all, and
refuses if that fails.

If Elixir is not on your PATH — a Nix or devbox setup, typically — set
`ELIXIR_BIN_DIR` and both scripts will prepend it:

```sh
export ELIXIR_BIN_DIR=/nix/store/...-elixir-1.19.5/bin
```

One more command, found the same way, for the work that is not agent
wiring: `xmllint`. The DMN validator (`ash_decisions`, via `boxic_dmn`)
shells out to it, and without it 32 of the 43 tests fail with
`schema_validator_unavailable` — which reads like a code bug and is an
environment gap. On Nix, `libxml2` carries it.

### 2. Compile the project

**Serena's answers are only as current as `_build`.** Expert indexes compiled
modules, not source files, so a resource you have edited but not compiled is
invisible to `find_symbol` and stale in `find_referencing_symbols`.

`.serena/project.yml` runs `mix compile` as its `activation_command`, so this
is handled — *provided the project is trusted*. Serena only runs activation
commands and language-server settings for projects matching
`trusted_project_path_patterns` in `~/.serena/serena_config.yml`:

```yaml
trusted_project_path_patterns:
  - /home/you/capstone-demo
```

Without that entry the activation command is skipped silently and you are
back to compiling by hand. Do it by hand anyway the first time:

```sh
mix deps.get && mix compile
```

### 3. Build the Expert binary

Serena's Elixir backend *is* [Expert](https://github.com/elixir-lang/expert),
and it resolves the binary in this order:

1. an `expert` executable already on `PATH`
2. otherwise, a download of the version Serena pins — currently `v0.1.0-rc.6`

Take the first branch, because rc.6 is broken for exactly the thing Serena
does with it. `Expert.EngineApi.document_symbols/2` pattern-matched its
document argument as a `%Document{}`, and the `documentSymbol` handler
resolves documents with a fallback that returns `nil` for any URI not in the
document store — which is every file Serena indexes without opening first. The
result is a `FunctionClauseError` instead of a symbol list. Serena's own test
suite carries an xfail for it.

Commit `537338b` on our fork widens the API with a clause for the
unresolvable case, returning an empty list. In the current build a file
that was never opened is in fact answered one layer earlier, by the
request pipeline, with a structured *document could not be loaded* error —
ask `documentSymbol` for a URI no `didOpen` ever named and you get a
well-formed error response while the server stays up. Either shape is
honest LSP; what Serena must never see again is the crash. Build and
install it:

```sh
cd ~/ast-forks/expert                       # branch fix/document-symbol-crashes

# deps for both apps, with the EPMD flags the justfile uses
(cd apps/engine && elixir --erl "-start_epmd false -epmd_module Elixir.Forge.EPMD" -S mix deps.get)
(cd apps/expert && elixir --erl "-start_epmd false -epmd_module Elixir.Forge.EPMD" -S mix deps.get)

# a plain release -- no Zig, unlike the burrito default
(cd apps/expert && MIX_ENV=prod mix release plain --overwrite)

mkdir -p ~/.local/bin ~/.local/libexec
rm -rf ~/.local/libexec/expert
cp -a apps/expert/_build/prod/rel/plain ~/.local/libexec/expert
ln -sf ../libexec/expert/bin/start_expert ~/.local/bin/expert
```

That is `just install` unrolled, for a machine without `just`. Point
`EXPERT_BIN` somewhere else if you keep it somewhere else.

Check it answers before you wire anything to it:

```sh
elixir bin/expert-smoke.exs ~/.local/bin/expert
```

That script *is* the conversation Serena has — initialize, initialized,
didOpen, `textDocument/documentSymbol` — done by hand over stdio. A list of
symbols means `find_symbol` has something to find.

It is deliberately patient, and both reasons it has to be are worth knowing
before you debug a silence of your own:

- Expert sends the *client* requests during startup — `client/registerCapability`,
  `window/workDoneProgress/create` — and waits for answers before it will get
  on with indexing. A client that ignores them looks exactly like a server
  that has hung. The script answers them.
- `documentSymbol` returns `null`, not an error, until indexing finishes. The
  script asks again, every ten seconds, rather than concluding the file has no
  symbols in it. `EXPERT_SMOKE_DEBUG=1` shows each message as it arrives.

### 4. Register the servers

**Claude Code** reads `.mcp.json` in the repository root. It registers one
server, `serena`, pointing at `bin/serena-mcp`. `.claude/settings.json`
allowlists `bin/ash-agent` so the other half runs without a prompt.

**opencode** reads `opencode.json`. Same `serena` entry, with Serena's
`agent` context rather than its `claude-code` one, since opencode's built-in
tools are not the ones the `claude-code` context is written against.

Both files also register the `ash_agent` MCP daemon — live in `.mcp.json`,
`"enabled": true` in `opencode.json`. See **The daemon slot**, below.

`uvx` must be on PATH; `bin/serena-mcp` installs and runs Serena with it and
does not vendor it.

## Waits

Nothing here is instant, and every one of these has been mistaken for a hang:

| | |
|---|---|
| First `bin/ash-agent` call | 10–15 seconds — a Mix boot. Batch your questions. |
| Serena's `activation_command` | as long as `mix compile` takes; a cold build is minutes |
| Expert's `initialize` | a minute or more on first contact, while it indexes |
| Serena cross-file answers | **~10 seconds after that**, before `find_referencing_symbols` is right |

That last one is Serena's own number, hard-coded in its Elixir backend as
`_get_wait_time_for_cross_file_referencing`. A `find_referencing_symbols` call
made immediately after startup is not wrong so much as early.

## Walkthrough

Three asks, one per tool, in the order you would actually hit them.

### Rename a symbol — Serena

> Rename `ClinicDemo.Decisions.Resolver.decide/3` to `evaluate/3`.

Serena's `rename_symbol` sends an LSP rename to Expert and applies the
resulting `WorkspaceEdit` across every file. In this repository the callers
are in `lib/clinic_demo/visits/`, `test/`, and the README's examples, and the
point of using the tool rather than `sed` is that it edits the first two and
not the third.

What Serena will *not* rename: the decision key `"appointment.triage"`, which
`decide/3` takes as an argument. That string is in `priv/decisions/appointment_triage.dmn`,
in `lib/clinic_demo/rules.ex`, and in `priv/processes/appointment_visit.bpmn`
as a `businessRuleTask` reference. It is data, not a symbol, and no language
server will find all three. Renaming an Ash action has the same shape and the
same problem — which is the gap `ash_agent_tools` exists to close, and does
not close yet.

### What does `book` accept — `ash_agent`

> What do I have to pass to book an appointment?

```sh
bin/ash-agent describe ClinicDemo.Scheduling.Appointment book --pretty
```

Four required inputs, two optional, each with a type, a description and a
file-and-line. Then check a call before making it:

```sh
bin/ash-agent validate ClinicDemo.Scheduling.Appointment book \
  '{"reason":"Hi","duration_minutes":"3","patient_id":"not-a-uuid","clinicianId":"x"}' --pretty
```

```json
{
  "valid?": false,
  "errors": [
    { "path": "clinicianId", "message": "unknown input ...", "did_you_mean": ["clinician_id"] },
    { "path": "patient_id", "message": "is invalid" },
    { "path": "clinician_id", "message": "is required" },
    { "path": "scheduled_at", "message": "is required" },
    { "message": "Invalid value provided for reason: length must be greater than or equal to 3." }
  ],
  "normalized_inputs": { "reason": "Hi", "duration_minutes": 3 }
}
```

Nothing ran. No changeset was submitted, no action fired, the database was not
touched — `validate` builds the input with `error?: false` and inspects it.
A camelCased key came back with a spelling suggestion; `"3"` came back cast to
`3`. Compare that with the alternative, which is calling `book_appointment/2`
and reading the exception.

### Why was that forbidden — `ash_agent`

> I called `:discharge` and got a Forbidden error. Why?

```sh
bin/ash-agent forbidden ClinicDemo.Scheduling.Appointment discharge
```

```json
{
  "policies": [
    { "description": "The schedule is readable by anything that can reach the application.",
      "condition": ["action.type == :read"], "checks": ["always true"], "access_type": "filter" },
    { "description": "Only a signed-in member of staff may change the schedule.",
      "condition": ["action.type in [:create, :update, :destroy]"], "checks": ["actor is present"],
      "access_type": "filter" }
  ],
  "authorizers": ["Ash.Policy.Authorizer"],
  "guidance": ["Authorization is deny-by-default: ...", "..."]
}
```

`:discharge` is an update, so the second policy applies and it wants an actor.
The report lists what *can* deny; it does not run the check. For a verdict,
`Ash.can?/3` with the actor you intend to use.

Two honest caveats on this one. It is a listing, so a `Forbidden` you get from
something other than a policy — a validation, a status guard like
`:discharge` refusing an appointment that was never written up — will not
appear here at all. And `forbidden` is the one subcommand `bin/ash-agent`
implements itself: `AshAgentTools.explain_forbidden/2` is a library function
with no Mix task behind it, so the wrapper calls it through `mix run`. That
is logged in `.agents/logs/tool-gaps.log`.

## The daemon slot

`ash_agent_tools` ships an MCP daemon: `mix ash_agent.serve` boots a
read-only, supervised MCP-over-HTTP server on `127.0.0.1:4100`, started by
its own Mix task rather than mounted in this application. The boot contract
is the same one the introspection tasks use — **compile, don't start**: the
configured domains are loaded, but no Phoenix endpoint and no Oban queues,
because an introspection tool has no business owning them.

Start it by hand from the repository root:

```sh
mix ash_agent.serve --port 4100
```

Until it is listening, the clients show the server as disconnected; that is
the design, not a failure. Loopback only, POST only, no auth — a dev tool
with an Origin check against DNS rebinding, and nothing that should ever be
exposed past `127.0.0.1`.

What it changes is arithmetic, not the answers. Every `bin/ash-agent` call is
a fresh Mix process and pays the boot every time (one to two seconds warm,
10–15 cold); the daemon pays it once and answers each call from in-memory
compiled state in single-digit milliseconds. Same JSON either way, which is
what [07 in `docs/evidence/`](evidence/07-daemon-slot.md) demonstrates: the
same `describe`/`validate` questions put to both paths, transcripts from
each, and the clock to compare them.

The wiring is live in both clients:

1. `.mcp.json`, under `mcpServers`:

   ```json
   "ash_agent": { "type": "http", "url": "http://127.0.0.1:4100" }
   ```

   (the root path — the daemon mounts its Plug at `/`, not `/mcp`)

2. `"enabled": true` on the `ash_agent` entry in `opencode.json`, with the
   same URL.

If you move the port — `--port`, or
`config :ash_agent_tools, :daemon, port: ...` — change both entries to match.

The tool surface is the same either way — describe, validate, search,
context, forbidden, status, reload — so nothing else in this document
changes. `bin/ash-agent` stays useful regardless: it is what a shell, a CI
job or a person uses, and its allowlist entries in `.claude/settings.json`
are kept for exactly that reason.

## Why `tidewave` and `ash_ai_dev` are not here

Both attach over HTTP to a running Phoenix dev server, and both are
dependencies this application does not have. It is a standalone demo, not the
reference app they are configured in. Adding the entries without the
dependencies would give you two servers that never connect.

## The GPL boundary

Serena is GPL-3.0+ (its `solidlsp` subdirectory is MIT; the rest is not).
Nothing in this repository links to it, imports it, vendors it or derives from
it. What is here is:

- `bin/serena-mcp`, a shell script that runs the published tool and hands it
  a path
- `.serena/project.yml` and `.mcp.json`, configuration

That is the integration, deliberately and entirely. Design ideas can be read
from a GPL project freely; code cannot be taken from one into an
Apache-licensed one, and none has been.

## A correction worth carrying

Serena's documented `ls_specific_settings.<language>.ls_path`, which most of
its backends accept for "use my binary, not your download", **is not
implemented for Elixir**. `solidlsp`'s `ElixirTools` writes its own dependency
setup rather than deriving from `LanguageServerDependencyProviderBaseCommand`,
and the only key it reads is `expert_version`. Serena's own configuration
documentation lists the backends that honour `ls_path`, and `elixir` is not
among them.

What it does do, first, before anything else, is `shutil.which("expert")` —
so **PATH is the supported override**, and PATH is what `bin/serena-mcp` sets,
through a directory containing nothing but a symlink named `expert` so that no
other command is shadowed.

Verified against `oraios/serena` at `main`, 2026-09-21:
`src/solidlsp/language_servers/elixir_tools/elixir_tools.py`,
`src/solidlsp/dependency_provider.py`,
`docs/02-usage/050_configuration.md`.

## What is verified, and what is not

Verified headlessly, on this machine, 2026-09-21:

- `bin/ash-agent` end to end — `describe`, `validate`, `search`, `context`,
  `laws`, `forbidden` — run from a directory that is not the repository root,
  each returning parseable JSON
- the Expert binary built from `537338b`, starting under `--stdio` and
  answering `initialize` and `textDocument/documentSymbol` for
  `lib/clinic_demo/scheduling/appointment.ex` (`bin/expert-smoke.exs`)
- the same binary asked for `documentSymbol` on a file no `didOpen` ever
  named — the rc.6 crash shape — answering a structured error with the
  server still up
- `mix precommit`, green: 43 tests, no warnings-as-errors, once `xmllint`
  is on PATH
- the `ash_agent` MCP daemon (`mix ash_agent.serve --port 4100`) —
  `initialize`, `tools/list`, and `ash_describe`/`ash_validate` round trips
  over HTTP, with boot-once vs per-call timing against `bin/ash-agent`
  ([docs/evidence/07](evidence/07-daemon-slot.md))

Not verified headlessly: Serena itself. It needs an MCP client session, and
the tools worth seeing — `find_symbol`, `find_referencing_symbols`,
`rename_symbol` — are only meaningful through one. The manual check is:

```sh
mix compile
claude          # in this repository; /mcp should list `serena` as connected
```

then, in the session:

1. `get_symbols_overview` on `lib/clinic_demo/decisions/resolver.ex`
2. `find_symbol` for `decide`, with `include_body`
3. `find_referencing_symbols` for it — **after the ten-second wait**
4. `bin/ash-agent describe ClinicDemo.Scheduling.Appointment book --pretty`,
   for the contrast: the second tool answering what the first cannot
