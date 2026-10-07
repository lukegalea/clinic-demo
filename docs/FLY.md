# Fly.io deployment — clinic-demo

Repo-side prep lives in this branch (`fly-prep`): `Dockerfile`, `fly.toml`
(the app), `fly.pg.toml` (the Postgres sidecar), the demo gate
(`ClinicDemoWeb.Gate`), and the release seed path
(`ClinicDemo.Release`). **Nothing in this document has been executed** —
and nothing billable exists until you upgrade the plan and run it.

Architecture: two apps on one private network.

```
                 internet
                    │ https (force_https, *.fly.dev cert)
            ┌───────▼────────┐         6PN private network
            │  clinic-demo   │◄──────── clinic-demo-pg.internal:5432
            │ shared-cpu-1x  │        ┌─────────────────────┐
            │     512mb      │        │    clinic-demo-pg   │
            │  auto-stop: on │        │  pgvector 0.8.7-pg18│
            └────────────────┘        │  1gb + 3gb volume   │
                                      │   (never stops)     │
                                      └─────────────────────┘
```

Why a sidecar and not Fly Postgres: the repo floor is **PostgreSQL 18**
(`ClinicDemo.Repo.min_pg_version/0` — migrations may use PG18 features),
and the image is `pgvector/pgvector:0.8.7-pg18`, which also ships the
`vector` extension. `citext` and `btree_gist` (the other two entries in
`installed_extensions`) come with the standard contrib the image includes;
`ash-functions` is installed by AshPostgres during migration. All four are
created by the app's own migrations/extensions setup on first boot.

---

## 0. Prerequisites

1. `flyctl` installed and logged in (`fly auth login`).
2. **Plan upgrade** — this is the billable gate. Everything below creates
   resources (two apps, one volume, one always-on machine). Nothing here
   runs or costs anything until you do it.
3. Pick a region — the configs say `yyz` (Toronto); change
   `primary_region` in both `fly.toml` and `fly.pg.toml` if you prefer
   another. Everything must be single-region (the volume is pinned to its
   region).

## 1. Create the apps

```sh
fly apps create clinic-demo          # the Phoenix app
fly apps create clinic-demo-pg       # the Postgres sidecar
```

Both land in your default org, which means both share the org's private
network — `clinic-demo-pg.internal` resolves from `clinic-demo`. That is
the only wiring they need.

If the names are taken, pick alternates and update `app =` in the two
toml files plus the `DATABASE_URL` host below.

## 2. Postgres sidecar first

Create the volume (name matches `fly.pg.toml`'s `[mounts].source`):

```sh
fly volumes create clinic_demo_pg_data \
  -a clinic-demo-pg --region yyz --size 3
```

Set the initdb credentials as secrets (read once by Postgres on **first**
boot; changing them later requires changing them inside Postgres too):

```sh
fly secrets set -a clinic-demo-pg \
  POSTGRES_USER=clinic \
  POSTGRES_PASSWORD="$(openssl rand -hex 24)" \
  POSTGRES_DB=clinic_demo
```

Copy the generated password somewhere — the app's `DATABASE_URL` in step 3
embeds it.

Deploy the sidecar:

```sh
fly deploy -a clinic-demo-pg -c fly.pg.toml
```

`fly.pg.toml` pins `PGDATA=/data/pgdata` **inside** the volume, so data
survives machine replacement; do not "simplify" it to the image default.

Verify it came up and has the extensions we rely on:

```sh
fly status -a clinic-demo-pg
fly ssh console -a clinic-demo-pg \
  -C "psql -U clinic -d clinic_demo -c \"select version();\" -c \"select name from pg_available_extensions where name in ('vector','btree_gist','citext');\""
```

Expect PostgreSQL 18.x and all three names. (They are *available* at this
point; the app's migrations create the ones it uses.)

## 3. App secrets

```sh
fly secrets set -a clinic-demo \
  SECRET_KEY_BASE="$(mix phx.gen.secret)" \
  DATABASE_URL="ecto://clinic:<PG_PASSWORD>@clinic-demo-pg.internal:5432/clinic_demo" \
  DEMO_GATE_PASSWORD="$(openssl rand -base64 12)"
```

* `SECRET_KEY_BASE` — signs the session cookie the gate flag and the a2ui
  actor live in. Rotating it logs everyone out; that's all.
* `DATABASE_URL` — the runtime raises without it (config/runtime.exs).
* `DEMO_GATE_PASSWORD` — the one shared password for the whole demo; the
  runtime raises without it in prod. This is what you hand out with the
  URL.

Optional: `POOL_SIZE` (default 10 — leave it on 512mb) and
`AI_INTERPRETER_MODEL`/provider keys for the agent console (it degrades
honestly without them).

## 4. First deploy

```sh
fly deploy
```

The `[deploy] release_command = "/app/bin/migrate"` runs **before** the
release takes traffic: a temporary machine boots the new image, applies
migrations (10-minute budget), then the real machine starts. If migration
fails, the deploy fails and the old release keeps running.

First deploy has no old release — watch it:

```sh
fly logs -a clinic-demo
fly status -a clinic-demo
```

`/health` is the load-balancer check (grace 30s); the machine won't take
traffic until it answers.

## 5. Seed the demo data

```sh
fly ssh console -a clinic-demo \
  -C "/app/bin/clinic_demo eval ClinicDemo.Release.seed()"
```

Same semantics as `mix seed` locally (`priv/repo/seeds.exs`): publishes
the DMN decision + BPMN process, books a day of visits, walks several
through the process, activates the compliance bundle. Idempotent —
re-running updates-in-place rather than duplicating.

## 6. Verify

```sh
curl https://clinic-demo.fly.dev/health          # → ok
```

Then in a browser: `https://clinic-demo.fly.dev` → the gate → your
`DEMO_GATE_PASSWORD` → the board, seeded and live. Any deep link you were
en route to survives the gate (the `next` param returns you there).

## 7. Reset procedures

**Data reset only** (schema survives, demo data rebuilt):

```sh
fly ssh console -a clinic-demo-pg
psql -U clinic -d clinic_demo \
  -c "DROP SCHEMA public CASCADE; CREATE SCHEMA public;"
exit
fly ssh console -a clinic-demo -C "/app/bin/clinic_demo eval ClinicDemo.Release.migrate()"
fly ssh console -a clinic-demo -C "/app/bin/clinic_demo eval ClinicDemo.Release.seed()"
```

(The migrate here runs outside a deploy on purpose; the release_command
only fires on `fly deploy`.)

**Full teardown** (billable resources gone — the inverse of this
document):

```sh
fly apps destroy clinic-demo
fly apps destroy clinic-demo-pg     # refuses while the volume exists
fly volumes destroy clinic_demo_pg_data -a clinic-demo-pg
```

## 8. Operating notes

* **Idle cost**: the app auto-stops (`auto_stop_machines = "stop"`) and
  wakes on the next request; only the Postgres sidecar runs continuously.
  The demo's floor cost ≈ the pg machine (shared-cpu-1x / 1gb) + the 3gb
  volume.
* **OOM**: 512mb is tight for BEAM + BPMN + AI deps. If the machine gets
  kill-happy (`fly logs` shows restarts), `fly scale memory 1gb -a
  clinic-demo` — or uncomment `swap_size_mb` in `fly.toml`.
* **Gate**: `config :clinic_demo, :gate` — password via
  `DEMO_GATE_PASSWORD`, on/off via `enabled?` (false in test, so CI never
  sees it). It is a demo lock: one shared password, no rate limiting, no
  accounts. If a leak ever matters, `fly secrets set -a clinic-demo
  DEMO_GATE_PASSWORD=<new>` — a secrets change rolls a new release on its
  own, and every existing session keeps working until its cookie expires
  (the flag, not the password, is what sessions carry).
* **Deployments**: `fly deploy` migrates first (release_command), then
  rolls. First boot after `apps create` with no machines:
  `fly deploy` creates them from `fly.toml`.
* **SSH**: `fly ssh console -a clinic-demo` for a shell,
  `-C "..."` for one-shots. The release's eval entrypoint is
  `/app/bin/clinic_demo eval "ClinicDemo.Release.migrate()"` etc.
