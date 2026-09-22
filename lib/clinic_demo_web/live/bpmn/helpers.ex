defmodule ClinicDemoWeb.Bpmn.Helpers do
  @moduledoc """
  The bridge between the session-backed a2ui actor and the bpmn/decisions
  LiveViews, which take actor and principal ids as `{m, f, a}` callbacks
  receiving the socket.
  """

  def current_principal_ids(%{assigns: %{a2ui_actor: %{id: id}}}), do: [id]

  def current_principal_ids(_socket), do: []

  def current_actor(%{assigns: %{a2ui_actor: actor}}), do: actor

  def current_actor(_socket), do: nil
end
