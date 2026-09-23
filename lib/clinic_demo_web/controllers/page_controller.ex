defmodule ClinicDemoWeb.PageController do
  use ClinicDemoWeb, :controller

  alias ClinicDemo.Scheduling.VisitMachine
  alias ClinicDemo.Visits.Instance

  def home(conn, _params) do
    render(conn, :home)
  end

  def operator(conn, _params) do
    render(conn, :operator,
      recent_instances: recent_instances(),
      visit_machine_chart: VisitMachine.chart(),
      active_bundle: active_guard_bundle()
    )
  end

  # The compliance bundle currently in force, for the hub's Audit section.
  # Nil when nothing is active (a fresh database before the seeds run).
  defp active_guard_bundle do
    case AshCompliance.Domain.active_policy_bundle(
           ClinicDemo.Compliance.organization_id(),
           authorize?: false
         ) do
      {:ok, %AshCompliance.Resources.PolicyBundle{} = bundle} -> bundle
      _ -> nil
    end
  end

  # The latest visit instances for the hub's "Recent visit processes" list.
  # The Visits surface cannot link a row out to the instance viewer (the
  # a2ui surface DSL has no external row links), so the hub carries the
  # cross-link instead. Guarded so a fresh database without the engine's
  # tables still renders the page.
  defp recent_instances do
    Instance
    |> Ash.Query.for_read(:read)
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(5)
    |> Ash.Query.load([:subject_label, :current_node])
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end
end
