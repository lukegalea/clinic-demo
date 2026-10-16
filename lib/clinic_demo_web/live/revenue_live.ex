defmodule ClinicDemoWeb.RevenueLive do
  @moduledoc """
  The revenue view — one instrument over the clinic's money: the past the
  ledger holds, the present the books show, and (BD-6) a projected future
  the scenarios draw.

  A host LiveView on the Day view's pattern (chrome around the data, not an
  A2UI surface; no new assets, hand-rolled SVG under the app's strict CSP):

    * **The scrubber** — one timeline card spanning 26 weeks of history and
      the 4-week scenario horizon. The cursor is a day offset carried in
      `?as_of=` (day-granular, the board's time-travel grammar through
      `AsOfSurface.parse/1`; unparseable means the present); the future
      zone is hatched cyan — provisional, never history.
    * **Recognized revenue, by month** — the paid visits as they read *as
      of the cursor*, folded from the value projection. The chart and the
      board's time travel share one grammar: revenue-at-T is the same
      containment read the board does, pinned to a different instant.
    * **The forecast, next four weeks** — every visit still `:scheduled`
      in the window, priced from its catalogue entry and weighted by the
      completion rate history teaches (`Finance.Forecast`). With a
      scenario run selected, a dashed cyan overlay draws the run's own
      weekly answer beside it, and every simulated number wears the
      `SIMULATION · <run>` badge — cyan is a data accent for sim-sourced
      pixels only.
    * **Completion rates** — observed terminal visits and completion share
      per catalogue type, plus the clinic-wide row the fallback chain
      floors at.

  Read-only over the past by design; the one write on the page is
  generating a scenario (an operator's act on the demo's own generator).
  """

  use ClinicDemoWeb, :live_view

  alias ClinicDemo.BusinessEvents.Scenarios
  alias ClinicDemo.BusinessEvents.ValueDrainer
  alias ClinicDemo.Finance
  alias ClinicDemo.Finance.Forecast
  alias ClinicDemoWeb.A2ui.AsOfSurface
  alias ClinicDemoWeb.A2ui.SurfaceChrome

  @surface_id "clinic_revenue"

  # The scrubber's span: 26 weeks of seeded history behind, the scenario
  # horizon's four weeks ahead. Day offsets, not dates — the linear scale
  # honestly dwarfs the future, and that asymmetry IS the story.
  @past_days 180
  @future_days 28
  @horizon_weeks 4

  # Chart geometry, in viewBox units. Both charts share the width so the
  # page reads as one instrument, not two.
  @width 640
  @bar_height 190
  @line_height 150
  @padding_left 8

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:today, Date.utc_today())
      # The chart geometry, mirrored into assigns: inside a ~H block `@x`
      # reads the assigns map, not the module attribute.
      |> assign(
        width: @width,
        bar_height: @bar_height,
        line_height: @line_height,
        padding_left: @padding_left,
        # The scrubber's span, mirrored into assigns: inside a ~H block
        # `@x` reads the assigns map, not the module attribute.
        past_days: @past_days,
        future_days: @future_days
      )
      |> assign(:generating, false)
      # The scenario panel's draft: a param-only form per control — the
      # change/click events are what matter; the knob is a draft until
      # Generate turns it into a run.
      |> assign(:scenario_form, to_form(%{"multiplier" => "1.00"}, as: :scenario))
      |> assign(:label_form, to_form(%{}, as: :label))
      |> assign(:multiplier, Decimal.new("1.00"))
      |> assign(:label_draft, nil)

    # A fold that applied new ledger events (ValueDrainer) re-reads the
    # page, so a visit completed on the board lands here (iron law #03).
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(ClinicDemo.PubSub, ValueDrainer.topic())

    {:ok, SurfaceChrome.mount_presence(socket, @surface_id)}
  end

  @impl true
  def handle_info({:value_projection_drained, _count}, socket) do
    {:noreply,
     load_revenue(socket, socket.assigns.as_of, socket.assigns.run, socket.assigns.runs)}
  end

  # Presence broadcasts for the nav's who-else-is-here, as on the surfaces.
  def handle_info(msg, socket) do
    case AshA2ui.Presence.handle_broadcast(msg, ClinicDemoWeb.A2uiPresence, socket) do
      {:noreply, socket} -> {:noreply, socket}
      :ignored -> {:noreply, socket}
    end
  end

  # Scrubbing, selecting, generating — every state change is navigation or
  # a guarded draft assign (iron law #01: the data loads in handle_params;
  # mount keeps only chrome). An absent or unparseable `?as_of=` is the
  # present — the board's convention, shared grammar.
  @impl true
  def handle_params(params, _uri, socket) do
    runs = Scenarios.runs()
    as_of = as_of_from_params(params)

    {run, socket} =
      validated_run(params, runs, socket)

    if as_of == socket.assigns[:as_of] and run == socket.assigns[:run] and
         socket.assigns[:loaded_for] == {as_of, run, length(runs)} do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> Phoenix.Component.assign(:as_of, as_of)
       |> Phoenix.Component.assign(:run, run)
       |> Phoenix.Component.assign(:runs, runs)
       |> Phoenix.Component.assign(:loaded_for, {as_of, run, length(runs)})
       |> load_revenue(as_of, run, runs)}
    end
  end

  # `?run=` must name a run that exists — a stale shareable URL degrades to
  # a true page (the live forecast) with a flash, never a lying overlay.
  defp validated_run(params, runs, socket) do
    case params["run"] do
      nil ->
        {nil, socket}

      label when is_binary(label) ->
        if Enum.any?(runs, &(&1.simulation_run == label)) do
          {label, socket}
        else
          socket =
            socket
            |> put_flash(
              :info,
              "That scenario run no longer exists — showing the live forecast."
            )
            |> push_patch(to: ~p"/revenue?#{revenue_query(as_of_from_params(params), nil)}")

          {nil, socket}
        end

      _other ->
        {nil, socket}
    end
  end

  # ── events ───────────────────────────────────────────────────────────────

  # The scrubber: a day offset in, a canonical day-granular `?as_of=` out.
  # The run rides along (scrubbing must not drop a selected scenario).
  # The range input is a bare `name="offset"`, so that is the shape the
  # browser posts.
  @impl true
  def handle_event("scrub", %{"offset" => raw}, socket) do
    offset =
      case Integer.parse(raw) do
        {int, _rest} -> clamp(int, -@past_days, @future_days)
        :error -> 0
      end

    as_of = day_offset_to_datetime(offset)

    {:noreply,
     push_patch(socket,
       to: ~p"/revenue?#{revenue_query(as_of, socket.assigns.run)}"
     )}
  end

  # The knob is a draft: assign only, no patch, no generation (a URL per
  # wiggle would be noise; the RUN is the shareable artifact).
  # The knob and the quick-set chips both land here: the knob posts the
  # form's nested params, the chips post their own phx-value. Assign only —
  # no patch, no generation (a URL per wiggle would be noise; the RUN is
  # the shareable artifact).
  def handle_event("multiplier", %{"scenario" => %{"multiplier" => raw}}, socket) do
    set_multiplier(raw, socket)
  end

  def handle_event("multiplier", %{"mult" => raw}, socket) do
    set_multiplier(raw, socket)
  end

  def handle_event("multiplier", %{"multiplier" => raw}, socket) do
    set_multiplier(raw, socket)
  end

  def handle_event("label", %{"label" => %{"draft" => draft}}, socket) do
    {:noreply, assign(socket, :label_draft, draft)}
  end

  def handle_event("select-run", %{"scenario" => %{"run" => ""}}, socket) do
    {:noreply, push_patch(socket, to: ~p"/revenue?#{revenue_query(socket.assigns.as_of, nil)}")}
  end

  def handle_event("select-run", %{"scenario" => %{"run" => label}}, socket)
      when is_binary(label) do
    {:noreply,
     push_patch(socket,
       to: ~p"/revenue?#{revenue_query(socket.assigns.as_of, label)}"
     )}
  end

  # Generating a scenario is the page's one write: the operator's act on
  # the demo's own generator. This demo has no authentication actors — the
  # write routes through `Scenarios.generate!/1`, the domain's generator,
  # whose record path carries the same machinery posture (authorize?: false,
  # structural-only context) as every seed and install! write here. The
  # work itself (deterministic draws + the sim drain) takes seconds, so the
  # spec's loading state applies: the button's loading twins show while
  # @generating holds, and @generating + the delivery keys are the
  # double-click backstop.
  def handle_event("generate", _params, socket) do
    if socket.assigns.generating do
      {:noreply, socket}
    else
      label = normalized_draft(socket.assigns.label_draft)

      multiplier = socket.assigns.multiplier

      {:noreply,
       socket
       |> assign(:generating, true)
       |> start_async(:generate_run, fn ->
         Scenarios.generate!(multiplier: multiplier, label: label, horizon_weeks: @horizon_weeks)
       end)}
    end
  end

  @impl true
  def handle_async(:generate_run, {:ok, result}, socket) do
    {:noreply,
     socket
     |> assign(:generating, false)
     |> assign(:label_draft, nil)
     |> put_flash(
       :info,
       "Scenario #{result.run} ready — #{result.appended} outcomes drawn " <>
         "(#{result.events} in the run)."
     )
     |> push_patch(to: ~p"/revenue?#{revenue_query(socket.assigns.as_of, result.run)}")}
  end

  def handle_async(:generate_run, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:generating, false)
     |> put_flash(
       :error,
       "Scenario generation failed — #{describe_reason(reason)}"
     )}
  end

  # ── render ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <header>
        <h1 class="text-2xl font-display">Revenue</h1>
        <p class="text-foreground/70">
          What completed visits have recognized, and what the schedule says is coming.
          Past weeks are history; the hatched window is projected — every simulated number is badged.
          All times UTC.
        </p>
      </header>

      <section
        aria-label="Timeline scrubber"
        data-testid="rev-scrubber"
        class={[
          "rounded-base border-2 border-border shadow-shadow transition-colors duration-300",
          mode_fill(@mode)
        ]}
      >
        <div class="flex flex-wrap items-center gap-x-4 gap-y-3 px-4 py-3">
          <.form
            for={%{}}
            id="revenue-scrubber-form"
            phx-change="scrub"
            class="flex flex-1 flex-wrap items-center gap-x-3 gap-y-2 min-w-64"
          >
            <label for="rev-scrub-input" class="text-sm font-heading">
              Scrub the timeline
            </label>
            <input
              type="range"
              name="offset"
              id="rev-scrub-input"
              data-testid="rev-scrub-input"
              min={-@past_days}
              max={@future_days}
              step="1"
              value={@day_offset}
              aria-valuetext={readout_label(@as_of, @today)}
              class="h-2 w-full accent-main cursor-ew-resize focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black"
            />
            <div aria-hidden="true" class="relative h-6 w-full">
              <span class="absolute inset-y-0 left-[86.5%] w-0.5 bg-border"></span>
              <span class="absolute top-0 left-[86.5%] -translate-x-1/2 text-[10px] font-heading text-foreground/70">
                NOW
              </span>
              <span class="absolute inset-y-0 right-0 w-[13.5%] bg-stripes text-cyan/30 pointer-events-none"></span>
              <span class="absolute bottom-0 left-0 text-[10px] text-foreground/50 tabular-nums">
                {month_label(@today, -6)}
              </span>
              <span class="absolute bottom-0 left-[43%] text-[10px] text-foreground/50 tabular-nums">
                {month_label(@today, -3)}
              </span>
              <span class="absolute bottom-0 right-[14.5%] text-[10px] text-foreground/50 tabular-nums">
                {month_label(@today, 0)}
              </span>
            </div>
            <span class="text-sm font-heading tabular-nums">
              {readout_label(@as_of, @today)}
            </span>
          </.form>
          <nav aria-label="Preset instants" class="flex flex-wrap items-center gap-1.5">
            <.link
              :for={{label, instant, id} <- revenue_presets(@today)}
              patch={revenue_patch(instant, @run)}
              data-testid={"rev-preset-#{id}"}
              title={preset_title(instant, @mode)}
              aria-current={if(instant == @as_of, do: "true", else: nil)}
              class={[
                "inline-flex h-9 items-center justify-center gap-1.5 whitespace-nowrap rounded-base border-2 border-border px-2.5 text-xs font-heading shadow-shadow ring-offset-white transition-all focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press",
                if(instant == @as_of,
                  do: "bg-main text-main-foreground",
                  else: "bg-secondary-background text-foreground"
                )
              ]}
            >
              <.icon :if={is_nil(instant)} name="hero-arrow-uturn-left" class="size-3.5" />
              {label}
            </.link>
          </nav>
          <span
            data-testid="rev-status-chip"
            role="status"
            class={[
              "tt-status-chip ml-auto inline-flex items-center gap-1.5 rounded-base border-2 border-border px-2.5 py-1 text-xs",
              status_chip(@mode)
            ]}
          >
            {status_chip_text(@mode, @as_of, @today, @run)}
          </span>
        </div>
      </section>

      <section aria-label="Headline numbers" class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.kpi
          :for={kpi <- @kpis}
          label={kpi.label}
          value={kpi.value}
          sub={kpi.sub}
          accent={kpi.accent}
          badge={kpi.badge}
        />
      </section>

      <section
        aria-label="Revenue by month"
        class="rounded-base border-2 border-border bg-secondary-background p-4 shadow-shadow"
      >
        <h2 class="mb-1 text-lg font-heading">Recognized revenue by month</h2>
        <p class="mb-3 text-sm text-foreground/60">
          History — internal clinic events, folded by the value projection. As-of reads: the board's time travel, pointed at money.
        </p>
        <svg
          viewBox={"0 0 #{@width} #{@bar_height + 24}"}
          class="w-full"
          role="img"
          aria-label="Bar chart of recognized revenue per month for the last six months and the current month"
        >
          <.month_bars months={@months} ceiling={@bar_ceiling} />
        </svg>
        <div
          :if={@ledger_not_started}
          data-testid="rev-empty-state"
          class="mt-2 flex items-center gap-2.5 rounded-base border-2 border-dashed border-border bg-secondary-background px-4 py-2.5 text-sm text-foreground/70"
        >
          <.icon name="hero-clock" class="size-4 shrink-0 text-foreground/50" />
          <p>
            <span class="font-heading text-foreground">No revenue recognized yet at this instant.</span>
            The ledger starts later.
          </p>
        </div>
      </section>

      <div class="flex flex-col gap-6 lg:flex-row lg:items-start">
        <section
          aria-label="Forecast"
          class="relative rounded-base border-2 border-border bg-secondary-background p-4 shadow-shadow lg:w-1/2"
        >
          <div class="flex items-start justify-between gap-2">
            <h2 class="mb-1 text-lg font-heading">Forecast — next four weeks</h2>
            <.sim_badge :if={@run} run={@run} />
          </div>
          <p class="mb-3 text-sm text-foreground/60">
            Scheduled visits priced at their catalogue entry, weighted by the completion rate history teaches. Expected revenue per week.
          </p>
          <svg
            viewBox={"0 0 #{@width} #{@line_height + 30}"}
            class="w-full"
            role="img"
            aria-label="Line chart of expected revenue per week for the next four weeks"
          >
            <.forecast_line
              weeks={@weeks}
              ceiling={@line_ceiling}
              sim_weeks={@sim_weeks}
              cursor_week={@cursor_week}
            />
          </svg>
        </section>

        <div class="flex flex-col gap-6 lg:w-1/2">
          <section
            aria-label="Scenario"
            class={[
              "rounded-base border-2 border-border p-4 shadow-shadow transition-colors duration-300",
              if(@run, do: "border-border bg-cyan/15", else: "bg-secondary-background")
            ]}
          >
            <h2 class="mb-1 text-lg font-heading">Scenario — project the next four weeks</h2>
            <p class="mb-3 text-sm text-foreground/60">
              Synthetic events on a separate ledger, folded into their own projection. They never touch real history.
            </p>

            <.form
              for={@scenario_form}
              as={:scenario}
              id="scenario-knob-form"
              phx-change="multiplier"
              class="mb-3"
            >
              <label for="scenario-multiplier" class="text-sm font-heading">
                Completion-rate multiplier
              </label>
              <input
                type="range"
                name="multiplier"
                id="scenario-multiplier"
                data-testid="scenario-multiplier"
                min="0"
                max="1.5"
                step="0.05"
                value={Decimal.to_string(@multiplier)}
                disabled={@generating}
                class="mt-1 h-2 w-full accent-main focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black"
              />
              <div class="mt-1 flex items-center gap-2">
                <span class="font-display text-2xl tabular-nums">× {Decimal.to_string(@multiplier)}</span>
                <button
                  :for={{label, mult, id} <- quick_sets()}
                  type="button"
                  phx-click="multiplier"
                  phx-value-mult={Decimal.to_string(mult)}
                  data-testid={"scenario-quick-#{id}"}
                  disabled={@generating}
                  class="inline-flex h-8 items-center rounded-base border-2 border-border px-2 text-xs font-heading shadow-shadow transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press bg-secondary-background text-foreground"
                >
                  {label}
                </button>
              </div>
            </.form>

            <.form
              for={@label_form}
              as={:label}
              id="scenario-label-form"
              phx-change="label"
              class="mb-3"
            >
              <label for="scenario-label-draft" class="text-sm font-heading">Run label</label>
              <input
                type="text"
                name="label[draft]"
                id="scenario-label-draft"
                value={@label_draft}
                placeholder={suggested_label(@multiplier)}
                disabled={@generating}
                class="mt-1 w-full rounded-base border-2 border-border bg-secondary-background px-2.5 py-1.5 text-sm font-base shadow-shadow focus-visible:outline-hidden focus-visible:ring-2 focus-visible:ring-black"
              />
            </.form>

            <div class="flex flex-wrap items-center gap-2">
              <button
                type="button"
                phx-click="generate"
                data-testid="scenario-generate"
                disabled={@generating}
                phx-click-loading:opacity-60
                phx-click-loading:pointer-events-none
                class="inline-flex h-10 items-center justify-center gap-1.5 rounded-base border-2 border-border bg-main px-3 text-sm font-heading text-main-foreground shadow-shadow transition-all hover:shadow-lift active:translate-x-0.5 active:translate-y-0.5 active:shadow-press phx-click-loading:opacity-60 phx-click-loading:pointer-events-none"
              >
                <span class="phx-click-loading:hidden">Generate scenario →</span>
                <span class="hidden phx-click-loading:inline">Simulating…</span>
              </button>

              <.form
                for={%{}}
                as={:scenario}
                id="scenario-run-select-form"
                phx-change="select-run"
                class="flex-1"
              >
                <.input
                  type="select"
                  field={@scenario_form[:run]}
                  name="scenario[run]"
                  id="scenario-run-select"
                  data-testid="scenario-run-select"
                  prompt="No scenario — live forecast only"
                  options={@run_options}
                  value={@run}
                  disabled={@generating}
                />
              </.form>
            </div>

            <div
              :if={@runs == []}
              class="mt-3 flex items-center gap-2.5 rounded-base border-2 border-dashed border-border bg-secondary-background px-4 py-2.5 text-sm text-foreground/70"
            >
              <.icon name="hero-clock" class="size-4 shrink-0 text-foreground/50" />
              <p>No scenarios yet — set a multiplier and generate one.</p>
            </div>
          </section>

          <section
            aria-label="Completion rates"
            class="rounded-base border-2 border-border bg-secondary-background p-4 shadow-shadow"
          >
            <h2 class="mb-1 text-lg font-heading">What history says</h2>
            <p class="mb-3 text-sm text-foreground/60">
              Visits that reached an outcome, and the share that completed. The forecast's confidence inputs — a cell the history barely observed falls through to the clinic-wide rate.
            </p>
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b-2 border-border text-left">
                  <th class="py-1.5 pr-2 font-heading">Visit type</th>
                  <th class="py-1.5 pr-2 font-heading">Completed</th>
                  <th class="py-1.5 pr-2 font-heading">Observed</th>
                  <th class="py-1.5 font-heading">Completion</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @rate_table} class="border-b border-border/40 last:border-b-0">
                  <td class="py-1.5 pr-2">{row.name}</td>
                  <td class="py-1.5 pr-2">{row.completed}</td>
                  <td class="py-1.5 pr-2">{row.total}</td>
                  <td class="py-1.5 font-base">{percent(row.rate)}</td>
                </tr>
              </tbody>
            </table>
          </section>
        </div>
      </div>
    </div>
    """
  end

  # ── components ───────────────────────────────────────────────────────────

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil
  attr :accent, :atom, default: nil
  attr :badge, :string, default: nil

  defp kpi(assigns) do
    fill =
      case assigns.accent do
        :violet -> "bg-violet"
        :cyan -> "bg-cyan"
        _ -> "bg-main"
      end

    assigns = assign(assigns, :fill, fill)

    ~H"""
    <div class={"rounded-base border-2 border-border p-3 shadow-shadow " <> @fill}>
      <div class="flex items-start justify-between gap-1">
        <div class="text-xs font-base opacity-80">{@label}</div>
        <.sim_badge :if={@badge} run={@badge} />
      </div>
      <div class="mt-1 text-xl font-display">{@value}</div>
      <div :if={@sub} class="text-xs font-base opacity-80">{@sub}</div>
    </div>
    """
  end

  attr :run, :string, required: true

  defp sim_badge(assigns) do
    ~H"""
    <span
      data-testid="sim-badge"
      class="inline-flex items-center gap-1 whitespace-nowrap rounded-base border-2 border-border bg-cyan px-2 py-0.5 text-xs font-heading text-foreground"
    >
      SIMULATION · {@run}
    </span>
    """
  end

  attr :months, :list, required: true
  attr :ceiling, :any, required: true

  defp month_bars(assigns) do
    %{months: months} = assigns
    n = max(length(months), 1)
    slot_w = (@width - @padding_left * 2) / n
    bar_w = slot_w * 0.6

    assigns =
      assigns
      |> assign(:slot_w, slot_w)
      |> assign(:bar_w, bar_w)
      |> assign(:baseline, @bar_height)
      |> assign(:width, @width)
      |> assign(:padding_left, @padding_left)

    ~H"""
    <line
      x1={@padding_left}
      y1={@baseline}
      x2={@width - @padding_left}
      y2={@baseline}
      stroke="currentColor"
      stroke-width="2"
    />
    <%= for {row, i} <- Enum.with_index(@months) do %>
      <% h = scaled_height(row.total, @ceiling, @baseline - 20) %>
      <% x = @padding_left + i * @slot_w + (@slot_w - @bar_w) / 2 %>
      <rect
        x={x}
        y={@baseline - h}
        width={@bar_w}
        height={h}
        class="fill-main"
        stroke="currentColor"
        stroke-width="2"
      />
      <text
        x={x + @bar_w / 2}
        y={@baseline - h - 5}
        text-anchor="middle"
        class="fill-current text-[11px] font-base"
      >
        {money(row.total)}
      </text>
      <text
        x={x + @bar_w / 2}
        y={@baseline + 16}
        text-anchor="middle"
        class="fill-current text-[11px] font-base"
      >
        {Calendar.strftime(row.month, "%b %Y")}
      </text>
    <% end %>
    """
  end

  attr :weeks, :list, required: true
  attr :ceiling, :any, required: true
  attr :sim_weeks, :list, required: true
  attr :cursor_week, :any, required: true

  # The real line: unchanged (currentColor, yellow points — evidence).
  # With a run: the dashed cyan overlay spans ALL horizon weeks (the run's
  # complete answer); weeks at-or-before the cursor draw filled points (the
  # accrued prefix reads at a glance), and the solid cyan cursor dot rides
  # the week containing the cursor.
  defp forecast_line(assigns) do
    %{weeks: weeks, ceiling: ceiling, sim_weeks: sim_weeks, cursor_week: cursor_week} = assigns
    n = max(length(weeks), 2)
    slot_w = (@width - @padding_left * 2) / (n - 1)

    points =
      weeks
      |> Enum.with_index()
      |> Enum.map(fn {week, i} ->
        x = @padding_left + i * slot_w
        y = @line_height - scaled_height(week.expected, ceiling, @line_height - 30)
        {x, y, week}
      end)

    sim_points =
      sim_weeks
      |> Enum.with_index()
      |> Enum.map(fn {week, i} ->
        x = @padding_left + i * slot_w
        y = @line_height - scaled_height(week.recognized, ceiling, @line_height - 30)
        {x, y, week}
      end)

    cursor_dot =
      case cursor_week do
        nil ->
          nil

        week_start ->
          Enum.find(sim_points, fn {_x, _y, week} -> week.week_start == week_start end)
      end

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:sim_points, sim_points)
      |> assign(:cursor_dot, cursor_dot)
      |> assign(:slot_w, slot_w)
      |> assign(:baseline, @line_height)
      |> assign(:width, @width)
      |> assign(:padding_left, @padding_left)

    ~H"""
    <line
      x1={@padding_left}
      y1={@baseline}
      x2={@width - @padding_left}
      y2={@baseline}
      stroke="currentColor"
      stroke-width="2"
    />
    <polyline
      :if={@sim_points != []}
      data-testid="sim-overlay"
      points={Enum.map_join(@sim_points, " ", fn {x, y, _} -> "#{x},#{y}" end)}
      fill="none"
      stroke="currentColor"
      class="text-cyan"
      stroke-dasharray="7 5"
      stroke-width="2.5"
    />
    <polyline
      points={Enum.map_join(@points, " ", fn {x, y, _} -> "#{x},#{y}" end)}
      fill="none"
      stroke="currentColor"
      stroke-width="2.5"
    />
    <%= for {x, y, _week} <- @points do %>
      <circle cx={x} cy={y} r="4" class="fill-yellow" stroke="currentColor" stroke-width="2" />
      <text x={x} y={y - 9} text-anchor="middle" class="fill-current text-[11px] font-base">
        {money(week_expected(@points, x, y))}
      </text>
    <% end %>
    <%= for {x, y, week} <- @sim_points do %>
      <% filled? = @cursor_week != nil and Date.compare(week.week_start, @cursor_week) != :gt %>
      <circle
        cx={x}
        cy={y}
        r="4"
        fill={if filled?, do: "var(--color-cyan)", else: "none"}
        stroke="currentColor"
        class="text-cyan"
        stroke-width="2"
      />
    <% end %>
    <circle
      :if={@cursor_dot}
      cx={elem(@cursor_dot, 0)}
      cy={elem(@cursor_dot, 1)}
      r="5"
      fill="var(--color-cyan)"
      stroke="black"
      stroke-width="2"
    />
    <%= for {x, y, week} <- @sim_points do %>
      <text
        x={x}
        y={y - 9}
        text-anchor="middle"
        class="fill-current text-[11px] font-base text-cyan"
      >
        {money(week.recognized)}
      </text>
    <% end %>
    """
  end

  defp week_expected(points, x, _y) do
    {_x, _y, week} = Enum.find(points, fn {px, _py, _w} -> px == x end)
    week.expected
  end

  # ── data ─────────────────────────────────────────────────────────────────

  # One pass over the reads the page is, pinned at the cursor: the money,
  # the outcomes, the forward window — and, with a run selected, the run's
  # own weekly answer and its cursor-scoped numbers. At rest (no cursor)
  # every read takes its unpinned path — the at-rest page is BD-4's page,
  # numbers and SQL.
  defp load_revenue(socket, as_of, run, _runs) do
    today = socket.assigns.today
    mode = mode_of(as_of, run, today)
    cursor_date = cursor_date(as_of, today)

    months = Finance.value_by_month(months: 7, as_of: as_of)
    rates = projection_rates(as_of)
    scheduled = forecast_schedule(as_of)
    weeks = Forecast.weekly(scheduled, rates, cursor_date)

    sim = sim_summary(run, as_of)

    type_names =
      ClinicDemo.Scheduling.list_appointment_types!(authorize?: false)
      |> Map.new(&{&1.id, &1.name})

    ceiling_values =
      Enum.map(weeks, & &1.expected) ++ Enum.map(sim_week_list(sim), & &1.recognized)

    kpis =
      kpis(%{
        mode: mode,
        as_of: as_of,
        cursor_date: cursor_date,
        month_to_date: month_total(months),
        month_count: month_count(months),
        trailing_total: trailing_total(months),
        scheduled_count: length(scheduled),
        forecast_total: forecast_total(weeks),
        sim: sim
      })

    socket
    |> assign(:mode, mode)
    |> assign(:day_offset, day_offset(as_of, today))
    |> assign(:months, months)
    |> assign(:bar_ceiling, clean_ceiling(Enum.map(months, & &1.total), 5_000))
    |> assign(:month_to_date, month_total(months))
    |> assign(:month_count, month_count(months))
    |> assign(:trailing_total, trailing_total(months))
    |> assign(:scheduled_count, length(scheduled))
    |> assign(:weeks, weeks)
    |> assign(:line_ceiling, clean_ceiling(ceiling_values, 1_000))
    |> assign(:forecast_total, forecast_total(weeks))
    |> assign(:rate_table, Forecast.rate_table(rates, type_names))
    |> assign(:sim_weeks, sim_week_list(sim))
    |> assign(:sim_horizon_expected, sim && sim.horizon_expected)
    |> assign(:sim_recognized_to_t, sim && sim.recognized_to_t)
    |> assign(:sim_remaining, sim && sim.remaining_after_t)
    |> assign(:cursor_week, cursor_week(run, as_of))
    |> assign(:kpis, kpis)
    |> assign(:ledger_not_started, ledger_not_started?(months, as_of))
    |> assign(:run_options, run_options(socket.assigns[:runs] || []))
  end

  # The rates read the projection's evidence as of the cursor (the fold is
  # the /revenue source since BD-3).
  defp projection_rates(as_of) do
    as_of
    |> then(&Finance.projected_outcomes(as_of: &1))
    |> Forecast.build_rates()
  end

  # The forecast's window: over the schedule as it read at a past cursor
  # (the retro-forecast), over the live schedule from now otherwise.
  defp forecast_schedule(as_of) do
    history? =
      as_of != nil and Date.compare(cursor_date(as_of, Date.utc_today()), Date.utc_today()) == :lt

    if history? do
      Finance.scheduled_with_prices(4, as_of: as_of)
    else
      Finance.scheduled_with_prices(4)
    end
  end

  # The run's own summary, or nil without a selected run.
  defp sim_summary(nil, _as_of), do: nil

  defp sim_summary(run, as_of),
    do: Finance.sim_run_summary(run, as_of: as_of, weeks: @horizon_weeks)

  defp sim_week_list(nil), do: []
  defp sim_week_list(%{weeks: weeks}), do: weeks

  # The overlay's cursor dot rides the week containing the cursor — only
  # while a cursor is pinned (the live page shows the full answer).
  defp cursor_week(_run, nil), do: nil

  defp cursor_week(_run, %DateTime{} = as_of),
    do: as_of |> DateTime.to_date() |> Date.beginning_of_week()

  defp ledger_not_started?(months, as_of) do
    as_of != nil and Enum.all?(months, fn m -> Decimal.eq?(m.total, Decimal.new(0)) end)
  end

  defp month_total(months), do: List.last(months).total
  defp month_count(months), do: List.last(months).count

  defp trailing_total(months) do
    months
    |> Enum.drop(-1)
    |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.total))
  end

  defp forecast_total(weeks) do
    Enum.reduce(weeks, Decimal.new(0), &Decimal.add(&2, &1.expected))
  end

  # The SIM-mode KPI numbers, off one sim summary.
  defp kpis(opts) do
    cond do
      opts.mode == :history and opts[:sim] == nil -> history_kpis(opts)
      opts.mode == :sim and opts[:sim] != nil -> sim_kpis(opts[:sim], opts[:as_of])
      opts.mode == :future -> future_kpis(opts)
      true -> live_kpis(opts)
    end
  end

  defp live_kpis(opts) do
    [
      %{
        label: "Recognized this month",
        value: money(opts.month_to_date),
        sub: "#{opts.month_count} charges",
        accent: nil,
        badge: nil
      },
      %{
        label: "Trailing six months",
        value: money(opts.trailing_total),
        sub: "paid charges",
        accent: nil,
        badge: nil
      },
      %{
        label: "Scheduled, next 4 weeks",
        value: Integer.to_string(opts.scheduled_count),
        sub: "visits on the books",
        accent: nil,
        badge: nil
      },
      %{
        label: "Four-week forecast",
        value: money(opts.forecast_total),
        sub: "expected revenue",
        accent: nil,
        badge: nil
      }
    ]
  end

  defp history_kpis(opts) do
    month_label_at = Calendar.strftime(opts.cursor_date, "%b %Y")

    opts
    |> live_kpis()
    |> put_in([Access.at(0), :label], "Recognized as of #{month_label_at}")
    |> put_in([Access.at(1), :label], "Trailing at #{month_label_at}")
    |> put_in([Access.at(2), :label], "On the books at #{month_label_at}")
    |> put_in([Access.at(3), :label], "Forecast as known at #{month_label_at}")
    |> then(fn kpis ->
      kpis
      |> List.update_at(0, &Map.put(&1, :accent, :violet))
      |> List.update_at(1, &Map.put(&1, :accent, :violet))
    end)
  end

  defp sim_kpis(sim, as_of) do
    week_of_t = sim_week_of(sim, opts_cursor_date(as_of))

    [
      %{
        label: "Sim recognized, week of #{week_label(week_of_t)}",
        value: money(sim.recognized_to_t),
        sub: "simulated",
        accent: :cyan,
        badge: "sim"
      },
      %{
        label: "Sim cumulative to #{format_date(as_of)}",
        value: money(sim.recognized_to_t),
        sub: "simulated",
        accent: :cyan,
        badge: "sim"
      },
      %{
        label: "Sim visits remaining after #{format_date(as_of)}",
        value: Integer.to_string(sim.remaining_after_t),
        sub: "simulated",
        accent: :cyan,
        badge: "sim"
      },
      %{
        label: "Run's full-horizon expectation",
        value: money(sim.horizon_expected),
        sub: "simulated",
        accent: :cyan,
        badge: "sim"
      }
    ]
  end

  defp future_kpis(opts) do
    # Future cursor without a run: the real numbers clamp at now.
    opts
    |> live_kpis()
    |> put_in([Access.at(2), :sub], "as of now")
    |> put_in([Access.at(3), :sub], "as of now")
  end

  defp opts_cursor_date(as_of) do
    if as_of, do: DateTime.to_date(as_of), else: Date.utc_today()
  end

  defp sim_week_of(sim, cursor_date) do
    Enum.find(sim.weeks, fn week ->
      Date.compare(week.week_start, cursor_date) != :gt and
        Date.compare(week.week_end, cursor_date) != :lt
    end) || List.last(sim.weeks)
  end

  defp week_label(nil), do: ""
  defp week_label(%{week_start: week_start}), do: Calendar.strftime(week_start, "%b %-d")

  # The mode: where the cursor stands relative to today, and whether a run
  # is projected into the future.
  defp mode_of(as_of, run, today) do
    cond do
      is_nil(as_of) -> :live
      Date.compare(DateTime.to_date(as_of), today) == :gt -> if(run, do: :sim, else: :future)
      true -> :history
    end
  end

  defp mode_fill(:history), do: "bg-violet"
  defp mode_fill(_other), do: "bg-secondary-background"

  defp status_chip(:live), do: "bg-green text-foreground"
  defp status_chip(:history), do: "bg-black text-white"
  defp status_chip(:sim), do: "bg-cyan text-foreground"
  defp status_chip(:future), do: "bg-neutral text-foreground"

  defp status_chip_text(:live, _as_of, _today, _run), do: "● Live now"

  defp status_chip_text(:history, as_of, _today, _run),
    do: "⟲ Viewing #{format_date(as_of)} — history"

  defp status_chip_text(:sim, _as_of, _today, run), do: "◐ Projecting — SIM · #{run}"

  defp status_chip_text(:future, as_of, _today, _run),
    do: "○ #{format_date(as_of)} — no scenario selected"

  defp format_date(nil), do: ""

  defp format_date(%DateTime{} = as_of),
    do: as_of |> DateTime.to_date() |> Calendar.strftime("%b %-d %Y")

  defp readout_label(as_of, today), do: readout_label(as_of, today, nil)

  defp readout_label(nil, today, _run), do: Calendar.strftime(today, "%b %-d %Y")

  defp readout_label(%DateTime{} = as_of, _today, _run) do
    Calendar.strftime(DateTime.to_date(as_of), "%b %-d %Y")
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # The charts' y-ceiling: the largest value rounded UP to a clean step, so
  # a data wiggle never redraws the axis. At least one step — an empty
  # ledger renders a flat, honest zero.
  defp clean_ceiling(values, step) do
    top =
      values
      |> Enum.map(&Decimal.to_float/1)
      |> Enum.max()

    steps = max(1.0, Float.ceil(top / step))
    Decimal.from_float(steps * step)
  end

  defp scaled_height(value, ceiling, height) do
    v = Decimal.to_float(value)
    m = Decimal.to_float(ceiling)

    if m <= 0, do: 0, else: max(0, v / m * height)
  end

  defp money(%Decimal{} = amount) do
    whole =
      amount
      |> Decimal.round(0)
      |> Decimal.to_string()
      |> grouping()

    "$" <> whole
  end

  defp grouping(digits) do
    digits
    |> String.graphemes()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.join(",")
    |> String.reverse()
  end

  defp percent(nil), do: "—"

  defp percent(%Decimal{} = rate) do
    rate
    |> Decimal.mult(100)
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> Kernel.<>("%")
  end

  # ── the grammar ──────────────────────────────────────────────────────────

  defp as_of_from_params(%{"as_of" => raw}) when is_binary(raw) do
    case AsOfSurface.parse(raw) do
      {:ok, as_of} -> as_of
      :error -> nil
    end
  end

  defp as_of_from_params(_params), do: nil

  defp as_of_param(nil), do: nil
  defp as_of_param(%DateTime{} = as_of), do: DateTime.to_iso8601(as_of)

  # The patch query: nil params are DROPPED, never emitted as empties — an
  # `as_of=` empty in the URL parses back to the present (harmless), but the
  # canonical URL carries only what the view means.
  defp revenue_query(as_of, run) do
    %{}
    |> maybe_put_param(:as_of, as_of_param(as_of))
    |> maybe_put_param(:run, run)
  end

  defp maybe_put_param(query, _key, nil), do: query
  defp maybe_put_param(query, key, value), do: Map.put(query, key, value)

  defp day_offset(as_of, today)

  defp day_offset(nil, today), do: Date.diff(today, today)

  defp day_offset(%DateTime{} = as_of, today) do
    as_of |> DateTime.to_date() |> Date.diff(today) |> clamp(-@past_days, @future_days)
  end

  defp day_offset_to_datetime(offset) do
    DateTime.new!(Date.add(Date.utc_today(), offset), ~T[00:00:00], "Etc/UTC")
  end

  defp clamp(int, min, max), do: int |> max(min) |> min(max)

  defp cursor_date(nil, today), do: today
  defp cursor_date(%DateTime{} = as_of, _today), do: DateTime.to_date(as_of)

  # The quick jumps: past and future — the future presets walk the
  # scenario horizon. Each chip carries its exact instant in the `?as_of=`
  # param (the URL stays the source of truth); "Now" is the reset: no
  # params at all except a selected run.
  defp revenue_presets(today) do
    [
      {"Now", nil, "now"},
      {"−1 mo", days_from_today(today, -30), "1mo"},
      {"−3 mo", days_from_today(today, -90), "3mo"},
      {"+1 wk", days_from_today(today, 7), "1w"},
      {"+2 wk", days_from_today(today, 14), "2w"},
      {"+4 wk", days_from_today(today, 28), "4w"}
    ]
  end

  defp days_from_today(today, days),
    do: today |> Date.add(days) |> DateTime.new!(~T[00:00:00], "Etc/UTC")

  defp revenue_patch(instant, run)

  defp revenue_patch(nil, run) do
    if run do
      ~p"/revenue?#{%{run: run}}"
    else
      ~p"/revenue"
    end
  end

  defp revenue_patch(%DateTime{} = instant, run) do
    if run do
      ~p"/revenue?#{%{as_of: DateTime.to_iso8601(instant), run: run}}"
    else
      ~p"/revenue?as_of=#{DateTime.to_iso8601(instant)}"
    end
  end

  defp preset_title(nil, _mode), do: "Back to the live page"
  defp preset_title(%DateTime{} = instant, _mode), do: as_of_label(instant)

  defp as_of_label(%DateTime{} = as_of),
    do: as_of |> DateTime.to_date() |> Calendar.strftime("%b %-d %Y")

  # ── the scenario panel's draft plumbing ──────────────────────────────────

  defp parse_multiplier(raw) do
    case Decimal.parse(to_string(raw)) do
      {%Decimal{} = mult, _rest} -> mult
      :error -> Decimal.new("1.00")
    end
  end

  defp suggested_label(multiplier), do: "×#{Decimal.to_string(multiplier)} · 4wk"

  defp label_draft(nil, multiplier), do: suggested_label(multiplier)
  defp label_draft(draft, _multiplier) when is_binary(draft), do: draft

  defp normalized_draft(nil), do: nil

  defp normalized_draft(draft) when is_binary(draft) do
    case String.trim(draft) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp quick_sets do
    [
      {"×0.80 cautious", Decimal.new("0.80"), "080"},
      {"×1.00 baseline", Decimal.new("1.00"), "100"},
      {"×1.20 optimistic", Decimal.new("1.20"), "120"}
    ]
  end

  defp run_options(runs) do
    Enum.map(runs, fn run ->
      {"#{run.simulation_run} — #{run.events} events", run.simulation_run}
    end)
  end

  defp set_multiplier(raw, socket) do
    multiplier = parse_multiplier(raw)

    {:noreply,
     socket
     |> assign(:multiplier, multiplier)
     |> assign(:label_draft, label_draft(socket.assigns.label_draft, multiplier))}
  end

  defp describe_reason(%_struct{} = reason) when is_exception(reason),
    do: Exception.message(reason)

  defp describe_reason(reason), do: inspect(reason, limit: 5)

  defp month_label(today, months) do
    today
    |> Date.beginning_of_month()
    |> Date.add(months)
    |> Calendar.strftime("%b")
  end
end
