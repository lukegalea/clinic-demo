defmodule ClinicDemoWeb.RevenueLive do
  @moduledoc """
  The revenue view — where the clinic's money has been, and where the
  schedule says it is going.

  A host LiveView on the Day view's pattern (chrome around the data, not an
  A2UI surface; no new assets, hand-rolled SVG under the app's strict CSP):

    * **Recognized revenue, by month** — the paid charges as they read
      *as of now*, grouped by the month each recognition took effect at.
      The charges are temporal (`Finance.Charge`), so this chart and the
      board's time travel share one grammar: revenue-at-T is the same
      containment read the board does, pinned to a different instant.
    * **The forecast, next four weeks** — every visit still `:scheduled`
      in the window, priced from its catalogue entry and weighted by the
      completion rate history teaches for its type, clinician and weekday
      (`Finance.Forecast`). The line is expected revenue per week; it is a
      claim about evidence, and the rates table below shows the evidence.
    * **Completion rates** — observed terminal visits and completion share
      per catalogue type, plus the clinic-wide row the fallback chain
      floors at.

  Read-only by design: money is written by the lifecycle (`:complete`
  recognizes a charge in the same transaction), never by this page.
  """

  use ClinicDemoWeb, :live_view

  alias ClinicDemo.Finance
  alias ClinicDemo.Finance.Forecast
  alias ClinicDemoWeb.A2ui.SurfaceChrome

  @surface_id "clinic_revenue"

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
      |> load_revenue()

    {:ok, SurfaceChrome.mount_presence(socket, @surface_id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-col gap-6">
      <header>
        <h1 class="text-2xl font-display">Revenue</h1>
        <p class="text-foreground/70">
          What completed visits have recognized, and what the schedule says is coming. All times UTC.
        </p>
      </header>

      <section aria-label="Headline numbers" class="grid grid-cols-2 gap-3 lg:grid-cols-4">
        <.kpi
          label="Recognized this month"
          value={money(@month_to_date)}
          sub={"#{@month_count} charges"}
        />
        <.kpi label="Trailing six months" value={money(@trailing_total)} sub="paid charges" />
        <.kpi
          label="Scheduled, next four weeks"
          value={"#{@scheduled_count}"}
          sub="visits on the books"
        />
        <.kpi label="Four-week forecast" value={money(@forecast_total)} sub="expected revenue" />
      </section>

      <section
        aria-label="Revenue by month"
        class="rounded-base border-2 border-border bg-secondary-background p-4 shadow-shadow"
      >
        <h2 class="mb-1 text-lg font-heading">Recognized revenue by month</h2>
        <p class="mb-3 text-sm text-foreground/60">
          Paid charges, by the month each visit was written up. As-of reads over the temporal charges — the board's time travel, pointed at money.
        </p>
        <svg
          viewBox={"0 0 #{@width} #{@bar_height + 24}"}
          class="w-full"
          role="img"
          aria-label="Bar chart of recognized revenue per month for the last six months and the current month"
        >
          <.month_bars months={@months} ceiling={@bar_ceiling} />
        </svg>
      </section>

      <div class="flex flex-col gap-6 lg:flex-row lg:items-start">
        <section
          aria-label="Forecast"
          class="rounded-base border-2 border-border bg-secondary-background p-4 shadow-shadow lg:w-1/2"
        >
          <h2 class="mb-1 text-lg font-heading">Forecast — next four weeks</h2>
          <p class="mb-3 text-sm text-foreground/60">
            Scheduled visits priced at their catalogue entry, weighted by the completion rate history teaches. Expected revenue per week.
          </p>
          <svg
            viewBox={"0 0 #{@width} #{@line_height + 30}"}
            class="w-full"
            role="img"
            aria-label="Line chart of expected revenue per week for the next four weeks"
          >
            <.forecast_line weeks={@weeks} ceiling={@line_ceiling} />
          </svg>
        </section>

        <section
          aria-label="Completion rates"
          class="rounded-base border-2 border-border bg-secondary-background p-4 shadow-shadow lg:w-1/2"
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
    """
  end

  # --- components ------------------------------------------------------------

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil

  defp kpi(assigns) do
    ~H"""
    <div class="rounded-base border-2 border-border bg-main p-3 text-main-foreground shadow-shadow">
      <div class="text-xs font-base opacity-80">{@label}</div>
      <div class="mt-1 text-xl font-display">{@value}</div>
      <div :if={@sub} class="text-xs font-base opacity-80">{@sub}</div>
    </div>
    """
  end

  attr :months, :list, required: true
  attr :ceiling, :any, required: true

  # The bars. Static class-free SVG — fills are plain attributes, so the
  # CSP has nothing to say and Tailwind nothing to scan. Heights scale
  # against a clean ceiling (the max month, rounded up), never against the
  # data's own wiggle.
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
      <% h = scaled_height(row.total, @ceiling, @bar_height - 20) %>
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

  # The forecast line: one point per week, Monday-anchored. Points sit on
  # the scaled expected value; labels carry the week and the number.
  defp forecast_line(assigns) do
    %{weeks: weeks, ceiling: ceiling} = assigns
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

    assigns =
      assigns
      |> assign(:points, points)
      |> assign(:slot_w, slot_w)
      |> assign(:baseline, @line_height)

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
      points={Enum.map_join(@points, " ", fn {x, y, _} -> "#{x},#{y}" end)}
      fill="none"
      stroke="currentColor"
      stroke-width="2.5"
    />
    <%= for {x, y, week} <- @points do %>
      <circle cx={x} cy={y} r="4" class="fill-yellow" stroke="currentColor" stroke-width="2" />
      <text x={x} y={y - 9} text-anchor="middle" class="fill-current text-[11px] font-base">
        {money(week.expected)}
      </text>
      <text x={x} y={@baseline + 16} text-anchor="middle" class="fill-current text-[11px] font-base">
        wk {Calendar.strftime(week.week_start, "%d %b")}
      </text>
    <% end %>
    """
  end

  # --- data --------------------------------------------------------------------

  # One pass over the three reads the page is: the money as of now, the
  # history's outcomes, and the forward window. Demo scale — the whole
  # book once per mount, like the Day view.
  defp load_revenue(socket) do
    months = Finance.revenue_by_month(7)

    outcomes = Finance.historical_outcomes()
    rates = Forecast.build_rates(outcomes)

    type_names =
      ClinicDemo.Scheduling.list_appointment_types!(authorize?: false)
      |> Map.new(&{&1.id, &1.name})

    scheduled = Finance.scheduled_with_prices(4)
    weeks = Forecast.weekly(scheduled, rates, Date.utc_today())

    %{month: _, total: month_to_date, count: month_count} = List.last(months)

    trailing_total =
      months
      |> Enum.drop(-1)
      |> Enum.reduce(Decimal.new(0), &Decimal.add(&2, &1.total))

    forecast_total = Enum.reduce(weeks, Decimal.new(0), &Decimal.add(&2, &1.expected))

    socket
    |> assign(:months, months)
    |> assign(:bar_ceiling, clean_ceiling(Enum.map(months, & &1.total), 5_000))
    |> assign(:month_to_date, month_to_date)
    |> assign(:month_count, month_count)
    |> assign(:trailing_total, trailing_total)
    |> assign(:scheduled_count, length(scheduled))
    |> assign(:weeks, weeks)
    |> assign(:line_ceiling, clean_ceiling(Enum.map(weeks, & &1.expected), 1_000))
    |> assign(:forecast_total, forecast_total)
    |> assign(:rate_table, Forecast.rate_table(rates, type_names))
  end

  # --- helpers -------------------------------------------------------------------

  # The charts' y-ceiling: the largest value rounded UP to a clean step, so
  # a data wiggle never redraws the axis. At least one step — an empty
  # ledger renders a flat, honest zero.
  defp clean_ceiling(values, step) do
    top =
      values
      |> Enum.map(&Decimal.to_float/1)
      |> Enum.max(fn -> 0 end)

    steps = max(1, Float.ceil(top / step))
    Decimal.from_float(steps * step)
  end

  defp scaled_height(value, ceiling, height) do
    v = Decimal.to_float(value)
    m = Decimal.to_float(ceiling)

    if m <= 0, do: 0, else: max(0, v / m * height)
  end

  # Whole dollars with thousands separators — the demo's prices are whole
  # and the charts read better without cents. A Decimal in, a string out.
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

  # A completion share as a rounded percentage; nil (no observations) is an
  # em dash, honestly.
  defp percent(nil), do: "—"

  defp percent(%Decimal{} = rate) do
    rate
    |> Decimal.mult(100)
    |> Decimal.round(0)
    |> Decimal.to_string()
    |> Kernel.<>("%")
  end
end
