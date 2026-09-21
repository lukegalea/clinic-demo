defmodule ClinicDemo.Repo do
  @moduledoc """
  The demo's Postgres repo.

  `AshPostgres.Repo` wraps `Ecto.Repo`, so everything you know about Ecto
  repos still applies; the extra callbacks below tell Ash which Postgres
  features it may generate against.
  """

  use AshPostgres.Repo, otp_app: :clinic_demo

  @doc "Extensions Ash may assume are installed. `ash-functions` is Ash's own."
  @impl true
  def installed_extensions, do: ["ash-functions", "citext"]

  @doc "The oldest Postgres this schema is generated for."
  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}
end
