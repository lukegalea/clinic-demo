defmodule ClinicDemoWeb.AtlasLabLive do
  @moduledoc """
  Atlas POC lab: two ways to build an Atlas text field in a hand-built
  LiveView form, side by side, under the same phx-change validation.

    * A — `Atlas.Forms.field/1`: HEEx Field around a native <input>.
    * B — `<atlas-text-field>`: a form-associated Lit element
      (ElementInternals) rendering a native input in light DOM.

  `?lang=fr` switches labels to French. French strings are only the real
  pairs from the Atlas Bilingual page (Figma, lifted from packages/i18n);
  strings without a real translation stay English rather than invented.
  """

  use ClinicDemoWeb, :live_view

  @strings %{
    "en" => %{label: "PM Id(s)", submit: "Add PM", caption: "Shown to vendors on the invitation."},
    "fr" => %{
      label: "Numéro(s) d’identification du Gestionnaire immobilier",
      submit: "Ajouter un Gestionnaire immobilier",
      # No real French pair on the Bilingual page: kept English.
      caption: "Shown to vendors on the invitation."
    }
  }

  # C's options: the invented properties of the CLM POC seeds.
  @properties [
    "Bayview Gardens",
    "Elm Park Residences",
    "Harbourfront Tower",
    "King West Lofts",
    "Lakeshore Terrace",
    "Maple Court",
    "Queensway Plaza",
    "Riverside Commons"
  ]

  # D's footer buttons: native <button>s with the Atlas Button recipe's classes.
  @button Atlas.Components.recipes()["Button"]

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(submitted: nil, property_options: Enum.map(@properties, &%{value: &1, label: &1}))
     |> assign(
       awarded: false,
       vendor_saved: nil,
       vendor_form: to_form(%{"name" => ""}, as: :vendor)
     )
     |> assign_form(%{"heex" => "", "lit" => "", "properties" => []}, false)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    lang = if params["lang"] == "fr", do: "fr", else: "en"
    {:noreply, assign(socket, lang: lang, t: @strings[lang])}
  end

  @impl true
  def handle_event("validate", params, socket) do
    {:noreply, assign_form(socket, Map.get(params, "lab", %{}), true)}
  end

  def handle_event("save", %{"lab" => params}, socket) do
    socket = assign_form(socket, params, true)

    if socket.assigns.form.errors == [],
      do:
        {:noreply,
         assign(socket,
           submitted:
             params
             |> Map.take(["heex", "lit"])
             |> Map.put("properties", chosen(params["properties"]))
         )},
      else: {:noreply, socket}
  end

  # D · overlays. The modal opens and closes in the browser (JS.dispatch); its
  # primary button also tells the server. The drawer is opened BY the server
  # (push_event), holds a LiveView form, and is closed by the server on save.
  def handle_event("award", _params, socket), do: {:noreply, assign(socket, awarded: true)}

  def handle_event("open_vendor_drawer", _params, socket) do
    {:noreply, push_event(socket, "atlas:open", %{id: "vendor-drawer"})}
  end

  # Form recovery after a reconnect can send the form before its Lit fields
  # have registered a value, so the form key may be missing.
  def handle_event("vendor_validate", params, socket) do
    {:noreply, assign(socket, vendor_form: vendor_form(Map.get(params, "vendor", %{}), true))}
  end

  def handle_event("vendor_save", %{"vendor" => params}, socket) do
    form = vendor_form(params, true)

    if form.errors == [] do
      {:noreply,
       socket
       |> assign(
         vendor_saved: %{
           name: String.trim(params["name"]),
           properties: chosen(params["properties"])
         },
         vendor_form: vendor_form(%{}, false)
       )
       |> push_event("atlas:close", %{id: "vendor-drawer"})}
    else
      {:noreply, assign(socket, vendor_form: form)}
    end
  end

  defp vendor_form(params, validate?) do
    errors =
      if validate?,
        do: Enum.map(errors_for("name", params["name"]), fn {_, e} -> {:name, e} end),
        else: []

    to_form(params, as: :vendor, errors: errors, action: validate? && :validate)
  end

  defp button_class(variant) do
    {classes, _tag} = Atlas.Components.resolve(@button, %{variant: variant})
    classes
  end

  defp assign_form(socket, params, validate?) do
    errors =
      if validate?,
        do:
          Enum.flat_map(["heex", "lit"], &errors_for(&1, params[&1])) ++
            properties_errors(params["properties"]),
        else: []

    assign(socket,
      form: to_form(params, as: :lab, errors: errors, action: validate? && :validate)
    )
  end

  defp errors_for(field, value) do
    value = String.trim(value || "")

    cond do
      value == "" ->
        [{String.to_existing_atom(field), {"is required", []}}]

      String.length(value) < 3 ->
        [{String.to_existing_atom(field), {"must be at least 3 characters", []}}]

      true ->
        []
    end
  end

  # The multi-select always submits the field: one entry per choice, or one
  # empty entry when nothing is chosen.
  defp chosen(values), do: values |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

  defp properties_errors(values) do
    if chosen(values) == [], do: [properties: {"choose at least one property", []}], else: []
  end

  # A Lit field's error, shown once LiveView considers the field used (the
  # same rule as the HEEx field), so the Lit fields are held to A's contract.
  defp lit_error(form, field \\ :lit) do
    if Phoenix.Component.used_input?(form[field]) do
      form.errors
      |> Keyword.get_values(field)
      |> Enum.map_join(" ", &elem(&1, 0))
      |> blank_to_nil()
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(s), do: s

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-5xl px-4 py-8 flex flex-col gap-6 font-sans" lang={@lang}>
      <header class="flex flex-col gap-1">
        <h1 class="text-xl font-semibold text-(--atlas-text-primary)">Atlas lab: form fields</h1>
        <p class="text-sm text-(--atlas-text-secondary)">
          Same rule on both: required, at least 3 characters. Language:
          <.link patch={~p"/atlas-lab?lang=en"} class="underline">EN</.link>
          · <.link patch={~p"/atlas-lab?lang=fr"} class="underline">FR</.link>
        </p>
      </header>

      <%!-- Demo for the team: the smallest useful Lit component
           (assets/js/demo/hello_badge.js). The server sends only the tag and
           its attribute; the browser runs the rest. The counter's state lives
           in the element, so clicking never talks to the server. --%>
      <section
        id="hello-badge-demo"
        class="flex flex-col gap-2 p-4 rounded-(--atlas-radius-xl) bg-(--atlas-bg-surface) border border-(--atlas-border-default)"
      >
        <h2 class="font-semibold">A Lit component in a HEEx page</h2>
        <hello-badge id="hello-badge" name="Leandro"></hello-badge>
        <code class="text-xs text-(--atlas-text-secondary)">
          &lt;hello-badge name="Leandro"&gt;&lt;/hello-badge&gt;
        </code>
      </section>

      <.form
        for={@form}
        id="atlas-lab-form"
        phx-change="validate"
        phx-submit="save"
        class="grid grid-cols-1 md:grid-cols-2 gap-8"
      >
        <section class="flex flex-col gap-3 min-w-0 p-4 rounded-(--atlas-radius-xl) bg-(--atlas-bg-surface) border border-(--atlas-border-default)">
          <Atlas.Components.tag color="blue" size="sm" class="self-start">
            A · HEEx + native input
          </Atlas.Components.tag>
          <Atlas.Forms.field field={@form[:heex]} label={@t.label} caption={@t.caption} required />
        </section>

        <section class="flex flex-col gap-3 min-w-0 p-4 rounded-(--atlas-radius-xl) bg-(--atlas-bg-surface) border border-(--atlas-border-default)">
          <Atlas.Components.tag color="gold" size="sm" class="self-start">
            B · Lit, form-associated
          </Atlas.Components.tag>
          <atlas-text-field
            id="lab-lit"
            name={@form[:lit].name}
            data-label={@t.label}
            data-caption={@t.caption}
            data-value={@form[:lit].value}
            data-error={lit_error(@form)}
            required
          >
          </atlas-text-field>
        </section>

        <section class="md:col-span-2 flex flex-col gap-3 min-w-0 p-4 rounded-(--atlas-radius-xl) bg-(--atlas-bg-surface) border border-(--atlas-border-default)">
          <Atlas.Components.tag color="green" size="sm" class="self-start">
            C · Lit multi-select, form-associated
          </Atlas.Components.tag>
          <%!-- Shadow-DOM rendering: no phx-update="ignore" needed. Server
               state still travels as data-* attributes (rule 2). --%>
          <atlas-multi-select
            id="lab-properties"
            name={@form[:properties].name <> "[]"}
            data-label="Properties"
            data-caption="Where the contract applies."
            data-options={JSON.encode!(@property_options)}
            data-value={JSON.encode!(chosen(@form[:properties].value))}
            data-error={lit_error(@form, :properties)}
            required
          >
          </atlas-multi-select>
        </section>

        <div class="md:col-span-2 flex flex-wrap items-center gap-3">
          <button
            type="submit"
            id="atlas-lab-submit"
            class="inline-flex items-center h-9 px-4 text-sm font-medium rounded-(--atlas-radius-lg) bg-(--atlas-bg-brand) text-(--atlas-text-on-brand) hover:bg-(--atlas-bg-brand-hover) focus-visible:outline-2 focus-visible:outline-offset-1 focus-visible:outline-(--atlas-border-focus) whitespace-nowrap"
          >
            {@t.submit}
          </button>
          <p :if={@submitted} id="atlas-lab-submitted" class="text-sm text-(--atlas-text-success)">
            Submitted: heex={inspect(@submitted["heex"])}, lit={inspect(@submitted["lit"])}, properties={inspect(
              @submitted["properties"]
            )}
          </p>
        </div>
      </.form>

      <section
        id="overlays-demo"
        class="flex flex-col gap-3 p-4 rounded-(--atlas-radius-xl) bg-(--atlas-bg-surface) border border-(--atlas-border-default)"
      >
        <Atlas.Components.tag color="orange" size="sm" class="self-start">
          D · Lit overlays on the native dialog
        </Atlas.Components.tag>
        <div class="flex flex-wrap gap-3">
          <button
            type="button"
            id="open-award-modal"
            class={button_class("secondary")}
            phx-click={JS.dispatch("atlas:open", to: "#award-modal")}
          >
            Open modal (in the browser)
          </button>
          <button
            type="button"
            id="open-vendor-drawer"
            class={button_class("secondary")}
            phx-click="open_vendor_drawer"
          >
            Open drawer (from the server)
          </button>
        </div>
        <p :if={@awarded} id="awarded-note" class="text-sm text-(--atlas-text-success)">
          The server recorded the award.
        </p>
        <p :if={@vendor_saved} id="vendor-saved-note" class="text-sm text-(--atlas-text-success)">
          Saved vendor {inspect(@vendor_saved.name)} for {inspect(@vendor_saved.properties)}; the server closed the drawer.
        </p>
      </section>

      <%!-- Fixture copy from the Atlas Figma Overlays page. --%>
      <atlas-modal id="award-modal" data-title="Award this project">
        <p>
          Awarding sends the vendor a confirmation and moves this project into contracting. You can still change the scope afterwards.
        </p>
        <button
          slot="footer"
          type="button"
          class={button_class("secondary")}
          phx-click={JS.dispatch("atlas:close", to: "#award-modal")}
        >
          Cancel
        </button>
        <button
          slot="footer"
          type="button"
          id="award-confirm"
          class={button_class("primary")}
          phx-click={JS.push("award") |> JS.dispatch("atlas:close", to: "#award-modal")}
        >
          Award project
        </button>
      </atlas-modal>

      <%!-- A LiveView form inside the drawer: slotted, so it is ordinary page
           DOM. The footer's submit button reaches it with form="vendor-form". --%>
      <atlas-drawer id="vendor-drawer" data-title="Vendor details">
        <.form
          for={@vendor_form}
          id="vendor-form"
          phx-change="vendor_validate"
          phx-submit="vendor_save"
          class="flex flex-col gap-4"
        >
          <atlas-text-field
            id="vendor-name"
            name={@vendor_form[:name].name}
            data-label="Vendor name"
            data-value={@vendor_form[:name].value}
            data-error={lit_error(@vendor_form, :name)}
            required
          >
          </atlas-text-field>
          <atlas-multi-select
            id="vendor-properties"
            name={@vendor_form[:properties].name <> "[]"}
            data-label="Properties"
            data-caption="Where this vendor works."
            data-options={JSON.encode!(@property_options)}
            data-value={JSON.encode!(chosen(@vendor_form[:properties].value))}
            data-error={lit_error(@vendor_form, :properties)}
            required
          >
          </atlas-multi-select>
        </.form>
        <button
          slot="footer"
          type="button"
          class={button_class("secondary")}
          phx-click={JS.dispatch("atlas:close", to: "#vendor-drawer")}
        >
          Cancel
        </button>
        <button
          slot="footer"
          type="submit"
          form="vendor-form"
          id="vendor-save"
          class={button_class("primary")}
        >
          Save changes
        </button>
      </atlas-drawer>
    </main>
    """
  end
end
