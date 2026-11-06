defmodule ClinicDemo.Planning.Install do
  @moduledoc """
  Publishes a planning model and binds it, idempotently. The model is any
  `ClinicDemo.Planning.Model` (default: the weekly roster).

      %{model_version: mv, binding: binding} = ClinicDemo.Planning.Install.install!()
      ClinicDemo.Planning.Install.install!(ClinicDemo.Planning.Models.MobileVisits)

  Two steps, in order, like `ClinicDemo.Rules.install!/0` (which must have run
  first, so a model's parameter decision, if it has one, exists to be pinned):

    1. **ModelVersion** — the model, checker and validator hashes from the model's
       declaration. A published version whose hashes match is reused; otherwise the
       next version is drafted and published. A published version is never edited.
    2. **Binding** — `(model key, purpose)` is bound to the selection that pins the
       decision's published version and hash (when the model has a decision) and the
       model, checker and validator hashes. The binding is temporal: when the
       pinned definitions change (a new decision version, a new model version) the
       binding is *re*-bound, and a run keeps resolving the binding valid as of
       its own knowledge cutoff.

  `mix run priv/planning/seed_weekly_roster.exs` and
  `priv/planning/seed_mobile_visits.exs` call this (synthetic data only).
  """

  require Ash.Query

  alias AshPlanning.Fragment.Binding.Changes.BuildSelector
  alias ClinicDemo.Decisions
  alias ClinicDemo.Planning
  alias ClinicDemo.Planning.{Binding, Machinery, ModelVersion, Reader}
  alias ClinicDemo.Planning.Models.WeeklyRoster

  @doc "Publishes the model version and (re)binds it. Returns both rows."
  @spec install!(module()) :: %{model_version: struct(), binding: struct()}
  def install!(model \\ WeeklyRoster) do
    definition = model.definition()
    model_version = model_version!(definition)
    %{model_version: model_version, binding: binding!(definition, model_version)}
  end

  @doc """
  The binding valid now and the model version it pins, **without installing or
  rebinding anything**. A plan is made with what a person bound; planning never
  quietly rebinds. Raises when nothing is installed, naming the seed script.
  """
  @spec current!(module()) :: %{model_version: struct(), binding: struct()}
  def current!(model \\ WeeklyRoster) do
    definition = model.definition()
    selector = BuildSelector.selector(definition.key, definition.purpose)

    binding =
      Binding
      |> Ash.Query.filter(selector == ^selector)
      |> Ash.read_one!(actor: Machinery.actor()) ||
        raise "the #{definition.key} model is not bound: run its seed script under priv/planning"

    %{"version" => version} =
      Enum.find(binding.selection, &(&1["kind"] == "mzn" and &1["key"] == definition.key))

    version = String.to_integer(version)

    model_version =
      ModelVersion
      |> Ash.Query.filter(key == ^definition.key and version == ^version)
      |> Ash.read_one!(actor: Machinery.actor())

    %{model_version: model_version, binding: binding}
  end

  defp model_version!(definition) do
    existing =
      ModelVersion
      |> Ash.Query.filter(key == ^definition.key)
      |> Ash.Query.sort(version: :desc)
      |> Ash.read!(actor: Machinery.actor())

    case Enum.find(existing, &(&1.status == :published and same_artifacts?(&1, definition))) do
      %ModelVersion{} = published ->
        published

      nil ->
        next = (existing |> Enum.map(& &1.version) |> Enum.max(fn -> 0 end)) + 1

        draft =
          Planning.draft_model_version!(
            %{
              key: definition.key,
              version: next,
              model_sha256: definition.model_sha256,
              checker_sha256: definition.checker_sha256,
              validator_module: inspect(definition.validator),
              validator_sha256: definition.validator_sha256,
              backend_profile: definition.backend_profile,
              capabilities: definition.capabilities
            },
            actor: Machinery.actor()
          )

        Planning.publish_model_version!(draft, %{}, actor: Machinery.actor())
    end
  end

  defp same_artifacts?(mv, definition) do
    mv.model_sha256 == definition.model_sha256 and mv.checker_sha256 == definition.checker_sha256 and
      mv.validator_sha256 == definition.validator_sha256
  end

  defp binding!(definition, model_version) do
    selection = selection(definition, model_version)
    profile_hash = Reader.hash(definition.backend_profile)
    selector = BuildSelector.selector(definition.key, definition.purpose)

    existing =
      Binding
      |> Ash.Query.filter(selector == ^selector)
      |> Ash.read_one!(actor: Machinery.actor())

    case existing do
      nil ->
        Planning.bind_model!(
          %{
            model_key: definition.key,
            purpose: definition.purpose,
            selection: selection,
            backend_profile_hash: profile_hash
          },
          actor: Machinery.actor()
        )

      %Binding{} = bound ->
        if same_selection?(bound, selection, profile_hash) do
          bound
        else
          Planning.rebind_model!(
            bound,
            %{selection: selection, backend_profile_hash: profile_hash},
            actor: Machinery.actor()
          )
        end
    end
  end

  # What the binding pins: the decision (published version + hash) and the three
  # reviewed artifacts. `(kind, key, version, content_hash)`, all strings.
  defp selection(definition, model_version) do
    decision_entries(definition.decision_key) ++
      [
        %{
          "kind" => "mzn",
          "key" => model_version.key,
          "version" => Integer.to_string(model_version.version),
          "content_hash" => model_version.model_sha256
        },
        %{
          "kind" => "mzn",
          "key" => model_version.key <> ".checker",
          "version" => Integer.to_string(model_version.version),
          "content_hash" => model_version.checker_sha256
        },
        %{
          "kind" => "validator",
          "key" => model_version.validator_module,
          "version" => Integer.to_string(model_version.version),
          "content_hash" => model_version.validator_sha256
        }
      ]
  end

  defp decision_entries(nil), do: []

  defp decision_entries(decision_key) do
    decision = hd(Decisions.latest_published_decision!(decision_key))

    [
      %{
        "kind" => "dmn",
        "key" => decision.key,
        "version" => Integer.to_string(decision.version),
        "content_hash" => decision.content_hash
      }
    ]
  end

  defp same_selection?(bound, selection, profile_hash) do
    bound.backend_profile_hash == profile_hash and
      Enum.sort_by(bound.selection, &{&1["kind"], &1["key"], &1["version"]}) ==
        Enum.sort_by(selection, &{&1["kind"], &1["key"], &1["version"]})
  end
end
