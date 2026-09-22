defmodule ClinicDemo.Repo.Migrations.CreateSchedulingBoardLanes do
  @moduledoc """
  The clinic board's lanes — process stages, seeded, matched by
  `appointments.board_lane` (the expression calculation).
  """

  use Ecto.Migration

  def up do
    create table(:scheduling_board_lanes, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :lane_key, :text, null: false
      add :label, :text, null: false
      add :position, :integer, null: false
      add :accent, :text, null: false, default: "neutral"

      timestamps()
    end

    create unique_index(:scheduling_board_lanes, [:lane_key])
  end

  def down do
    drop table(:scheduling_board_lanes)
  end
end
