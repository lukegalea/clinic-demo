# PUBLISH — making this repository public, in one sitting

Everything is prepared so that publishing is one Luke action: work through
this checklist top to bottom. Nothing below requires code changes; section 2
is the one that wants human judgement.

## 1. Create the public repository

- [ ] New public GitHub repository (suggest name: `clinic-demo` or
      `capstone-demo`).
- [ ] `git remote add public <url>` (keep `origin` private; push explicitly
      to `public`).
- [ ] Push `main` and the tags. **Local commits only so far** — the history
      is meant to be read; skim `git log --oneline` once before pushing.

## 2. Sanitize: machine-specific paths and usernames

The grep already ran (2026-09-21, tracked files only, patterns:
`lukegalea` case-insensitive, `/home/luke`, `/nix/store`, plus
`ast-forks`, `~/.local`, `ideaforge`). Results by category, with the
recommended treatment:

### 2a. Package URLs — intentional, keep (12 hits)

`https://github.com/lukegalea/...` in [README.md](../README.md) (4),
[mix.exs](../mix.exs) (3), `priv/processes/appointment_visit.bpmn` (2 — the
BPMN `targetNamespace`), `docs/evidence/07-daemon-slot.md` (1), `mix.lock`
(2). These are the actual homes of the three packages; they are the citation,
not a leak. **Only change them if the packages themselves move accounts** —
and if they do, the BPMN namespace changes too, which invalidates nothing
(namespace is an identifier, not a fetch).

### 2b. Absolute home paths — prose docs already elided; decide on the transcripts

- **Numbered evidence docs (7 hits total):** `01` (one LSP request URI),
  `02` (2), `03` (1), `04` (2), `06` (3), `07` (1 — `~/.local/bin/expert`
  style, generic). Each is a verbatim quote of a tool output. The README's
  convention is `.../` elision for these; most already use it. If you want
  zero `/home/lukegalea` strings: a mechanical `.../capstone-demo/`
  substitution is safe, but it makes the prose docs *quotes that were
  edited* — the honest alternative is to keep them and let the README's
  "verbatim, noise and all" sentence cover them.
- **Raw transcripts (≈110 hits across 10 files in
  `docs/evidence/transcripts/`):** absolute paths are load-bearing here —
  they are what the tools actually printed. Two of them (the Serena logs in
  `serena-read.txt` / `serena-rename.txt` line 91) also carry the machine's
  whole `PATH`, including usernames of tools (`.fly`, `.pulumi`, `.nvm`).
  Nothing secret — no tokens, no hostnames — but it is personal-environment
  detail. **Recommendation: scrub the username with
  `sed 's|/home/lukegalea|/home/demo|g'` across `transcripts/*.txt` at
  publish time, and accept that the transcripts are then "verbatim modulo
  one sed"** — noted here either way so the choice is deliberate.

### 2c. Nix store hashes — parameterize or keep (8 files)

- `docs/agents.md` line 62: already elided (`/nix/store/...-elixir-1.19.5`).
- `docs/evidence/README.md` line 37 and
  `docs/evidence/bin/serena-mcp-smoke.exs` line 233: carry the full store
  hash `iqc2jyh…` of *this machine's* Elixir. Harmless (store hashes are not
  secrets) but machine-specific; the reproduce block should ideally say
  `ELIXIR_BIN_DIR=$(dirname "$(command -v elixir)")` or point at the
  reader's own store path.
- `06-environment.md` / `env-command-v.txt`: full hashes for the libxml2
  bin (xmllint). Same treatment.
- `serena-read.txt` / `serena-rename.txt`: the PATH lines again.

### 2d. Reviewed and fine as-is

- `~/ast-forks/expert`, `~/.local/bin`, `~/.local/libexec` in
  `bin/serena-mcp` and `docs/agents.md` — build instructions, no username.
- `.claude/settings.json`, `.serena/project.yml`, `.mcp.json`,
  `opencode.json` — no absolute personal paths (the `.mcp.json` uses
  `${CLAUDE_PROJECT_DIR:-.}`).
- No `ideaforge` email strings in tracked files (they exist only in commit
  metadata, which publishing the repo necessarily publishes — see §5).

### 2e. Re-run before pushing

```sh
git grep -il lukegalea ; git grep -l "/home/luke" ; git grep -l "/nix/store"
```

Every hit should be in a category above, or fixed before the push.

## 3. README polish for a cold reader

- [ ] Add badges (top of README): MIT licence, Elixir version
      (`elixir-lang/elixir`), tests count or a CI badge once the public repo
      has Actions.
- [ ] Topics: `elixir`, `phoenix`, `ash-framework`, `dmn`, `bpmn`,
      `mcp`, `ai-agents`, `developer-experience`.
- [ ] First paragraph already links `docs/storyline.md` — check it renders.

## 4. The one-command verify

On a clean checkout (fresh clone, not the dev tree):

```sh
mix setup && mix precommit && bin/ash-agent describe ClinicDemo.Scheduling.Appointment complete --pretty
```

`mix setup` needs the environment from the README: Postgres on
`localhost:5432` (`postgres`/`postgres`), `xmllint` on PATH
(`libxml2`), and Elixir ≥ 1.17 reachable (`mix` on PATH or `ELIXIR_BIN_DIR`
set — both `bin/ash-agent` and `bin/serena-mcp` prepend it themselves).
`mix precommit` is compile-with-warnings-as-errors, unused-deps check,
format, and the 43-test suite; `bin/ash-agent describe` then proves the
introspection surface answers on a stranger's machine. Expected at the end:
`"name": "complete"` and `"accept": []` in the JSON, exit 0.

## 5. Before you press the button

- [ ] Commit metadata publishes author name/email with the repo
      (`git log --format='%ae' | sort -u` to see what ships).
- [ ] Secrets: this repo has no CI config and no API tokens in-tree. The one
      in-tree credential is `config/dev.exs`'s `secret_key_base` — the
      standard `phx.new` development default, publicly known and safe to
      publish (`config/runtime.exs` correctly reads `SECRET_KEY_BASE` from
      the environment for prod). If you add Actions later, generate fresh
      keys — the reference app's read-only deploy keys are not copied here.
- [ ] `docs/evidence/README.md` says "captured on this machine" — that
      stays true and is the point; no edit needed.
