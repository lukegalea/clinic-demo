defmodule ClinicDemo.Release do
  @moduledoc """
  Executed from inside the release — the `mix`-less equivalent of the repo's
  dev commands:

    * `migrate/0` is what fly.toml's release_command runs on every deploy
      (`/app/bin/migrate`): the same `Ecto.Migrator.run` pass that
      `mix ash.setup` performs locally, applied before the new release
      takes traffic.

    * `seed/0` is the release-side twin of `mix run priv/repo/seeds.exs`
      (the `mix seed` alias): it starts the full application — the seeds
      book visits, and booking starts BPMN process instances that
      broadcast on PubSub, so a lone Repo is not enough — and then
      evaluates `priv/repo/seeds.exs` exactly as `mix run` would. The
      file ships inside the release (it lives under `priv/`), so no
      source tree is needed on the machine.

  Run from the host (or via `fly ssh console -C`):

      /app/bin/clinic_demo eval ClinicDemo.Release.migrate()
      /app/bin/clinic_demo eval ClinicDemo.Release.seed()
  """

  @app :clinic_demo

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, migrations_path(), :up, all: true))
    end
  end

  def seed do
    load_app()
    # Full application, not just the Repo: the seeds walk real actions —
    # booking starts process instances whose token transitions broadcast
    # on PubSub, and the audit log rides AshEvents. Everything must be up.
    {:ok, _} = Application.ensure_all_started(@app)
    Code.eval_file(seed_path())
  end

  defp repos, do: Application.fetch_env!(@app, :ecto_repos)

  defp migrations_path, do: Application.app_dir(@app, "priv/repo/migrations")

  defp seed_path, do: Application.app_dir(@app, "priv/repo/seeds.exs")

  # Idempotent: `bin/... eval` runs with the app loaded-but-not-started, but
  # `fly ssh console -C ... eval` may RPC into a live node where it is both.
  defp load_app do
    case Application.load(@app) do
      :ok -> :ok
      {:error, {:already_loaded, loaded}} when loaded == @app -> :ok
    end
  end
end
