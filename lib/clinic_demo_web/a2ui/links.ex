defmodule ClinicDemoWeb.A2ui.Links do
  @moduledoc """
  Where a reference link goes.

  The schedule's patient and clinician columns are `link`ed fields: ash_a2ui
  knows the target *record* and asks this module which *surface* shows it
  (`surface_for/2`, the `AshA2ui.LinkResolver` behaviour, configured as
  `config :ash_a2ui, :link_resolver`). The keys are the surface registry's
  names, so a link names the same page the nav does.

  Opening one (`open/2`, the `:open_surface` callback of the LiveViews that
  show links) navigates to that surface with the record selected through
  its context: `/patients?ctx[patient]=<id>` picks the patient and shows
  their appointments. The id goes through the surface's authorized context
  read on arrival, like any other selection — an id the actor cannot read
  is dropped, and the page simply opens unselected.

  Links are UX, not authorization: the opened surface enforces its own
  policies.
  """

  @behaviour AshA2ui.LinkResolver

  use Phoenix.VerifiedRoutes,
    endpoint: ClinicDemoWeb.Endpoint,
    router: ClinicDemoWeb.Router,
    statics: ClinicDemoWeb.static_paths()

  alias ClinicDemo.Scheduling.{Clinician, Patient}

  @impl AshA2ui.LinkResolver
  def surface_for({:resource, Patient}, _context), do: "patients"
  def surface_for({:resource, Clinician}, _context), do: "clinicians"
  def surface_for(_target, _context), do: nil

  @doc """
  The path that opens `surface` with `record_id` selected, or `nil` for a
  surface this module does not route.
  """
  @spec target_path(String.t(), String.t() | nil) :: String.t() | nil
  def target_path("patients", id) when is_binary(id), do: ~p"/patients?#{[ctx: [patient: id]]}"

  def target_path("clinicians", id) when is_binary(id),
    do: ~p"/clinicians?#{[ctx: [clinician: id]]}"

  def target_path(_surface, _id), do: nil

  @doc """
  The `AshA2ui.LiveRenderer` `:open_surface` callback: navigates to `target_path/2`
  for the activated link, and ignores anything it does not route.
  """
  @spec open(map(), Phoenix.LiveView.Socket.t()) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def open(%{"surface" => surface} = args, socket) do
    case target_path(surface, record_id(args)) do
      nil -> {:noreply, socket}
      path -> {:noreply, Phoenix.LiveView.push_navigate(socket, to: path)}
    end
  end

  def open(_args, socket), do: {:noreply, socket}

  defp record_id(%{"recordId" => id}) when is_binary(id) and id != "", do: id
  defp record_id(_args), do: nil
end
