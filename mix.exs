defmodule ClinicDemo.MixProject do
  use Mix.Project

  def project do
    [
      app: :clinic_demo,
      version: "0.1.0",
      # runtime.exs uses 1.20 regex modifiers (~r"..."E) and the boxic_*
      # packages already require ~> 1.20.
      elixir: "~> 1.20",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      docs: docs(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      consolidate_protocols: Mix.env() != :dev,
      listeners: [Phoenix.CodeReloader] ++ clarity_listener(),

      # Agent instructions for the a2ui surfaces, linked rather than inlined
      # (same trade as ash_enterprise: a pointer instead of ~130k chars of
      # always-loaded content). Regenerate with `mix usage_rules.sync`.
      usage_rules: [file: "AGENTS.md", usage_rules: [{:ash_a2ui, link: :markdown}]],

      # The one known finding — injected by `use AshBpmn.Web.DesignerLive` —
      # is documented in the ignore file rather than suppressed inline.
      dialyzer: [ignore_warnings: ".dialyzer_ignore.exs"]
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {ClinicDemo.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  #
  # lib/clinic_demo_web/storybook.ex `use`s phoenix_storybook, a dev-only
  # dep — compiling it in test/prod (where the dep is not fetched) fails.
  # The router's storybook scope is gated on :dev_routes, so nothing
  # references the module outside dev; `without_storybook/1` keeps it out
  # of the compile set in those envs.
  defp elixirc_paths(:dev), do: ["lib"]
  defp elixirc_paths(:test), do: without_storybook(["lib", "test/support"])
  defp elixirc_paths(_), do: without_storybook(["lib"])

  # Expand the "lib" directory into explicit .ex files minus the storybook
  # backend. Both glob shapes are listed because `**` matching zero path
  # segments (i.e. files directly under lib/) varies by implementation;
  # Enum.uniq/1 collapses the overlap.
  defp without_storybook(paths) do
    (paths
     |> Enum.flat_map(fn
       "lib" -> Path.wildcard("lib/**/*.ex") ++ Path.wildcard("lib/*.ex")
       path -> [path]
     end)
     |> Enum.uniq()) -- ["lib/clinic_demo_web/storybook.ex"]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.2.0"},
      # Component storybook, mounted at /storybook behind Mix.env() == :dev.
      # Unconditional (like Clarity) — the router's import needs the module
      # in the code path at compile time regardless of the route guard, and
      # `if Mix.env()` in a module body still expands macros in dead branches.
      {:phoenix_storybook, "~> 1.5"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.5", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},

      # Ash. The domain model this demo exists to introspect.
      {:ash, "~> 3.0"},
      {:ash_postgres, "~> 2.0"},

      # The Appointment lifecycle as a formal machine: transitions declared
      # on the resource, checked by Ash. One authority for what states a
      # visit may move between; the BPMN graph orchestrates when.
      {:ash_state_machine, "~> 0.2.13"},

      # Decisions and process, the two halves of the rules layer. A DMN table
      # says how urgent an appointment is; a BPMN graph says what happens to it
      # between booking and discharge. Both are runtime dependencies — they are
      # the application, not a tool pointed at it.
      {:ash_decisions, github: "lukegalea/ash_decisions"},
      {:ash_bpmn, github: "lukegalea/ash_bpmn"},

      # Operator-defined compliance: rule bundles (via ash_rules) compiled
      # into immutable policy bundles that guard the appointment state
      # machine's transitions, plus the web surface (RulesetEditorLive) that
      # lets an operator author them.
      {:ash_compliance, github: "lukegalea/ash_compliance"},

      # The process engine's jobs. `oban_testing: :inline` means this demo never
      # starts a queue, but the shim still expects the modules to be loadable.
      {:oban, "~> 2.0"},

      # The tool under demonstration. Dev-only and `runtime: false`: it is a
      # read-only introspection layer for agents, never part of the running
      # application.
      {:ash_agent_tools, github: "lukegalea/ash_agent_tools", only: :dev, runtime: false},

      # The UI layer under demonstration: `a2ui` DSL blocks on the domain's
      # resources emit A2UI message streams, rendered in the browser by the
      # @a2ui/lit components through the LiveRenderer and the shipped JS
      # hook. Runtime dependency — it powers the app's interface.
      {:ash_a2ui, github: "lukegalea/ash_a2ui"},

      # The operator section's helper agent: ash_ai's prompt actions carry
      # the interpreter, ReqLLM speaks to the model. The console degrades
      # honestly (surface buttons only) when no provider key is set.
      {:ash_ai, "~> 1.0"},
      {:req_llm, "~> 1.7"},

      # The operator section's introspection UI. Mounted unconditionally (an
      # operator tool, not a dev extra) so every env compiles the same
      # router; the CSP it needs stays scoped to its own pipeline.
      {:clarity, "~> 0.6"},
      # Clarity's diagram engine (ER/policy views) — optional to Clarity and
      # genuinely dev-only.
      {:ash_diagram, "~> 0.2", only: :dev},

      # Tidewave: an MCP server inside the running Phoenix dev server, so an
      # agent can project_eval with the app's own reflection APIs, read the
      # logs, and query the dev database. `runtime: false` rather than
      # `only: :dev` — a dev-only restriction on this package diverges from
      # the same package pulled unrestricted elsewhere — and the plug only
      # ever mounts inside `if code_reloading?`, i.e. dev.
      {:tidewave, "~> 0.9", runtime: false},

      # Ash's policy authorizer needs a SAT solver to compile policies.
      {:picosat_elixir, "~> 0.2"},

      # `Spark.Formatter` (wired up in .formatter.exs) needs sourceror to
      # keep Ash DSL sections in a stable order.
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:usage_rules, "~> 1.1", only: [:dev], runtime: false},

      # Dev/test hygiene for CI: linting, type checking, docs and dependency
      # advisories.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, ">= 0.0.0", only: [:dev, :test], runtime: false}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ash.setup", "seed", "assets.setup", "assets.build"],
      seed: ["run priv/repo/seeds.exs"],
      reset: ["ash.reset", "seed"],
      test: ["ash.setup --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind clinic_demo", "esbuild clinic_demo"],
      "assets.deploy": [
        "tailwind clinic_demo --minify",
        "esbuild clinic_demo --minify",
        "phx.digest"
      ],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end

  # API documentation, built by CI's `mix docs` job.
  defp docs do
    [main: "readme", extras: ["README.md"]]
  end

  # Clarity's code-reload listener exists only in dev (the dep is only: :dev);
  # the list is compiled per env, so ask the code server what is loaded.
  defp clarity_listener do
    if Code.ensure_loaded?(Clarity.CodeReloader), do: [Clarity.CodeReloader], else: []
  end
end
