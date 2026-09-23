defmodule ClinicDemoWeb.A2ui.Surfaces do
  @moduledoc """
  The catalogue of declared A2UI surfaces, and the one place that knows how to
  host one.

  Three callers need this and each needed something slightly different, which is
  why it exists rather than each of them keeping its own list:

    * `ClinicDemoWeb.A2ui.*Live` mounts one surface per route.
    * `ClinicDemoWeb.AgentLive` picks one at runtime, because a person asked
      for it in a sentence.
    * The helper agent needs to be *told* what exists, in words, so a model can
      choose between them.

  ## Topics are derived, never spelled

  `AshA2ui.LiveRenderer` cannot introspect a resource's publications, so the
  topics a surface subscribes to have to come from somewhere. Writing them out
  next to the `pub_sub` block would be two independent spellings of the same
  strings, and a typo in either produces a page that silently never updates,
  with nothing logged anywhere.

  So `topics/1` reads them straight off the resource's publications. There is one
  declaration — the `pub_sub` block — and the subscription is computed from it.
  A surface whose resource publishes nothing gets `[]` and is simply not live,
  which is the correct answer rather than a special case. None of this demo's
  resources publish today, so every surface is currently static; a resource
  that grows a `pub_sub` block becomes live here without another edit.
  """

  alias ClinicDemoWeb.A2ui

  @surfaces [
    %{
      name: "schedule",
      label: "Schedule",
      ui: A2ui.AppointmentUI,
      path: "/schedule",
      blurb:
        "Every appointment in one grid, with the visit lifecycle's row actions. Booking lives on the intake screen.",
      description:
        "The schedule: every appointment, with its time, reason, severity, triage " <>
          "urgency and status, plus the check-in-to-discharge transitions " <>
          "as row actions. New bookings are made on the intake screen."
    },
    %{
      name: "worklist",
      label: "Worklist",
      ui: A2ui.WorklistUI,
      path: "/worklist",
      blurb: "Human tasks waiting on a person, completed through the engine.",
      description:
        "The worklist: human tasks from running visit processes that are waiting on a " <>
          "person, with their step, status and due time, completed through the process " <>
          "engine so the token advances."
    },
    %{
      name: "visits",
      label: "Visits",
      ui: A2ui.VisitInstanceUI,
      path: "/visits",
      blurb: "Where each running visit process stands, and how it ended. Read-only.",
      description:
        "Running visit process instances over appointments: where each stands (its live " <>
          "token's node), about what (subject and reason), and how it ended. Read-only — " <>
          "instances advance through the worklist, never by hand."
    },
    %{
      name: "patients",
      label: "Patients",
      ui: A2ui.PatientUI,
      path: "/patients",
      blurb: "Registered animals, with the register form.",
      description:
        "Registered patients — the clinic's animals — with their details and weight " <>
          "recordings, and the register form whose validations live on the action."
    },
    %{
      name: "clinicians",
      label: "Clinicians",
      ui: A2ui.ClinicianUI,
      path: "/clinicians",
      blurb: "Bookable staff, and who can see them.",
      description:
        "The clinicians — bookable staff — with their role and license, and the form " <>
          "whose license-number rule lives on the create action."
    },
    %{
      name: "processes",
      label: "Visit processes",
      ui: A2ui.ProcessDefinitionUI,
      path: "/processes",
      blurb: "The published visit processes, and which version is live. Read-only.",
      description:
        "The published visit process definitions (BPMN): which version of which process " <>
          "is live. Read-only — definitions change through ClinicDemo.Rules, never by " <>
          "hand from a grid."
    },
    %{
      name: "decisions",
      label: "Decision tables",
      ui: A2ui.DecisionDefinitionUI,
      path: "/decisions",
      blurb: "The published decision tables — how urgency is decided. Read-only.",
      description:
        "The published decision table definitions (DMN) — how urgency is decided — and " <>
          "which version is live. Read-only; rules change through ClinicDemo.Rules."
    },
    %{
      name: "evaluations",
      label: "Decision evidence",
      ui: A2ui.EvaluationUI,
      path: "/evaluations",
      blurb: "Every rule evaluation the clinic has run, and which rules matched.",
      description:
        "Decision evaluations — the evidence the DMN side writes for free: every rule " <>
          "evaluation the clinic has run, which version of which table answered, and " <>
          "which rules matched."
    },
    %{
      name: "events",
      label: "Audit events",
      ui: A2ui.EventUI,
      path: "/events",
      blurb: "The ash_events audit log, newest first. Read-only.",
      description:
        "The audit event log: recorded write events, newest first. Read-only — the log " <>
          "is appended to by ash_events inside each story action's transaction, never " <>
          "by hand from a grid."
    },
    %{
      name: "emergencies",
      label: "Emergency board",
      ui: A2ui.EmergencyBoardUI,
      path: "/emergencies",
      blurb: "Appointments the triage table has routed as emergencies.",
      description:
        "The emergency board: appointments the triage decision table has routed as " <>
          "emergencies, promoted from an agent-composed surface spec."
    }
  ]

  @doc "Every declared surface, in menu order."
  @spec all() :: [map()]
  def all, do: @surfaces

  @doc "The surface with this name, or `nil`."
  @spec fetch(String.t() | nil) :: map() | nil
  def fetch(nil), do: nil

  def fetch(name) when is_binary(name) do
    normalized = name |> String.trim() |> String.downcase() |> String.replace(~r/[\s-]+/, "_")

    Enum.find(@surfaces, &(&1.name == normalized))
  end

  @doc "The surface names a model may choose between."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@surfaces, & &1.name)

  @doc """
  The catalogue as prose, for a prompt.

  Uses `:description`, not `:blurb`. They are different audiences and the
  difference showed the first time a surface was rendered: the description tells
  a *model* when to pick this surface, and putting that on screen reads as the
  application talking to itself in front of the user.

  Built from the same list the application renders from, so a surface added
  above becomes available to the helper agent without anybody remembering to
  describe it a second time.
  """
  @spec catalogue() :: String.t()
  def catalogue do
    Enum.map_join(@surfaces, "\n", fn surface ->
      "  - #{surface.name}: #{surface.description}"
    end)
  end

  @doc """
  The Phoenix.PubSub topics a surface should subscribe to, read off its
  resource's `Ash.Notifier.PubSub` publications.

  Returns `[]` for a resource with no publications — that surface is not live,
  and saying so by returning nothing is better than pretending otherwise.
  """
  @spec topics(map() | module()) :: [String.t()]
  def topics(%{ui: ui}), do: topics(ui)

  def topics(ui_module) do
    resource = AshA2ui.Info.resource!(ui_module)

    if function_exported?(resource, :spark_dsl_config, 0) and
         Ash.Notifier.PubSub in Ash.Resource.Info.notifiers(resource) do
      prefix = Ash.Notifier.PubSub.Info.prefix(resource)

      resource
      |> Ash.Notifier.PubSub.Info.publications()
      |> Enum.flat_map(fn publication ->
        publication.topic
        |> List.wrap()
        |> Enum.map(&topic_string(prefix, &1))
      end)
      |> Enum.uniq()
    else
      []
    end
  end

  # A topic template is a list of segments; the ones here are plain strings, but
  # a template carrying an interpolated field (`[:id, "updated"]`) cannot be
  # subscribed to without knowing the value, so it is skipped rather than
  # subscribed to under a wrong name.
  defp topic_string(prefix, segment) when is_binary(segment) do
    if prefix, do: "#{prefix}:#{segment}", else: segment
  end

  defp topic_string(_prefix, _segment), do: nil

  @doc """
  Whether a surface refreshes itself when its underlying rows change.

  Used to decide whether to promise live updates in the UI. Promising them for a
  surface that cannot deliver is worse than not mentioning them.
  """
  @spec live?(map() | module()) :: boolean()
  def live?(surface), do: topics(surface) != []

  @doc """
  The `AshA2ui.LiveRenderer` config for hosting `surface` at runtime.

  `ClinicDemoWeb.AgentLive` does not know at compile time which surface it
  will show, so it cannot `use AshA2ui.LiveRenderer` — it builds a config when
  somebody asks for one and drives the renderer's public functions with it.
  """
  @spec renderer_config(map(), keyword()) :: map()
  def renderer_config(surface, opts) do
    AshA2ui.LiveRenderer.build_config(
      ui: surface.ui,
      actor_fn: fn _socket -> opts[:actor] end,
      pubsub: pubsub_opts(surface)
    )
  end

  defp pubsub_opts(surface) do
    case topics(surface) do
      [] -> nil
      topics -> [module: ClinicDemo.PubSub, topics: topics]
    end
  end

  @doc """
  The allowlist the surface editor composes under.

  Names mirror the resources' short module names — that is what
  `AshA2ui.Dynamic.Importer` writes into an imported spec — except where two
  resources would collide on theirs: both `Definition`s are named by their
  side (`visit_definition`-style, CamelCase to keep the imports aligned). An
  import of a colliding surface resolves once the operator picks the
  disambiguated name in the editor's resource select; the underlying
  resource, and so every field and action reference, is unchanged.

  This is a map rather than `dynamic_allowlist/0`'s list because the editor's
  imports speak short names, and a map is ash_a2ui's composer contract for
  host naming. The gate is the same: a model (or operator) cannot compose its
  way to a table this application never meant to publish.
  """
  @spec composer_allowlist() :: %{String.t() => module()}
  def composer_allowlist do
    AshA2ui.Dynamic.allowlist(%{
      "Patient" => ClinicDemo.Scheduling.Patient,
      "Clinician" => ClinicDemo.Scheduling.Clinician,
      "Appointment" => ClinicDemo.Scheduling.Appointment,
      "HumanTask" => ClinicDemo.Visits.HumanTask,
      "Instance" => ClinicDemo.Visits.Instance,
      "VisitDefinition" => ClinicDemo.Visits.Definition,
      "DecisionDefinition" => ClinicDemo.Decisions.Definition,
      "Evaluation" => ClinicDemo.Decisions.Evaluation,
      "Event" => ClinicDemo.Events.Event
    })
  end

  @doc """
  The resources the helper agent may compose an ad-hoc surface over.

  An allowlist, and host configuration rather than client input: it gates both
  the surface's resource and every context resource, so a model cannot compose
  its way to a table this application never meant to publish. Kept to what the
  acting clinician may reasonably see end to end.

  The names are spelled out rather than derived from module short names,
  because two of these resources would collide on theirs — `Definition` is
  both a decision table and a visit process, and "Definition" twice is a
  distinction a model cannot act on.
  """
  @spec dynamic_allowlist() :: %{String.t() => module()}
  def dynamic_allowlist do
    AshA2ui.Dynamic.allowlist(%{
      "patient" => ClinicDemo.Scheduling.Patient,
      "clinician" => ClinicDemo.Scheduling.Clinician,
      "appointment" => ClinicDemo.Scheduling.Appointment,
      "decision_definition" => ClinicDemo.Decisions.Definition,
      "decision_evaluation" => ClinicDemo.Decisions.Evaluation,
      "visit_definition" => ClinicDemo.Visits.Definition,
      "visit_instance" => ClinicDemo.Visits.Instance,
      "human_task" => ClinicDemo.Visits.HumanTask,
      "task_candidate" => ClinicDemo.Visits.TaskCandidate
    })
  end
end
