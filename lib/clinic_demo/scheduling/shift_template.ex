defmodule ClinicDemo.Scheduling.ShiftTemplate do
  @moduledoc """
  A reusable shift pattern: a role, a start and end as minute offsets from UTC
  midnight, and the weekdays it may run on.

  The roster model chooses from templates rather than inventing shift times, so
  "what a shift can look like" is data a manager edits. The staffing policy
  decision (`staffing.policy`) says which templates (by `name`) may start on
  which weekday; `allowed_days` is the template's own bound (1 = Monday ... 7 =
  Sunday), and a pattern must satisfy both.

  Offsets are half-open, `[start_offset_minutes, end_offset_minutes)`, and a
  template stays inside one day.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "scheduling_shift_templates"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      description "The pattern's name as the staffing policy refers to it, e.g. \"early\"."
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 40, trim?: true
    end

    attribute :role, :atom do
      description "Who works this pattern."
      allow_nil? false
      public? true
      constraints one_of: [:veterinarian, :technician, :nurse]
    end

    attribute :start_offset_minutes, :integer do
      description "Minutes after UTC midnight the shift starts (inclusive)."
      allow_nil? false
      public? true
      constraints min: 0, max: 1439
    end

    attribute :end_offset_minutes, :integer do
      description "Minutes after UTC midnight the shift ends (exclusive)."
      allow_nil? false
      public? true
      constraints min: 1, max: 1440
    end

    attribute :allowed_days, {:array, :integer} do
      description "ISO weekdays (1 = Monday ... 7 = Sunday) the pattern may run on."
      allow_nil? false
      public? true
      default [1, 2, 3, 4, 5]
      constraints items: [min: 1, max: 7]
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    timestamps()
  end

  identities do
    identity :unique_name_role, [:name, :role]
  end

  actions do
    default_accept []
    defaults [:read]

    create :define do
      description "Add a shift pattern."
      accept [:name, :role, :start_offset_minutes, :end_offset_minutes, :allowed_days]
      validate ClinicDemo.Scheduling.Validations.OffsetsOrdered
    end

    update :retire do
      description "Stop offering the pattern to the roster. Shifts already placed keep it."
      accept []
      change set_attribute(:active, false)
    end
  end

  policies do
    policy action_type(:read) do
      description "Templates are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type([:create, :update, :destroy]) do
      description "Only a signed-in member of staff may change the pattern catalogue."
      authorize_if actor_present()
    end
  end
end
