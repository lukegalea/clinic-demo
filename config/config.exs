# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :clinic_demo,
  ecto_repos: [ClinicDemo.Repo],
  ash_domains: [
    ClinicDemo.Scheduling,
    ClinicDemo.Finance,
    ClinicDemo.Decisions,
    ClinicDemo.Visits,
    ClinicDemo.Events,
    ClinicDemo.Spikes,
    ClinicDemo.Judgments,
    ClinicDemo.BusinessEvents,
    AshCompliance.Domain
  ],
  generators: [timestamp_type: :utc_datetime]

# ash_compliance: every resource resolves its repo and table prefix at COMPILE
# time (`Application.compile_env`), so this block must exist before the deps
# ever compile — a fresh checkout that compiled first would bake in the wrong
# repo and fail at runtime with "relation does not exist".
config :ash_compliance,
  repo: ClinicDemo.Repo,
  table_prefix: "ash_compliance_"

# ash_events_projections: same compile-time ruling as ash_compliance above —
# the projector engine's internal resources (Checkpoint, DeadLetter, Registry)
# resolve their repo and table prefix when the dep compiles. The value
# projection's drain (BPSim BD-3) runs those resources against this app's
# repo, under the engine's default table prefix.
config :ash_events_projections,
  repo: ClinicDemo.Repo,
  table_prefix: "ash_projection_"

# ash_compliance's host wiring, per its README.
config :ash, ash_domains: [AshCompliance.Domain]

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
  policies: [no_filter_static_forbidden_reads?: false],
  # Temporal resources: `Appointment` is one (board time travel reads it
  # "as of" an instant), and the temporal safety gate refuses any change,
  # validation or preparation on it whose module has not declared itself
  # safe to run at a point in time that is not now. The clinic's own
  # modules declare `temporal_safe?/1` in their own files, with the
  # reasoning written next to the code; this list is the sanctioned escape
  # hatch for hex-dep modules we cannot edit. `transition_state` just sets
  # the `:status` attribute from the state machine's declaration — no
  # clock reads, no side effects — which is exactly what the declaration
  # asserts.
  temporal_safe_modules: [
    # ash_state_machine's transition setter: just writes `:status` from the
    # machine's declaration — no clock reads, no side effects.
    AshStateMachine.BuiltinChanges.TransitionState,
    # ash_events' replay-machinery guard: the `where:` validation that keeps
    # an introspection-only copy of a change from ever running. It executes
    # nothing by construction, so it is safe at any instant.
    AshEvents.Events.Validations.Never,
    # ash_events_projections' ops applier: the projector engine's write path
    # onto a temporal projection. It reads no clock — the DRAIN is the
    # temporal driver, handing each write its `as_of` (the event's
    # `occurred_at`, the source's truth time). The fold itself is a pure
    # function of the event and the row it lands on (BPSim BD-3).
    AshEvents.Projections.ApplyOpsChange
  ]

# ash_a2ui: every surface composes through the experience layer (there is
# no experience version to pin since ash_a2ui a3c1763). The component
# catalog stays at its `:basic` default. f777ede turned admin_v1 off
# because the admin composition dropped the board's sectioned table;
# ash_a2ui #16 fixed that, and admin_v1 was re-tried against a3c1763 with
# the visual suite. It broke three things this app depends on:
#
#   * prompt row actions (Record weight, Complete, Cancel) invoke straight
#     away with no prompt to collect their values, so they fail with
#     "Validation failed";
#   * the read-only View panel (recordPanel) has no way to close it;
#   * the dataGrid shows every row action on every row, ignoring
#     visible_when (Check in on completed visits), and on the schedule the
#     action column runs off the right edge.
#
# Re-enable `catalog: :admin_v1` when those land upstream.
#
# Reference links (the schedule's patient and clinician columns) resolve to
# surface keys through ClinicDemoWeb.A2ui.Links, which also opens them. They
# no longer need admin_v1: since ash_a2ui 25c6b8f the basic catalog draws a
# to-one link as a button whenever the LiveRenderer can navigate, which
# ScheduleLive's :open_surface callback provides.
config :ash_a2ui,
  actor: [
    resource: ClinicDemo.Scheduling.Clinician,
    label: :full_name,
    filter: [active: true]
  ],
  link_resolver: ClinicDemoWeb.A2ui.Links

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

# The judgment pipeline's host wiring (P4-S4): the materialiser's facts
# resource, the observation ledger its C1 evidence assertion reads, and
# the stack's region — law 10 says every ledger row carries it, host
# config, never a caller input.
config :ash_judgments, :facts, ClinicDemo.Judgments.Fact
config :ash_judgments, :ledger, ClinicDemo.Judgments.Observation
config :ash_judgments, region: :ca

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

# Configure esbuild (the version is required). NODE_PATH includes
# assets/node_modules because the bpmn-js/dmn-js imports live inside
# deps/*/priv/js — Node resolution walks up from the importing file and
# would never reach the app's assets without it.
config :esbuild,
  version: "0.25.4",
  clinic_demo: [
    # The bpmn-js / dmn-js stylesheets reference their icon fonts by URL
    # with cache-buster query strings; without an explicit loader esbuild
    # refuses the build outright. Inlined as data URLs, which
    # `font-src 'self' data:` in the CSP permits.
    args:
      ~w(js/app.js js/operator_diagram.js js/flight_view.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --external:/assets/* --alias:@=.) ++
        ~w(--loader:.woff=dataurl --loader:.woff2=dataurl --loader:.ttf=dataurl
           --loader:.eot=dataurl --loader:.svg=dataurl),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../assets/node_modules", __DIR__),
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ],
  # Dev-only storybook entry (assets/js/storybook.js): the bundle the
  # storybook loads to reach the app's LiveView hooks/params/uploaders.
  # Built by the `storybook_*` watchers in config/dev.exs.
  storybook: [
    args: ~w(js/storybook.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../assets/node_modules", __DIR__),
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path()
      ]
    }
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
    env: %{
      "NODE_PATH" => [
        Path.expand("../assets/node_modules", __DIR__),
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path()
      ]
    }
  ],
  # Dev-only storybook styles (assets/css/storybook.css). The entry mirrors
  # app.css's imports and @source scanning so stories emit exactly the
  # utility classes the app build emits — a storybook that styles
  # differently from the app is worse than none.
  storybook: [
    args: ~w(
      --input=assets/css/storybook.css
      --output=priv/static/assets/css/storybook.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{
      "NODE_PATH" => [
        Path.expand("../assets/node_modules", __DIR__),
        Path.expand("../deps", __DIR__),
        Mix.Project.build_path()
      ]
    }
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
