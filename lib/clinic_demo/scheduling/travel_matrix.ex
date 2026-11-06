defmodule ClinicDemo.Scheduling.TravelMatrix do
  @moduledoc """
  The travel matrix: how long the veterinarian drives between two
  `ClinicDemo.Scheduling.ServiceLocation`s, as a **versioned, immutable data
  artifact**.

  One row is one published version of one matrix (`key`, `version`): the directed
  pairs between locations, each with a duration in whole minutes and a distance in
  metres, or marked unreachable. It also records where the numbers came from
  (`provider`, `collected_at`) and a `content_hash`, the SHA-256 of the
  canonical-JSON form of everything above. A mobile-visit plan reads one version and
  records its hash in the snapshot (role `:travel_matrix`), so a plan names exactly
  the numbers it was made with, and any other version, or any edit, is a different
  digest.

  There is no update and no destroy: **a changed matrix is a new version**. The
  numbers come from outside (a provider, a survey); the demo ships synthetic ones
  and a hosted routing API stays out until an `ash_operations` declaration exists
  for it (no HTTP client lives here).

  ## Pairs

    * a reachable pair carries `duration_minutes` (>= 0) and optionally
      `distance_m`;
    * an **unreachable** pair (`reachable: false`) carries no duration. The planner
      treats it as a pair that can never be driven: infeasible, never zero-cost;
    * a pair from a location to itself is not stored (no travel is needed); every
      other pair a plan needs must be present, or the plan is `:needs_input` naming
      it. A missing pair is never read as zero.
  """

  use Ash.Resource,
    domain: ClinicDemo.Scheduling,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshEvents.Events]

  alias AshOpenLineage.Snapshot.CanonicalJSON

  postgres do
    table "scheduling_travel_matrices"
    repo ClinicDemo.Repo
  end

  attributes do
    uuid_primary_key :id

    attribute :key, :string do
      description "Which matrix this is a version of, e.g. \"clinic_van\"."
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60, trim?: true
    end

    attribute :version, :integer do
      description "Assigned on publication: one more than the key's latest version."
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :mode, :atom do
      description "How the legs are travelled."
      allow_nil? false
      public? true
      default :driving
      constraints one_of: [:driving]
    end

    attribute :provider, :string do
      description "Where the numbers came from; \"synthetic\" for every fixture."
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 60, trim?: true
    end

    attribute :collected_at, :utc_datetime do
      description "When the provider produced the numbers."
      allow_nil? false
      public? true
    end

    attribute :entries, {:array, :map} do
      description """
      The directed pairs, sorted by `(origin_id, destination_id)`: `origin_id`,
      `destination_id`, `reachable`, and for a reachable pair `duration_minutes`
      (and optionally `distance_m`).
      """

      allow_nil? false
      public? true
      default []
    end

    attribute :content_hash, :string do
      description "SHA-256 (lowercase hex) of the canonical-JSON content. Set on publication."
      allow_nil? false
      public? true
      constraints match: ~r/^[0-9a-f]{64}$/
    end

    attribute :published_at, :utc_datetime_usec do
      description "When this version became available to a plan."
      allow_nil? false
      public? true
    end

    create_timestamp :inserted_at
  end

  identities do
    identity :unique_version, [:key, :version]
  end

  events do
    event_log(ClinicDemo.Events.Event)
  end

  actions do
    default_accept []
    defaults [:read]

    create :publish do
      description """
      Publish a new version of a matrix. The version, the canonical entries, the
      publication instant and the content hash are set here, never supplied.
      """

      accept [:key, :mode, :provider, :collected_at, :entries]
      change ClinicDemo.Scheduling.Changes.SealTravelMatrix
    end
  end

  policies do
    policy action_type(:read) do
      description "Matrices are readable by anything that can reach the application."
      authorize_if always()
    end

    policy action_type(:create) do
      description "Only a signed-in member of staff may publish a matrix version."
      authorize_if actor_present()
    end
  end

  @doc """
  The content hash a row with these fields must carry (lowercase hex SHA-256 of
  the canonical JSON of `key`, `version`, `mode`, `provider`, `collected_at` and the
  entries sorted by pair). `Planning` recomputes it on every read, so a row edited
  behind the resource's back is refused rather than trusted.
  """
  @spec content_hash(map()) :: String.t()
  def content_hash(%{} = fields) do
    %{
      "key" => fields.key,
      "version" => fields.version,
      "mode" => Atom.to_string(fields.mode),
      "provider" => fields.provider,
      "collected_at" => fields.collected_at,
      "entries" => sort_entries(fields.entries)
    }
    |> CanonicalJSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc false
  @spec sort_entries([map()]) :: [map()]
  def sort_entries(entries),
    do: Enum.sort_by(entries, &{&1["origin_id"], &1["destination_id"]})
end
