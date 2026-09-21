# 06 — Environment: what is on PATH, and does the script's CLI still match

Transcript: [`transcripts/env-command-v.txt`](transcripts/env-command-v.txt),
[`transcripts/serena-flag-drift.txt`](transcripts/serena-flag-drift.txt).
Captured 2026-09-21.

## The four commands, in a plain shell

```
$ command -v uvx; command -v xmllint; command -v expert; command -v mix
.../.local/share/devbox/global/default/.devbox/nix/profile/default/bin/uvx
.../.local/bin/expert
(exit 1 -- mix is the one that is missing; both bin/ scripts accept ELIXIR_BIN_DIR)
```

Two present, two absent, and every absence has a documented answer:

| Command | State | How it is provided |
|---|---|---|
| `uvx` | on PATH (devbox profile) | installs/runs Serena from `git+https://github.com/oraios/serena`; nothing vendored |
| `expert` | on PATH (`~/.local/bin/expert`) | the fork build; `bin/serena-mcp` re-wins PATH through its shim dir |
| `mix` | **not on PATH** (Nix setup) | `ELIXIR_BIN_DIR="$(dirname "$(command -v elixir)")"`, which both `bin/ash-agent` and `bin/serena-mcp` prepend themselves |
| `xmllint` | **not on PATH** | `export PATH="$(ls -d /nix/store/*libxml2*-bin/bin | head -1):$PATH"` before `mix test` |

```
$ command -v xmllint   # with the libxml2 bin dir on PATH
/nix/store/...-libxml2-2.11.5-bin/bin/xmllint
xmllint: using libxml version 21105
```

Without `xmllint`, 32 of 43 tests fail with `schema_validator_unavailable` —
which reads like a code bug and is an environment gap. It is the first thing
to check when the test suite looks broken.

## Serena flag drift (uvx tracks upstream `main`)

`bin/serena-mcp` calls `serena start-mcp-server --context "$SERENA_CONTEXT"
--project "$root" --transport stdio`. Against `--help` from the same `main`
uvx resolves today (`Serena 2.0.0.dev0`):

- `--context` — present (default has become `desktop-app`; the script's
  `claude-code`/`agent` override is what pins it)
- `--project` — present; it has absorbed `--project-file`, which is now
  **deprecated** in the help text. The script never used it.
- `--transport` — present (`stdio|sse|streamable-http`)

No drift: every flag the script passes still exists with the same meaning. Two
nearby renames to watch, seen in the same help: `--project-file` (deprecated,
not used) and the context default (changed, overridden by the script).

## Serena machine config, which this session had to create

First run of `bin/serena-mcp` generated `~/.serena/serena_config.yml` with
`trusted_project_path_patterns: []` — and without this repository in that
list, Serena skips `.serena/project.yml`'s `activation_command` *silently*,
exactly as `docs/agents.md` warns. The session added:

```yaml
trusted_project_path_patterns:
  - .../capstone-demo
```

and the next run logged `Running activation_command for project
'clinic_demo': mix compile`. One more machine-config behaviour worth knowing:
on load, Serena rewrites `.serena/project.yml` into its canonical template
(semantically lossless — same `project_name`, `language_servers`,
`activation_command`, `initial_prompt`; it adds keys and its own comments).
The committed file is the curated artifact; after a Serena run,
`git checkout -- .serena/project.yml` puts it back.
