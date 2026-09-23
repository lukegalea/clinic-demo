defmodule ClinicDemoWeb.PageController do
  use ClinicDemoWeb, :controller

  alias ClinicDemo.Visits.Instance

  def home(conn, _params) do
    render(conn, :home)
  end

  def operator(conn, _params) do
    render(conn, :operator,
      recent_instances: recent_instances(),
      visit_machine_chart: ClinicDemo.Scheduling.VisitMachine.chart()
    )
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
