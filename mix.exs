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
      listeners: [Phoenix.CodeReloader]
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
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

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
      {:daisyui,
       github: "saadeghi/daisyui",
       tag: "v5.5.20",
       sparse: "packages/bundle",
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

      # Decisions and process, the two halves of the rules layer. A DMN table
      # says how urgent an appointment is; a BPMN graph says what happens to it
      # between booking and discharge. Both are runtime dependencies — they are
      # the application, not a tool pointed at it.
      {:ash_decisions, github: "lukegalea/ash_decisions"},
      {:ash_bpmn, github: "lukegalea/ash_bpmn"},

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

      # Ash's policy authorizer needs a SAT solver to compile policies.
      {:picosat_elixir, "~> 0.2"},

      # `Spark.Formatter` (wired up in .formatter.exs) needs sourceror to
      # keep Ash DSL sections in a stable order.
      {:sourceror, "~> 1.7", only: [:dev, :test]},
      {:usage_rules, "~> 0.1", only: [:dev], runtime: false},

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
end
