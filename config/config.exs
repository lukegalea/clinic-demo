# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :clinic_demo,
  ecto_repos: [ClinicDemo.Repo],
  ash_domains: [ClinicDemo.Scheduling, ClinicDemo.Decisions, ClinicDemo.Visits],
  generators: [timestamp_type: :utc_datetime]

# Ash reads `:ash_domains` above to find the domains it should know about.
# `include_embedded_source_by_default: false` and the policy settings below
# are the current Ash 3 recommendations; they are set explicitly so that
# upgrading Ash cannot silently change this app's behaviour.
config :ash,
  # Count unicode codepoints for `min_length`/`max_length`, which is how
  # Postgres counts them. Without this the same string can pass validation in
  # Elixir and be rejected by the data layer.
  default_string_length_count: :codepoints,
  include_embedded_source_by_default?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false]

# The full ash_a2ui v2 experience: semantic View/Edit rows, task-panel forms
# with explicit create/view/edit modes, and the admin_v1 semantic catalog
# (entityPage / dataGrid / recordPanel), rendered by the admin catalog wired
# up in assets/js/app.js. The catalog selection requires experience v2 — the
# two travel together.
config :ash_a2ui,
  experience_version: 2,
  catalog: :admin_v1

# Who is acting: the surfaces run every write under a Clinician — appointment
# transitions need an actor present, task completion goes through the engine's
# candidacy checks under that actor, and attribution gets a name. This is the
# demo's whole auth story, by design.
config :ash_a2ui,
  actor: [
    resource: ClinicDemo.Scheduling.Clinician,
    label: :full_name,
    filter: [active: true]
  ]

# The process engine's three host seams. `ash_bpmn` never guesses any of them:
# a diagram with a business rule task will not even compile without a decision
# resolver configured, and the error names this key.
config :ash_bpmn,
  ash_domains: [ClinicDemo.Visits],
  assignment_resolver: ClinicDemo.Visits.Roster,
  action_invoker: ClinicDemo.Visits.Invoker,
  decision_resolver: ClinicDemo.Decisions.Resolver,
  queue: :bpmn,
  max_attempts: 5

# This demo runs no Oban queue. The engine's shim executes advance jobs inline
# and parks timers in ETS, which keeps `mix phx.server` a single process with
# nothing to babysit. A real clinic runs real Oban and deletes this line.
config :ash_bpmn, oban_testing: :inline

# Configure the endpoint
config :clinic_demo, ClinicDemoWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: ClinicDemoWeb.ErrorHTML, json: ClinicDemoWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: ClinicDemo.PubSub,
  live_view: [signing_salt: "Jy235ON0"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  clinic_demo: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  clinic_demo: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
