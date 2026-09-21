defmodule ClinicDemo.Rules do
  @moduledoc """
  Publishes the clinic's rule documents from `priv/`.

  Two documents, and the order between them is not arbitrary:

    1. `priv/decisions/appointment_triage.dmn` becomes the published
       `appointment.triage` decision.
    2. `priv/processes/appointment_visit.bpmn` becomes the published
       `appointment_visit` process.

  The process will not compile until the decision exists. Its `businessRuleTask`
  carries a reference, and `ash_bpmn` asks
  `ClinicDemo.Decisions.Resolver.exists?/1` at publish time rather than at three
  in the morning on the first instance that reaches the node. Try it the other
  way round and the draft comes back carrying:

      businessRuleTask 'Triage' references decision 'appointment.triage',
      which does not exist

  Both halves are idempotent: a document whose content hash already matches a
  published version is left alone, and a draft left behind by an interrupted run
  is picked up rather than duplicated. `mix seed` and the test suite both call
  `install!/0`, and running either twice publishes nothing the second time.
  """

  require Ash.Query

  alias ClinicDemo.Decisions
  alias ClinicDemo.Visits

  @decision_key "appointment.triage"
  @decision_name "Appointment triage"
  @decision_path "priv/decisions/appointment_triage.dmn"

  @process_key "appointment_visit"
  @process_name "Appointment visit"
  @process_path "priv/processes/appointment_visit.bpmn"

  @doc """
  Publishes both documents, in order, and returns the published rows.

  `:actor` is whoever is deploying the rules. Publishing is a write, and the
  `Definition` resources ask for an actor like every other write in this
  application does.
  """
  @spec install!(keyword()) :: %{decision: struct(), process: struct()}
  def install!(opts \\ []) do
    actor = Keyword.get(opts, :actor, deployer())

    decision =
      install_document(
        Decisions.Definition,
        @decision_key,
        @decision_name,
        read!(@decision_path),
        actor,
        &Decisions.create_decision!/2,
        &Decisions.publish_decision!/2
      )

    process =
      install_document(
        Visits.Definition,
        @process_key,
        @process_name,
        read!(@process_path),
        actor,
        &Visits.create_process!/2,
        &Visits.publish_process!/2
      )

    %{decision: decision, process: process}
  end

  @doc "Where the DMN document lives, for anything that wants to read it directly."
  @spec decision_path() :: String.t()
  def decision_path, do: @decision_path

  @doc "Where the BPMN document lives."
  @spec process_path() :: String.t()
  def process_path, do: @process_path

  @doc "The key the visit process is published under."
  @spec process_key() :: String.t()
  def process_key, do: @process_key

  @doc "The key the triage decision is published under."
  @spec decision_key() :: String.t()
  def decision_key, do: @decision_key

  defp install_document(resource, key, name, xml, actor, create, publish) do
    hash = content_hash(xml)

    case existing(resource, key, hash, actor) do
      {:published, definition} -> definition
      {:draft, draft} -> publish.(draft, actor: actor)
      :none -> publish.(compile!(key, name, xml, actor, create), actor: actor)
    end
  end

  defp compile!(key, name, xml, actor, create) do
    draft = create.(%{key: key, name: name, xml: xml}, actor: actor)

    if draft.errors != [] do
      raise """
      #{key} did not compile:

      #{Enum.map_join(draft.errors, "\n", &"  - #{inspect(&1)}")}
      """
    end

    draft
  end

  # A filtered read rather than a code interface: "the row for this key whose
  # content hash matches, in whichever lifecycle state" is a deployment
  # question, not a thing the domain should grow an action for.
  defp existing(resource, key, hash, actor) do
    rows =
      resource
      |> Ash.Query.for_read(:read, %{}, actor: actor)
      |> Ash.Query.filter(key == ^key and content_hash == ^hash)
      |> Ash.Query.sort(version: :desc)
      |> Ash.read!()

    cond do
      published = Enum.find(rows, &(&1.status == :published)) -> {:published, published}
      draft = Enum.find(rows, &(&1.status == :draft and &1.errors == [])) -> {:draft, draft}
      true -> :none
    end
  end

  # Both packages hash the document the same way, and both store it on the row.
  # Comparing it is what makes a second `install!/0` a no-op rather than a new
  # version of a document nobody edited.
  defp content_hash(xml), do: Base.encode16(:crypto.hash(:sha256, xml), case: :lower)

  defp read!(path), do: :clinic_demo |> Application.app_dir(path) |> File.read!()

  # A named non-human actor. Publishing a rule is not nobody's doing, and an
  # audit trail that says so is the point of keeping one.
  defp deployer, do: %{id: "00000000-0000-0000-0000-000000000001", name: "rule deployer"}
end
