defmodule ClinicDemo.Repo do
  @moduledoc """
  The demo's Postgres repo.

  `AshPostgres.Repo` wraps `Ecto.Repo`, so everything you know about Ecto
  repos still applies; the extra callbacks below tell Ash which Postgres
  features it may generate against.
  """

  use AshPostgres.Repo, otp_app: :clinic_demo

  @doc """
  Extensions Ash may assume are installed. `ash-functions` is Ash's own;
  `citext` backs the case-insensitive identities; `btree_gist` is the Phase 0
  (PostgreSQL 18) temporal-readiness floor — later temporal surfaces build
  exclusion constraints over range types, and every non-GiST-native column in
  such a constraint needs this extension. The migration generator diffs this
  list against the extensions snapshot and emits the CREATE EXTENSION
  migration when such a surface lands.
  """
  @impl true
  def installed_extensions, do: ["ash-functions", "citext", "btree_gist"]

  @doc """
  The oldest Postgres this schema is generated for. Phase 0 pins the declared
  floor to the server the family develops against (PostgreSQL 18; the shared
  ash_enterprise devenv provides 18.4). This is ash_postgres' feature-gating
  declaration, not a runtime server check — generated migrations may use PG18
  features (native uuidv7()), which is why CI's service image must be pg18.
  """
  @impl true
  def min_pg_version, do: %Version{major: 18, minor: 0, patch: 0}
end
