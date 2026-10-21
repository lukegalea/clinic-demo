defmodule ClinicDemoWeb.Clm.Components do
  @moduledoc """
  The CLM workspace chrome, from the "CLM Shell Wireframe" design: a workspace
  bar under the app header with the workspace name, its tabs and a way back.

  The wireframe's "Archived" tab is left out: the POC models no archiving.
  Strings are English only (no real French pairs on the Bilingual page).
  """

  use Phoenix.Component

  use Phoenix.VerifiedRoutes,
    endpoint: ClinicDemoWeb.Endpoint,
    router: ClinicDemoWeb.Router,
    statics: ClinicDemoWeb.static_paths()

  attr :active, :atom, default: nil, values: [nil, :all]

  def workspace_bar(assigns) do
    ~H"""
    <div
      id="clm-workspace-bar"
      class="-mx-4 md:-mx-6 -mt-6 mb-6 px-4 md:px-6 border-b border-(--atlas-border-default) bg-(--atlas-bg-surface-sunken) flex flex-wrap items-center gap-x-6 gap-y-2 min-h-14 font-sans"
    >
      <span class="flex items-center gap-2 font-semibold text-(--atlas-text-primary)">
        <span aria-hidden="true" class="size-4 rounded-sm border-2 border-current"></span> Contracts
      </span>
      <nav aria-label="Contracts" class="flex items-stretch self-stretch gap-4 text-sm">
        <.link
          navigate={~p"/contracts"}
          aria-current={@active == :all && "page"}
          class="inline-flex items-center border-b-2 border-transparent text-(--atlas-text-secondary) hover:text-(--atlas-text-primary) aria-[current=page]:border-(--atlas-border-brand) aria-[current=page]:text-(--atlas-text-brand)"
        >
          All contracts
        </.link>
      </nav>
      <.link
        navigate={~p"/"}
        class="ms-auto inline-flex items-center gap-1 h-8 px-3 text-sm rounded-(--atlas-radius-lg) border border-(--atlas-border-strong) bg-(--atlas-bg-surface) text-(--atlas-text-primary) hover:bg-(--atlas-bg-surface-sunken) focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-(--atlas-border-focus)"
      >
        <span aria-hidden="true">‹</span> Back to the clinic
      </.link>
    </div>
    """
  end
end
