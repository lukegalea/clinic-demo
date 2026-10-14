defmodule ClinicDemo.Scheduling.Preparations.ScheduledFromReadInstant do
  @moduledoc """
  Filters a query to the two days the board runs: the read instant's own day
  ("the day in flight") and the next one ("the day being booked") — where
  "today" is `as_of`'s date for a time-travel read and the wall clock for a
  present-tense one, the same default the temporal machinery itself
  resolves.

  The board's scope: the process *around the instant being read*. The
  finance seeds stand up six months of history and a three-week forward
  backlog around the demo world, and a lane board that renders every card
  in the book is a half-megapixel scroll — the working board is the day's
  visits and tomorrow's bookings, in their lanes. The rest of the schedule
  stays on the schedule (its window read), the deep past in the revenue
  view (its as-of reads).
  """

  use Ash.Resource.Preparation

  # Temporal safety (declared and meant): the window is pinned to the READ's
  # own instant — `query.as_of` when the read is pinned, now only as the
  # machinery's own default — so a time-travel board answers about the two
  # days around that instant, never about "now".
  @impl true
  def temporal_safe?(_opts), do: true

  @impl true
  def prepare(query, _opts, _context) do
    instant = Ash.Temporal.resolve_read_as_of(query.as_of) || DateTime.utc_now()
    window_start = DateTime.new!(DateTime.to_date(instant), ~T[00:00:00], "Etc/UTC")
    window_end = DateTime.add(window_start, 2, :day)

    Ash.Query.filter(query, scheduled_at >= ^window_start and scheduled_at < ^window_end)
  end
end
