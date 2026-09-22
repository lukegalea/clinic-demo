defmodule ClinicDemo.Repo.Migrations.AddVerificationToDmnDefinitions do
  @moduledoc """
  The publish-time verification result, stored beside the compile errors it
  complements rather than replaces. Mirrors ash_decisions' own reference
  migration; this deployment has no tenant tables.
  """

  use Ecto.Migration

  def up do
    alter table(:dmn_definitions) do
      add :verification, :map
    end
  end

  def down do
    alter table(:dmn_definitions) do
      remove :verification
    end
  end
end
