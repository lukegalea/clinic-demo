defmodule ClinicDemoWeb.Bpmn.ViewerLive do
  @moduledoc """
  One visit instance pinned to its definition graph, with the live token
  overlay — where the visit stands, on the map it stands on.
  """

  use AshBpmn.Web.ViewerLive, domain: ClinicDemo.Visits
end
