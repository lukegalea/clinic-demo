defmodule ClinicDemoWeb.A2ui.AsOfSurface do
  @moduledoc """
  The board's as-of surface builder: time travel as a containment read.

  `ClinicDemoWeb.A2ui.BoardUI` is a read-action surface over
  `ClinicDemo.Scheduling.Appointment`, which is a temporal resource — so
  "the board as it was at instant T" is the same surface declaration with
  its records read `as_of` T, nothing more. This module produces that wire
  payload, mirroring `AshA2ui.Info.build_surface/2` (resolve → expand the
  lane sections → load records → encode) with two deliberate differences:

    * **The reads are pinned to the instant.** Every appointment read runs
      with `as_of:`, which the temporal data layer turns into period
      containment — one version per appointment, the one valid at T. The
      cells are the `board_lane` calculation's declared stages crossed with
      the `triage_category` calculation's declared rows (the sections have
      no source, so expanding them reads nothing and has no instant to
      pin), and each cell's `board_lane == <stage>` and
      `triage_category == <row>` filters evaluate against the historical
      row's status and triage urgency, so cards land in the cell they were
      in at T with no second implementation of the board logic.

    * **The surface is view-only.** A view of the past is not an operating
      surface: an action clicked on a historical card would run against the
      live record — silently mutating the present while looking at the
      past. The resolved view's row actions are stripped before encoding,
      so the wire carries no invoke envelopes at all (not merely hidden
      ones).

  Threading choice: `AshA2ui.LiveRenderer`'s `:surface_fn` is the seam the
  LiveView already calls through (`defoverridable mount/3` plus the
  compile-time `:surface_fn` option), and the as-of instant travels in the
  closure that BoardLive installs for that seam. `AshA2ui.Info
  .build_surface/2` itself builds its read opts from a fixed allowlist
  (domain/actor/tenant/authorize?), so threading `as_of` through the stock
  builder is not possible without an upstream change; this module keeps the
  divergence small, named, and pinned next to the ash_a2ui version in
  mix.lock.

  `parse/1` is the `?as_of=` contract: ISO 8601 (what this module's links
  carry, always UTC) or a `datetime-local` string (what the control posts,
  read as UTC per the app's all-times-UTC convention). Anything unparseable
  means "present" — the DayLive `?date=` convention.
  """

  alias Ash.Resource.Info, as: ResourceInfo
  alias AshA2ui.{ContextRunner, Info, ResolvedView, Sections}

  @type as_of :: DateTime.t()

  @doc """
  Builds the surface messages for `ui` as of `opts[:as_of]`.
  """
  @spec build(module, keyword) :: [map]
  def build(ui, opts) do
    {as_of, opts} = Keyword.pop!(opts, :as_of)

    view =
      ui
      |> ResolvedView.resolve(opts)
      |> Sections.expand!(opts)
      |> view_only()

    selected = ContextRunner.selected(view, opts[:context_state])

    records =
      Map.new(view.tables, fn table ->
        {table.name, load_table!(view, table, selected, as_of, opts)}
      end)

    # The stock builder also loads option lists (relationship selects,
    # pickers) and context/detail values here. The board surface declares
    # neither a form nor contexts, so both legs are empty by construction;
    # if the board ever grows a form, this builder needs the option leg
    # threaded with the same as_of before that form can ship.
    opts = Keyword.put(opts, :options, %{})

    Info.encoder(view).encode_surface(view, records, opts)
  end

  @doc """
  The `?as_of=` parameter: `{:ok, DateTime}` in UTC, or `:error` for
  absent/unparseable — both of which mean "the present".
  """
  @spec parse(term) :: {:ok, as_of} | :error
  def parse(nil), do: :error

  def parse(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        {:ok, datetime}

      _not_a_full_iso8601 ->
        # datetime-local posts "YYYY-MM-DDTHH:MM[:SS]" without a zone; the
        # app's convention (the agent clock, the surfaces' stamps) is UTC.
        # Regex.run/2 returns the full match first, then the captures.
        with [_match, date, time] <-
               Regex.run(~r/^(\d{4}-\d{2}-\d{2})T(\d{2}:\d{2}(?::\d{2})?)$/, value),
             {:ok, day} <- Date.from_iso8601(date),
             {:ok, time_of_day} <- to_time(time) do
          {:ok, DateTime.new!(day, time_of_day, "Etc/UTC")}
        else
          _unparseable -> :error
        end
    end
  rescue
    _argument_error -> :error
  end

  defp to_time(<<_::binary-size(5)>> = hh_mm), do: Time.from_iso8601(hh_mm <> ":00")
  defp to_time(<<_::binary-size(8)>> = hh_mm_ss), do: Time.from_iso8601(hh_mm_ss)
  defp to_time(_other), do: :error

  # One read per lane table, as of the instant. Sectionless tables (none on
  # the board today) take the same path with an empty scope.
  defp load_table!(view, table, selected, as_of, opts) do
    case ContextRunner.table_scope(view, table, selected) do
      :require_unmet ->
        []

      {:ok, scope} ->
        # The instant goes in at for_read, not after it. for_read runs the
        # action's preparations on the spot, and the board's day window
        # (ScheduledFromReadInstant) reads `query.as_of` to pick its day;
        # set later, the preparation saw nil and windowed on the wall clock,
        # so every past day read as an empty board. for_read stores it as
        # shared context, so the loads thread it too. Handing it to
        # Ash.read!/2 instead would be silently dropped.
        table.resource
        |> Ash.Query.for_read(table.read_action, %{}, as_of: as_of)
        |> ContextRunner.apply_scope(scope)
        |> Ash.Query.load(table.loads)
        |> Ash.read!(read_opts(view, opts))
    end
  end

  # The same read opts `AshA2ui.Info` builds, plus the instant.
  defp read_opts(view, opts) do
    [
      domain: opts[:domain] || ResourceInfo.domain(view.resource),
      actor: opts[:actor],
      tenant: opts[:tenant],
      authorize?: Keyword.get(opts, :authorize?, true)
    ]
  end

  # Strips the operating affordances: no row actions, no action metadata,
  # no refresh targets. What remains is a sectioned, read-only table.
  defp view_only(%ResolvedView{} = view) do
    tables = Enum.map(view.tables, &Map.put(&1, :row_actions, []))

    %{view | tables: tables, row_actions: [], actions: %{}, refreshes: %{}}
  end
end
