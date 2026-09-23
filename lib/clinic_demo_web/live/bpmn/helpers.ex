defmodule ClinicDemoWeb.Bpmn.Helpers do
  @moduledoc """
  The bridge between the session-backed a2ui actor and the bpmn/decisions
  LiveViews, which take actor and principal ids as `{m, f, a}` callbacks
  receiving the socket.

  It is also the host's designer catalogue: the `{m, f, a}` tuples behind
  `AshBpmn.Web.DesignerLive`'s `:actions` and `:decisions` options. Each is
  called as `module.function(args ++ [socket])` on mount and every
  `handle_params`; a failure is swallowed and the panel falls back to free
  text. A catalogue entry turns its panel field into a combobox — a text
  input over a native `<datalist>` of the entries — per
  `documentation/topics/the-designer.md` in ash_bpmn ("catalogue-backed
  fields are comboboxes"): searchable, keyboard-navigable, still writable
  with a ref that does not exist yet, because authoring runs ahead of what
  it binds.

  The clinic-demo-shaped wiring, straight from the framework docs:

      use AshBpmn.Web.DesignerLive,
        domain: ClinicDemo.Visits,
        actor: {ClinicDemoWeb.Bpmn.Helpers, :current_actor, []},
        actions: {ClinicDemoWeb.Bpmn.Helpers, :action_catalogue, []},
        decisions: {ClinicDemoWeb.Bpmn.Helpers, :decision_catalogue, []}

  ## Action catalogue

  `AshBpmn.Catalogue.AshActions.entries/1` builds the entries from
  `{ref, resource, action}` triples, so the panel renders one row per the
  action's real arguments — name, type, required badge, description. The
  allowlist is code: an entry naming an action that does not exist raises
  `ArgumentError` at catalogue build (mount), not in front of a modeller.

  The refs are the visit process's `ActionInvoker` vocabulary — the same
  strings `ClinicDemo.Visits.Invoker.exists?/1` verifies at publish time.
  `alert_emergency_team` is in the invoker but deliberately absent here: it
  is the paging seam (a `Logger` call), not an Ash action, so there is
  nothing Ash-constrained to catalogue for it.

  ## Decision catalogue

  `AshDecisions.Catalogue.entries/2` projects the decision domain — per
  key: the draft-or-published status, the latest published version, whether
  a draft is in flight, and the named decisions the document declares. The
  business-rule panel renders the ref as a combobox, badges the resolved
  entry (`draft` / `published vN`), and flags a pinned version drifting
  behind the latest published one.
  """

  def current_principal_ids(%{assigns: %{a2ui_actor: %{id: id}}}), do: [id]

  def current_principal_ids(_socket), do: []

  def current_actor(%{assigns: %{a2ui_actor: actor}}), do: actor

  def current_actor(_socket), do: nil

  @action_specs [
    {"record_triage", ClinicDemo.Scheduling.Appointment, :record_triage},
    {"check_in", ClinicDemo.Scheduling.Appointment, :check_in},
    {"mark_no_show", ClinicDemo.Scheduling.Appointment, :mark_no_show},
    {"discharge", ClinicDemo.Scheduling.Appointment, :discharge}
  ]

  @doc """
  The service/send panel's action combobox: the Ash-constrained refs a
  diagram may bind, each with the arguments the host's action declares.
  """
  @spec action_catalogue(term) :: [map()]
  def action_catalogue(_socket) do
    AshBpmn.Catalogue.AshActions.entries(@action_specs)
  end

  @doc """
  The business-rule panel's decision combobox: the DMN keys the decision
  domain knows, with their publish status and declared decisions.
  """
  @spec decision_catalogue(term) :: [map()]
  def decision_catalogue(_socket) do
    AshDecisions.Catalogue.entries(ClinicDemo.Decisions)
  end
end
