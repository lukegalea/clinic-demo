defmodule ClinicDemoWeb.AgentLive do
  @moduledoc """
  The helper agent console.

  Ask for something in plain language. The console shows you a table, composes
  one for you, or answers a question — in that order of preference.

  ## Three things it can do, all of them reads

      "show me the patients"
        --> Interpreter     --> a DECLARED surface, from the registry
        --> rendered immediately, filtered by YOUR policies

      "appointments, just patient and triage urgency, sorted by time"
        --> Interpreter     --> a spec the model COMPOSED
        --> resolved against an allowlist, verified, then rendered

      "what makes an appointment an emergency?"
        --> Interpreter     --> an ANSWER, grounded in the surface catalogue
        --> shown in words; the catalogue it answers from is the same one
            that drove the classification

  Every path is a read, and that is the point rather than a limitation. A
  table is filtered by the viewer's own policies before a single row reaches
  the page, an answer can only restate what the catalogue already declares,
  and the model holds no tool that could do otherwise. Prompt injection is
  uninteresting here because there is no path from generated text to a change.

  ## Surfaces the agent shows are live

  A surface whose resource publishes notifications keeps updating after it is
  rendered — including when the writer was a different application entirely.
  None of this demo's resources publish today, so every surface is currently
  static; the machinery is already here for the first one that does.

  ## Zero-LLM path

  The declared surfaces are one click away and never touch a model, so the
  console is useful exactly as far as a fresh checkout with no API key — which
  is the state it ships in.
  """

  use ClinicDemoWeb, :live_view

  alias ClinicDemo.AI.Interpreter
  alias ClinicDemoWeb.A2ui.Host
  alias ClinicDemoWeb.A2ui.Surfaces

  @cue_visible_ms 6_000

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:request, "")
     |> assign(:error, nil)
     |> assign(:result, nil)
     |> assign(:thinking, false)
     |> assign(:presentation, nil)
     |> assign(:refresh_scheduled?, false)
     |> assign(:cue, nil)
     |> assign(:cue_ref, nil)}
  end

  # The LiveView is the coordinator, not the worker: interpretation is one or
  # two synchronous model calls, and running them here would freeze this page
  # (and its console) for the round trip. The event acks immediately with a
  # thinking state on the wire; the plan arrives in handle_async and renders
  # through the same carry_out paths the buttons use.
  @impl true
  def handle_event("propose", %{"request" => request}, socket) do
    socket =
      socket
      |> assign(request: request, error: nil, result: nil, thinking: true)
      |> start_async(:interpret, fn -> Interpreter.interpret(request) end)

    {:noreply, socket}
  end

  # The declared surfaces, one click away. A person who already knows which table
  # they want should not have to spend a model call and a round trip to say so --
  # and the console should still be useful when no API key is configured, which
  # is the state a fresh checkout is in.
  def handle_event("show-surface", %{"name" => name}, socket) do
    case Surfaces.fetch(name) do
      nil ->
        {:noreply, assign(socket, :error, "No surface named #{inspect(name)}.")}

      surface ->
        socket =
          socket
          |> assign(error: nil, request: "")
          |> present(Host.declared(surface), socket.assigns[:a2ui_actor])

        {:noreply, socket}
    end
  end

  def handle_event("dismiss-surface", _params, socket) do
    Host.dismiss(socket.assigns.presentation)

    {:noreply, assign(socket, presentation: nil, cue: nil)}
  end

  # The client interacted with the rendered surface. Routed through the handler
  # rather than into an Ash action directly: the handler is what enforces the
  # row-action allowlist, `visible_when`, and the error contract that puts
  # validation messages on the reserved `/errors/<field>` paths.
  def handle_event("a2ui:action", envelope, %{assigns: %{presentation: nil}} = socket) do
    # Nothing is being shown, so there is nothing this envelope can refer to.
    # Rebuilding a surface from something the client echoed back is exactly the
    # tamper-proofing hole the server-held presentation exists to close.
    _ = envelope
    {:noreply, socket}
  end

  def handle_event("a2ui:action", envelope, socket) do
    {socket, presentation} =
      Host.handle_action(socket, socket.assigns.presentation, envelope,
        actor: socket.assigns[:a2ui_actor]
      )

    {:noreply, assign(socket, :presentation, presentation)}
  end

  # The interpreter is back. A plan renders exactly as it did when this work
  # was synchronous; a provider error is the same flash it always was; a
  # crash is new, and is treated as an ordinary, non-blocking failure.
  @impl true
  def handle_async(:interpret, {:ok, {:ok, plan}}, socket) do
    {:noreply, carry_out(plan, assign(socket, :thinking, false), socket.assigns[:a2ui_actor])}
  end

  def handle_async(:interpret, {:ok, {:error, message}}, socket) do
    {:noreply, assign(socket, thinking: false, error: message)}
  end

  # A crash inside the interpreter must not freeze or blank the console: the
  # error is non-blocking, the thinking state clears, and everything else on
  # the page stays exactly where it was.
  def handle_async(:interpret, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       thinking: false,
       error: "the interpreter stopped before answering — ask again."
     )}
  end

  @impl true
  def handle_info(:clear_cue, socket) do
    {:noreply, assign(socket, cue: nil, cue_ref: nil)}
  end

  # The debounce window closed: rebuild the rows and raise the cue together. The
  # cue is deliberately NOT raised when the broadcast arrives -- announcing an
  # update 150 ms before it lands reads as a bug even though nothing is wrong.
  def handle_info({:ash_a2ui_host, :refresh}, %{assigns: %{presentation: nil}} = socket) do
    {:noreply, assign(socket, :refresh_scheduled?, false)}
  end

  def handle_info({:ash_a2ui_host, :refresh}, socket) do
    {socket, presentation} =
      Host.refresh(socket, socket.assigns.presentation, actor: socket.assigns[:a2ui_actor])

    if socket.assigns.cue_ref, do: Process.cancel_timer(socket.assigns.cue_ref)
    ref = Process.send_after(self(), :clear_cue, @cue_visible_ms)

    {:noreply,
     socket
     |> assign(:presentation, presentation)
     |> assign(:refresh_scheduled?, false)
     |> assign(:cue, (socket.assigns.cue || 0) + 1)
     |> assign(:cue_ref, ref)}
  end

  # Anything else while a surface is subscribed is a notification on one of its
  # topics. Ash's PubSub notifier can send a %Notification{}, a
  # %Phoenix.Socket.Broadcast{} or a bare map depending on `broadcast_type`, so
  # this matches on none of them and coalesces whatever arrives.
  def handle_info(_message, %{assigns: %{presentation: nil}} = socket), do: {:noreply, socket}

  def handle_info(_message, socket) do
    case Host.schedule_refresh(socket.assigns.refresh_scheduled?) do
      :scheduled -> {:noreply, assign(socket, :refresh_scheduled?, true)}
      :already_scheduled -> {:noreply, socket}
    end
  end

  # A declared surface: show it. No confirmation, because the surface is built
  # by running the resource's own read action with this viewer as the actor --
  # the rows a person sees are the rows their policies allow, decided before
  # anything renders.
  defp carry_out({:surface, surface}, socket, actor) do
    present(socket, Host.declared(surface), actor)
  end

  defp carry_out({:designed, surface, title}, socket, actor) do
    present(socket, Host.dynamic(surface, title), actor)
  end

  # An answer is words, not a surface: it goes in the result banner, the same
  # place confirmations of nothing live. It is already bounded -- the prompt
  # grounds it in the catalogue -- so there is nothing further to check here.
  defp carry_out({:answer, text}, socket, _actor) do
    assign(socket, result: text, request: "")
  end

  defp present(socket, presentation, actor) do
    # Drop the previous subscription first. Without this, asking for three
    # surfaces in a row leaves the LiveView subscribed to all three and a write
    # to any of them refreshes a surface nobody is looking at.
    Host.dismiss(socket.assigns.presentation)

    {socket, presentation} = Host.present(socket, presentation, actor: actor)

    socket
    |> assign(:presentation, presentation)
    |> assign(:cue, nil)
    |> assign(:result, nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <div class="space-y-6">
        <header>
          <h1 class="text-2xl font-heading">Helper</h1>
          <p class="text-foreground/70 text-sm">
            Ask in plain language — it shows a surface, composes a table, or answers a
            question about this clinic. It changes nothing.
          </p>
        </header>

        <form phx-submit="propose" class="flex w-full gap-2" id="agent-request">
          <input
            type="text"
            name="request"
            value={@request}
            placeholder="Show me the patients"
            class="h-10 w-full rounded-base border-2 border-border bg-secondary-background px-3 py-2 text-sm font-base placeholder:text-foreground/50 focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2"
            autocomplete="off"
          />
          <%!-- Acknowledgement is twofold: the CSS loading variant fires the
               instant the form is submitted (before the server acks), and
               the :thinking assign keeps the button down for as long as the
               interpreter is actually out. --%>
          <button
            type="submit"
            disabled={@thinking}
            class="inline-flex h-10 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-main px-4 py-2 text-sm font-base text-main-foreground shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press phx-submit-loading:opacity-50 phx-submit-loading:pointer-events-none"
          >
            {if @thinking, do: "Thinking…", else: "Ask"}
          </button>
        </form>

        <p class="text-foreground/50 text-xs">
          Try: <span class="font-mono">show me the patients</span>
          ·
          <span class="font-mono">appointments, just patient and triage urgency, sorted by time</span>
          · <span class="font-mono">what makes an appointment an emergency?</span>
        </p>

        <div class="flex flex-wrap items-center gap-2">
          <span class="text-foreground/50 text-xs">or open one directly:</span>
          <button
            :for={surface <- Surfaces.all()}
            phx-click="show-surface"
            phx-value-name={surface.name}
            id={"open-#{surface.name}"}
            class="inline-flex h-8 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-2.5 text-xs font-base text-foreground shadow-shadow transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press phx-click-loading:opacity-50 phx-click-loading:pointer-events-none"
          >
            {surface.label}
          </button>
        </div>

        <%!-- The interpreter is out; the console says so in the same slot the
             result lands in, so nothing jumps when it is replaced. --%>
        <div
          :if={@thinking}
          class="relative grid w-full gap-2 rounded-base border-2 border-border bg-background px-4 py-3 text-sm text-foreground shadow-shadow"
          role="status"
        >
          <span class="whitespace-pre-line">Thinking…</span>
        </div>

        <div
          :if={@error}
          class="relative grid w-full gap-2 rounded-base border-2 border-border bg-black px-4 py-3 text-sm text-white shadow-shadow"
          role="alert"
        >
          <span class="whitespace-pre-line">{@error}</span>
        </div>

        <div
          :if={@result}
          class="relative grid w-full gap-2 rounded-base border-2 border-border bg-background px-4 py-3 text-sm text-foreground shadow-shadow"
          role="status"
        >
          <span class="whitespace-pre-line">{@result}</span>
        </div>

        <%!--
        The surface the agent chose or composed. The container is always in the
        DOM once something has been shown, because the renderer owns it
        (`phx-update="ignore"`) and LiveView must not remove and re-add a node it
        has been told to keep out of -- the hook would remount with no surface.
        Dismissing hides the wrapper instead.
      --%>
        <div :if={@presentation} class="space-y-3" data-role="surface">
          <div class="flex items-start justify-between gap-4">
            <div>
              <h2 class="flex flex-wrap items-center gap-2 text-lg font-heading">
                {@presentation.title}
                <.badge
                  :if={@presentation.kind == :dynamic}
                  tone="violet"
                  title="Composed for this request, then validated against the schema"
                >
                  composed
                </.badge>
                <.badge
                  :if={@presentation.topics != []}
                  tone="green"
                  title="This surface updates itself when the underlying rows change"
                >
                  live
                </.badge>
              </h2>
              <p :if={@presentation.subtitle} class="text-foreground/60 text-sm">
                {@presentation.subtitle}
              </p>
            </div>
            <%!-- Optimistic dismiss: the panel hides the instant the click
                 lands; the server does its PubSub cleanup afterwards and the
                 reconciling patch finds it already gone. --%>
            <button
              phx-click={JS.push("dismiss-surface") |> JS.hide(to: "[data-role=surface]")}
              class="inline-flex h-9 items-center justify-center gap-2 whitespace-nowrap rounded-base border-2 border-border bg-secondary-background px-3 text-sm font-base text-foreground shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black focus-visible:ring-offset-2 disabled:pointer-events-none disabled:opacity-50 hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press"
            >
              Dismiss
            </button>
          </div>

          <%!--
          Keyed on the counter so the element is genuinely removed and re-added
          for each refresh, which is what makes `phx-mounted` fire again rather
          than only on the first change.
        --%>
          <div :if={@cue} id={"agent-cue-#{@cue}"}>
            <div
              class="flex items-center gap-2 rounded-base border-2 border-amber-500 bg-amber-50 px-4 py-2 text-sm text-amber-900 dark:border-amber-500/40 dark:bg-amber-950/60 dark:text-amber-100"
              phx-mounted={
                JS.transition(
                  {"transition-all duration-500 ease-out", "opacity-0 -translate-y-1",
                   "opacity-100 translate-y-0"},
                  time: 500
                )
              }
            >
              <span class="relative flex size-2">
                <span class="absolute inline-flex size-2 animate-ping rounded-full bg-amber-500 opacity-75" />
                <span class="relative inline-flex size-2 rounded-full bg-amber-500" />
              </span>
              <span>
                These rows were rebuilt
                <span :if={@cue > 1} class="font-semibold">({@cue} updates)</span>
              </span>
            </div>
          </div>
        </div>

        <div class={["", if(!@presentation, do: "hidden")]}>
          {AshA2ui.LiveRenderer.surface_container(assigns)}
        </div>
      </div>
    </Layouts.app>
    """
  end
end
