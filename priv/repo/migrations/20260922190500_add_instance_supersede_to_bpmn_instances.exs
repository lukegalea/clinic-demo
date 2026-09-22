defmodule ClinicDemo.Repo.Migrations.AddInstanceSupersedeToBpmnInstances do
  @moduledoc """
  The supersede columns from ash_bpmn's newer main: an instance superseded
  by a re-run carries who replaced it and when. Mirrors the package's
  reference migration; this deployment has no tenant tables.
  """

  use Ecto.Migration

  def up do
    alter table(:bpmn_instances) do
      add :superseded_by_instance_id, :uuid
      add :superseded_at, :utc_datetime
    end

    create index(:bpmn_instances, [:superseded_by_instance_id],
             where: "superseded_by_instance_id IS NOT NULL",
             name: "bpmn_instances_superseded_by_index"
           )
  end

  def down do
    drop index(:bpmn_instances, [:superseded_by_instance_id],
             where: "superseded_by_instance_id IS NOT NULL",
             name: "bpmn_instances_superseded_by_index"
           )

    alter table(:bpmn_instances) do
      remove :superseded_at
      remove :superseded_by_instance_id
    end
  end
end
