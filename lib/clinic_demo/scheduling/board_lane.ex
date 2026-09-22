defmodule ClinicDemo.Scheduling.BoardLane do
  @moduledoc """
  The clinic board's lanes: the process stages cards move through.

  A row per lane, seeded — the board's shape changes with the clinic's
  process, not with its data. `lane_key` matches `Appointment.board_lane`;
  `accent` names the lane's color token for the board's rendering.
  """

  use Ash.Resource, domain: ClinicDemo.Scheduling, data_layer: AshPostgres.DataLayer

  postgres do
    table "scheduling_board_lanes"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :lane_key, :string do
      allow_nil? false
      public? true
    end

    attribute :label, :string do
      allow_nil? false
      public? true
    end

    attribute :position, :integer do
      allow_nil? false
      public? true
    end

    attribute :accent, :string do
      # Seeded color-token name (neutral/blue/green/amber/red/violet); not
      # user input, so no constraint machinery.
      default "neutral"
      public? true
    end

    timestamps()
  end

  identities do
    identity :unique_lane_key, [:lane_key]
  end

  actions do
    default_accept [:lane_key, :label, :position, :accent]
    defaults [:read, :destroy, create: :*, update: :*]
  end
end
