defmodule ClinicDemo.Planning.MobileExplain do
  @moduledoc """
  Why a mobile visit was refused, in the clinic's own vocabulary.

  A mobile-visits run that is `:infeasible` has no candidate to read, so this reads
  the **problem** instead: for each requested visit, on its own, around the
  veterinarian's pinned commitments and blocked time (not around the other visits),
  and says which of these is true:

    * `:window_too_short` — the window cannot hold the visit's service time;
    * `:no_free_time` — the calendar itself leaves no room in the window: every
      start overlaps a commitment or blocked time, or the working hours;
    * `:unreachable` — every start that the calendar allows needs a leg the travel
      matrix marks unreachable;
    * `:travel_conflict` — the visit **fits its window** but the travel into it from
      what comes before, or out to what comes after, does not fit between the
      pinned commitments. `blocking` names the commitments (appointment ids) whose
      end or start the travel runs into;
    * `:fits_alone` — the visit could be placed on its own; it is refused only
      because of the other requested visits competing for the same day.

  This is a diagnosis, not a second solver: it never decides what a plan is. It reads
  the same domain-level `"problem"` the independent validator reads, in whole-minute
  steps, and shares nothing with the model or its lowering.
  """

  @doc """
  The refusal reason for every visit of `problem` (the payload's `"problem"` map):
  `[%{visit_request_id, reason, blocking}]`, in the problem's order.
  """
  @spec refusals(map()) :: [map()]
  def refusals(problem) do
    context = context(problem)

    for visit <- problem["visits"] || [] do
      {reason, blocking} = diagnose(visit, context)
      %{visit_request_id: visit["id"], reason: reason, blocking: blocking}
    end
  end

  defp context(problem) do
    %{
      work_from: unix(problem["work_from"]),
      work_to: unix(problem["work_to"]),
      start_location: problem["start_location_id"],
      end_location: problem["end_location_id"],
      commitments:
        problem["commitments"]
        |> Kernel.||([])
        |> Enum.map(
          &%{
            id: &1["id"],
            from: unix(&1["starts_at"]),
            to: unix(&1["ends_at"]),
            location: &1["location_id"]
          }
        )
        |> Enum.sort_by(& &1.from),
      blocked:
        for(
          b <- problem["blocked"] || [],
          do: %{from: unix(b["starts_at"]), to: unix(b["ends_at"])}
        ),
      travel:
        Map.new(problem["travel"] || [], fn p ->
          {{p["from"], p["to"]}, if(p["reachable"], do: p["minutes"], else: :unreachable)}
        end)
    }
  end

  defp diagnose(visit, context) do
    from = unix(visit["window_from"])
    to = unix(visit["window_to"])
    seconds = visit["service_minutes"] * 60

    starts = if to - from >= seconds, do: Enum.to_list(from..(to - seconds)//60), else: []

    free = Enum.filter(starts, &calendar_free?(&1, &1 + seconds, context))

    cond do
      starts == [] ->
        {:window_too_short, []}

      free == [] ->
        {:no_free_time, []}

      Enum.any?(free, &travel_ok?(&1, &1 + seconds, visit, context)) ->
        {:fits_alone, []}

      Enum.all?(free, &unreachable_leg?(&1, &1 + seconds, visit, context)) ->
        {:unreachable, []}

      true ->
        {:travel_conflict, blocking(free, seconds, context)}
    end
  end

  # The calendar leaves the interval alone: working hours, commitments, blocked time.
  defp calendar_free?(from, to, context) do
    from >= context.work_from and to <= context.work_to and
      not Enum.any?(context.commitments ++ context.blocked, &(from < &1.to and &1.from < to))
  end

  defp travel_ok?(from, to, visit, context) do
    {before, next} = neighbours(from, to, context)

    leg_fits?(before.to, from, before.location, visit["location_id"], context) and
      leg_fits?(to, next.from, visit["location_id"], next.location, context)
  end

  defp leg_fits?(left, right, from_location, to_location, context) do
    case minutes(context.travel, from_location, to_location) do
      minutes when is_integer(minutes) ->
        right - left >= minutes * 60 and not travel_blocked?(right, minutes, context)

      _ ->
        false
    end
  end

  defp unreachable_leg?(from, to, visit, context) do
    {before, next} = neighbours(from, to, context)

    :unreachable in [
      minutes(context.travel, before.location, visit["location_id"]),
      minutes(context.travel, visit["location_id"], next.location)
    ]
  end

  # The commitment (or the start/end of the day) just before and just after a slot.
  defp neighbours(from, to, context) do
    before =
      context.commitments
      |> Enum.filter(&(&1.to <= from))
      |> Enum.max_by(& &1.to, fn ->
        %{to: context.work_from, location: context.start_location}
      end)

    next =
      context.commitments
      |> Enum.filter(&(&1.from >= to))
      |> Enum.min_by(& &1.from, fn ->
        %{from: context.work_to, location: context.end_location}
      end)

    {before, next}
  end

  # The commitments the travel runs into: for each free slot, the neighbours whose
  # leg does not fit.
  defp blocking(free, seconds, context) do
    free
    |> Enum.flat_map(fn from ->
      {before, next} = neighbours(from, from + seconds, context)
      Enum.filter([before, next], &Map.has_key?(&1, :id))
    end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp travel_blocked?(arrival, minutes, context) do
    start = arrival - minutes * 60
    minutes > 0 and Enum.any?(context.blocked, &(start < &1.to and &1.from < arrival))
  end

  defp minutes(_travel, same, same), do: 0
  defp minutes(travel, from, to), do: Map.get(travel, {from, to}, :unknown)

  defp unix(iso) do
    {:ok, at, _} = DateTime.from_iso8601(iso)
    DateTime.to_unix(at)
  end
end
