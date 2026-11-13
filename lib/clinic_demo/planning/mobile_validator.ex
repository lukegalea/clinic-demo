defmodule ClinicDemo.Planning.MobileValidator do
  @moduledoc """
  The independent Elixir validator for `mobile_visits`: it re-checks a decoded
  candidate against the **domain-level problem** and shares nothing with the model,
  the checker or `ClinicDemo.Planning.MobileLowering`.

  It reads instants, minutes and place ids. It has no minute grid, no location
  indices and no model nodes, so a bug in the lowering (an off-by-one in a flattened
  matrix index, a swapped window bound) cannot also be a bug here. Overlap is the
  generic `AshPlanning.Validators.Intervals` over plain unix seconds; every other
  rule is written out below in the vocabulary of the clinic.

      validate(problem, assignments) :: :ok | {:error, [AshPlanning.Violation.t()]}

  `problem` is the payload's `"problem"` map (string keys); `assignments` is
  `MobileLowering.decode/2`'s output: `"stops"` (each visit's start), `"legs"` and
  `"route_ends_at"`. The validator ignores the candidate's own `"legs"`: it derives
  the travel from the time order of the stops and the pinned commitments and the
  problem's travel pairs.

  ## Rules (half-open intervals throughout)

    * every requested visit is scheduled exactly once, at the place requested;
    * a visit starts no earlier than its window opens and, service included
      (`service_minutes`: booked minutes plus access buffer), ends no later than it
      closes;
    * no two stops, and no stop and pinned commitment, overlap;
    * **travel**: the vet starts the day at the start location at the working
      window's open, visits and commitments in time order, and ends at the end
      location. Between each consecutive pair the gap holds at least the travel time
      between their places: zero for the same place, the pair's duration otherwise. A
      pair marked unreachable can never be used (never zero-cost) and a pair the
      problem does not hold is an unknown travel time, not zero;
    * the vet is back by the working window's close;
    * no service, and no travel interval (the leg arriving exactly when what it leads
      to starts), overlaps blocked time.

  Violation codes: `:unknown_visit`, `:visit_unaccounted`, `:visit_double_scheduled`,
  `:wrong_location`, `:stop_duration_mismatch`, `:outside_window`, `:overlap`,
  `:unreachable_leg`, `:travel_time_unknown`, `:insufficient_travel`,
  `:outside_work_hours`, `:in_blocked_time`, `:travel_in_blocked_time`,
  `:route_unreadable`. Subjects are ids; details are structural.
  """

  @behaviour AshPlanning.Validator

  alias AshPlanning.Validators.{Intervals, Support}
  alias AshPlanning.Violation

  @impl true
  def validate(problem, assignments) do
    visits = Map.new(list(problem, "visits"), &{&1["id"], &1})
    stops = list(assignments, "stops")

    with {:ok, work_from} <- instant(problem["work_from"]),
         {:ok, work_to} <- instant(problem["work_to"]),
         {:ok, route_end} <- instant(assignments["route_ends_at"]) do
      day = %{work_from: work_from, work_to: work_to, route_end: route_end}

      violations =
        accounting(visits, stops) ++
          stop_violations(visits, stops) ++
          calendar_violations(problem, visits, stops, day)

      Support.result(violations)
    else
      _ -> Support.result([Violation.new(:route_unreadable, "route", %{})])
    end
  end

  # ── every visit exactly once ───────────────────────────────────────────────

  defp accounting(visits, stops) do
    ids = Enum.map(stops, & &1["visit_request_id"])
    unknown = for id <- Enum.uniq(ids), not Map.has_key?(visits, id), do: id
    twice = ids |> Enum.frequencies() |> Enum.filter(fn {_id, n} -> n > 1 end)
    unaccounted = for {id, _v} <- visits, id not in ids, do: id

    Enum.map(unknown, &Violation.new(:unknown_visit, &1, %{})) ++
      Enum.map(twice, fn {id, n} -> Violation.new(:visit_double_scheduled, id, %{times: n}) end) ++
      Enum.map(unaccounted, &Violation.new(:visit_unaccounted, &1, %{}))
  end

  # ── each stop on its own: place, duration, window ──────────────────────────

  defp stop_violations(visits, stops) do
    Enum.flat_map(stops, fn stop ->
      case visits[stop["visit_request_id"]] do
        nil -> []
        visit -> one_stop(stop, visit)
      end
    end)
  end

  defp one_stop(stop, visit) do
    id = visit["id"]

    with {:ok, starts_at} <- instant(stop["starts_at"]),
         {:ok, stop_end} <- instant(stop["ends_at"]),
         {:ok, window_from} <- instant(visit["window_from"]),
         {:ok, window_to} <- instant(visit["window_to"]) do
      ends_at = DateTime.add(starts_at, visit["service_minutes"] * 60, :second)

      place =
        if stop["location_id"] == visit["location_id"],
          do: [],
          else: [
            Violation.new(:wrong_location, id, %{
              requested: visit["location_id"],
              planned: stop["location_id"]
            })
          ]

      duration =
        if DateTime.compare(stop_end, ends_at) == :eq,
          do: [],
          else: [
            Violation.new(:stop_duration_mismatch, id, %{
              expected_minutes: visit["service_minutes"]
            })
          ]

      window =
        if DateTime.compare(starts_at, window_from) != :lt and
             DateTime.compare(ends_at, window_to) != :gt,
           do: [],
           else: [Violation.new(:outside_window, id, %{})]

      place ++ duration ++ window
    else
      _ -> [Violation.new(:outside_window, id, %{reason: :unreadable_instant})]
    end
  end

  # ── the vet's day: overlap, travel, hours, blocked time ────────────────────

  defp calendar_violations(problem, visits, stops, day) do
    scheduled = scheduled_visits(visits, stops)
    pinned = pinned_commitments(problem)
    blocked = blocked_intervals(problem)
    travel = travel_table(problem)

    items = Enum.sort_by(scheduled ++ pinned, &{&1.from, &1.to, &1.id})

    start_item = %{
      id: "start",
      from: DateTime.to_unix(day.work_from),
      to: DateTime.to_unix(day.work_from),
      location: problem["start_location_id"]
    }

    end_item = %{
      id: "end",
      from: DateTime.to_unix(day.route_end),
      to: DateTime.to_unix(day.route_end),
      location: problem["end_location_id"]
    }

    path = [start_item] ++ items ++ [end_item]

    legs =
      path
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] ->
        {from, to, leg_minutes(travel, from.location, to.location)}
      end)

    overlap(items) ++
      leg_violations(legs) ++
      hours_violations(day) ++
      blocked_violations(scheduled, legs, blocked)
  end

  defp scheduled_visits(visits, stops) do
    for stop <- stops,
        visit = visits[stop["visit_request_id"]],
        not is_nil(visit),
        {:ok, starts_at} <- [instant(stop["starts_at"])] do
      from = DateTime.to_unix(starts_at)

      %{
        id: visit["id"],
        from: from,
        to: from + visit["service_minutes"] * 60,
        location: visit["location_id"],
        kind: :visit
      }
    end
  end

  defp pinned_commitments(problem) do
    for c <- list(problem, "commitments"),
        {:ok, starts_at} <- [instant(c["starts_at"])],
        {:ok, ends_at} <- [instant(c["ends_at"])] do
      %{
        id: c["id"],
        from: DateTime.to_unix(starts_at),
        to: DateTime.to_unix(ends_at),
        location: c["location_id"],
        kind: :commitment
      }
    end
  end

  defp blocked_intervals(problem) do
    for b <- list(problem, "blocked"),
        {:ok, starts_at} <- [instant(b["starts_at"])],
        {:ok, ends_at} <- [instant(b["ends_at"])] do
      %{
        id: "blocked:#{b["id"]}",
        start: DateTime.to_unix(starts_at),
        end: DateTime.to_unix(ends_at)
      }
    end
  end

  # `%{{from, to} => :unreachable | minutes}`; a pair missing from the problem is
  # absent, and `leg_minutes/3` reads absence as unknown.
  defp travel_table(problem) do
    Map.new(list(problem, "travel"), fn pair ->
      value = if pair["reachable"], do: pair["minutes"], else: :unreachable
      {{pair["from"], pair["to"]}, value}
    end)
  end

  # Travel between two places: none at all for the same place; otherwise the pair.
  defp leg_minutes(_travel, same, same), do: 0

  defp leg_minutes(travel, from, to) do
    case Map.fetch(travel, {from, to}) do
      {:ok, :unreachable} -> :unreachable
      {:ok, minutes} when is_integer(minutes) and minutes >= 0 -> minutes
      _ -> :unknown
    end
  end

  defp overlap(items) do
    intervals = for i <- items, do: %{id: i.id, start: i.from, end: i.to}

    case Intervals.validate(%{}, intervals) do
      :ok -> []
      {:error, found} -> found
    end
  end

  defp leg_violations(legs) do
    Enum.flat_map(legs, fn {from, to, minutes} -> leg_violation(from, to, minutes) end)
  end

  defp leg_violation(from, to, :unreachable) do
    [
      Violation.new(:unreachable_leg, "#{from.id}->#{to.id}", %{
        from: from.location,
        to: to.location
      })
    ]
  end

  defp leg_violation(from, to, :unknown) do
    [
      Violation.new(:travel_time_unknown, "#{from.id}->#{to.id}", %{
        from: from.location,
        to: to.location
      })
    ]
  end

  defp leg_violation(from, to, minutes) do
    subject = "#{from.id}->#{to.id}"
    available = div(to.from - from.to, 60)

    if to.from - from.to >= minutes * 60,
      do: [],
      else: [
        Violation.new(:insufficient_travel, subject, %{
          needed_minutes: minutes,
          available_minutes: available
        })
      ]
  end

  defp hours_violations(day) do
    if DateTime.compare(day.route_end, day.work_to) == :gt,
      do: [Violation.new(:outside_work_hours, "end", %{})],
      else: []
  end

  # Service intervals against blocked time, and every leg's travel interval (arriving
  # exactly when what it leads to starts) against blocked time.
  defp blocked_violations(scheduled, legs, blocked) do
    service =
      case Intervals.validate(
             %{pinned: blocked},
             for(s <- scheduled, do: %{id: s.id, start: s.from, end: s.to})
           ) do
        :ok -> []
        {:error, found} -> Enum.map(found, &rename_blocked/1)
      end

    travel =
      for {from, to, minutes} <- legs,
          is_integer(minutes) and minutes > 0,
          interval = %{id: "#{from.id}->#{to.id}", start: to.from - minutes * 60, end: to.from},
          b <- blocked,
          interval.start < b.end and b.start < interval.end do
        Violation.new(:travel_in_blocked_time, interval.id, %{blocked: b.id})
      end

    service ++ travel
  end

  defp rename_blocked(%{code: :overlaps_pinned} = v), do: %{v | code: :in_blocked_time}
  defp rename_blocked(v), do: v

  # ── helpers ────────────────────────────────────────────────────────────────

  defp list(map, key), do: Map.get(map, key) || []

  defp instant(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> {:ok, dt}
      error -> error
    end
  end

  defp instant(%DateTime{} = dt), do: {:ok, dt}
  defp instant(_other), do: :error
end
