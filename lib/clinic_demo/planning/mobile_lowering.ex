defmodule ClinicDemo.Planning.MobileLowering do
  @moduledoc """
  Facts in, `mobile_visits.mzn` data out, and the model's answer back to
  domain-level stops and legs.

  This is the **model-lowering** half of the mobile-visits plan and the only module
  that knows the model's conventions:

    * time is whole minutes after 00:00 UTC of the plan's day, half-open `[from, to)`;
    * a visit's window is rounded **inward** (start up, end down) and a pinned
      commitment or blocked interval **outward** (start down, end up), so rounding can
      never admit a plan the exact times would refuse;
    * places are indexed from 1 in the order of the `"locations"` ids recorded in the
      payload; the travel matrix is flattened row-major `(from - 1) * n_loc + to`;
    * visits and commitments are indexed from 1 in the order of their `"ids"` arrays,
      and the model's nodes are visits, then commitments, then the start and end of
      the day.

  **An unreachable pair is never cheap.** It lowers to `reach = false` *and* a
  travel time of a whole day, so the model both forbids the leg and could not price
  it at zero if the reachability test were ever edited out. A pair the matrix does not
  hold never gets here (the snapshot builder makes the run `:needs_input`); if one
  does, lowering fails rather than guessing.

  `ClinicDemo.Planning.MobileValidator` shares none of this: it reads `"problem"` (the
  same facts at domain level: instants, minutes, place ids) and the decoded stops.
  """

  @horizon 1_440

  # The objective weights are data to the model, so a reviewed change here is not a
  # model edit. Moving a visit off the start it was already booked at costs more than
  # fifty minutes of driving; the minute the vet is back is a tie-breaker.
  @weights %{"w_travel" => 10, "w_move" => 500, "w_finish" => 1}

  @doc "Minutes in the plan's day."
  @spec horizon() :: pos_integer()
  def horizon, do: @horizon

  @doc """
  Lowers facts to the model's data.

  Returns `{:ok, %{"data" => data, "ids" => ids}}`. `"ids"` maps each model index
  back to a record id: `"visits"` (visit request ids), `"commitments"` (appointment
  ids) and `"locations"` (service location ids).
  """
  @spec lower(map()) :: {:ok, map()} | {:error, term()}
  def lower(%{} = facts) do
    locations = facts.involved_locations
    index = locations |> Enum.with_index(1) |> Map.new()
    day_start = facts.effective_at

    with {:ok, matrix} <- matrix(facts, locations) do
      visits = facts.visits
      commitments = facts.commitments
      blocks = facts.blocks

      data =
        Map.merge(@weights, %{
          "horizon" => @horizon,
          "work_from" => floor_minute(facts.work_window.from, day_start),
          "work_to" => ceil_minute(facts.work_window.to, day_start),
          "n_loc" => length(locations),
          "tt" => matrix.tt,
          "reach" => matrix.reach,
          "start_loc" => Map.fetch!(index, facts.start_location_id),
          "end_loc" => Map.fetch!(index, facts.end_location_id),
          "n_visit" => length(visits),
          "v_from" => pad(Enum.map(visits, &ceil_minute(&1.window_from, day_start)), 0),
          "v_to" => pad(Enum.map(visits, &floor_minute(&1.window_to, day_start)), 0),
          "v_dur" => pad(Enum.map(visits, & &1.service_minutes), 0),
          "v_loc" => pad(Enum.map(visits, &Map.fetch!(index, &1.location_id)), 0),
          "v_prev" =>
            pad(
              Enum.map(visits, fn v ->
                if v.previous_starts_at,
                  do: exact_minute(v.previous_starts_at, day_start),
                  else: -1
              end),
              0
            ),
          "n_commit" => length(commitments),
          "c_from" => pad(Enum.map(commitments, &floor_minute(&1.starts_at, day_start)), 0),
          "c_to" => pad(Enum.map(commitments, &ceil_minute(&1.ends_at, day_start)), 0),
          "c_loc" => pad(Enum.map(commitments, &Map.fetch!(index, &1.location_id)), 0),
          "n_block" => length(blocks),
          "b_from" => pad(Enum.map(blocks, &floor_minute(&1.starts_at, day_start)), 0),
          "b_to" => pad(Enum.map(blocks, &ceil_minute(&1.ends_at, day_start)), 0)
        })

      {:ok,
       %{
         "data" => data,
         "ids" => %{
           "visits" => Enum.map(visits, & &1.id),
           "commitments" => Enum.map(commitments, & &1.id),
           "locations" => locations
         }
       }}
    end
  end

  # The flattened travel matrix over the places in play: same place is zero and
  # reachable, a stored pair is its minutes, an unreachable pair is a whole day and
  # not reachable, a missing pair is an error.
  defp matrix(facts, locations) do
    cells =
      for a <- locations, b <- locations do
        cond do
          a == b ->
            {:ok, {0, true}}

          is_nil(facts.matrix) ->
            {:error, {:travel_pair_missing, a, b}}

          true ->
            case Map.fetch(facts.matrix.pairs, {a, b}) do
              {:ok, %{reachable: true, minutes: minutes}} -> {:ok, {minutes, true}}
              {:ok, %{reachable: false}} -> {:ok, {@horizon, false}}
              :error -> {:error, {:travel_pair_missing, a, b}}
            end
        end
      end

    case Enum.find(cells, &match?({:error, _}, &1)) do
      {:error, _} = error ->
        error

      nil ->
        pairs = Enum.map(cells, fn {:ok, cell} -> cell end)
        {:ok, %{tt: Enum.map(pairs, &elem(&1, 0)), reach: Enum.map(pairs, &elem(&1, 1))}}
    end
  end

  @doc """
  Reads one model answer (`"st"`, `"succ"`, `"tin"`) back to domain-level stops and
  legs:

      %{
        "stops" => [%{"visit_request_id", "starts_at", "ends_at", "booked_minutes",
                      "service_minutes", "location_id", "order"}],
        "legs" => [%{"from", "to", "from_location_id", "to_location_id", "minutes",
                     "departs_at", "arrives_at"}],
        "route_ends_at" => iso8601
      }

  Instants are ISO-8601 strings. Legs are the explicit travel intervals, in route
  order from the start of the day to its end.
  """
  @spec decode(map(), map()) :: {:ok, map()} | {:error, term()}
  def decode(%{"ids" => ids, "data" => data, "problem" => problem}, %{} = answer) do
    n_visit = length(ids["visits"])
    n_commit = length(ids["commitments"])
    n_node = n_visit + n_commit + 2
    start_node = n_visit + n_commit + 1
    end_node = n_visit + n_commit + 2

    with {:ok, day} <- Date.from_iso8601(problem["day"]),
         st when is_list(st) and length(st) == n_node <- answer["st"],
         succ when is_list(succ) and length(succ) == n_node <- answer["succ"],
         tin when is_list(tin) and length(tin) == n_node <- answer["tin"],
         {:ok, route} <- route(succ, start_node, end_node, n_node) do
      day_start = DateTime.new!(day, ~T[00:00:00], "Etc/UTC")
      booked = Map.new(problem["visits"], &{&1["id"], &1["booked_minutes"]})

      labels =
        Enum.map(1..n_node, fn
          node when node <= n_visit ->
            "visit_request:#{Enum.at(ids["visits"], node - 1)}"

          node when node <= n_visit + n_commit ->
            "appointment:#{Enum.at(ids["commitments"], node - n_visit - 1)}"

          ^start_node ->
            "start"

          ^end_node ->
            "end"
        end)

      node_location = fn
        node when node <= n_visit -> Enum.at(data["v_loc"], node - 1)
        node when node <= n_visit + n_commit -> Enum.at(data["c_loc"], node - n_visit - 1)
        ^start_node -> data["start_loc"]
        ^end_node -> data["end_loc"]
      end

      location_id = fn node -> Enum.at(ids["locations"], node_location.(node) - 1) end
      at = fn node -> instant(day_start, Enum.at(st, node - 1)) end

      stops =
        for node <- 1..n_visit//1 do
          visit_id = Enum.at(ids["visits"], node - 1)
          minutes = Enum.at(data["v_dur"], node - 1)

          %{
            "visit_request_id" => visit_id,
            "starts_at" => DateTime.to_iso8601(at.(node)),
            "ends_at" => DateTime.to_iso8601(DateTime.add(at.(node), minutes * 60, :second)),
            "booked_minutes" => Map.fetch!(booked, visit_id),
            "service_minutes" => minutes,
            "location_id" => location_id.(node)
          }
        end
        |> Enum.sort_by(& &1["starts_at"])
        |> Enum.with_index(1)
        |> Enum.map(fn {stop, order} -> Map.put(stop, "order", order) end)

      legs =
        route
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] ->
          minutes = Enum.at(tin, to - 1)

          %{
            "from" => Enum.at(labels, from - 1),
            "to" => Enum.at(labels, to - 1),
            "from_location_id" => location_id.(from),
            "to_location_id" => location_id.(to),
            "minutes" => minutes,
            "departs_at" => DateTime.to_iso8601(DateTime.add(at.(to), -minutes * 60, :second)),
            "arrives_at" => DateTime.to_iso8601(at.(to))
          }
        end)

      {:ok,
       %{
         "stops" => stops,
         "legs" => legs,
         "route_ends_at" => DateTime.to_iso8601(at.(end_node))
       }}
    else
      _ -> {:error, :answer_unreadable}
    end
  end

  def decode(_payload, _answer), do: {:error, :answer_unreadable}

  # The route: the successor chain from the start of the day to its end, which must
  # visit every node exactly once.
  defp route(succ, start_node, end_node, n_node) do
    walk(succ, start_node, end_node, [start_node], n_node)
  end

  defp walk(_succ, current, current, acc, n_node) when length(acc) == n_node,
    do: {:ok, Enum.reverse(acc)}

  defp walk(_succ, current, current, _acc, _n_node), do: :error

  defp walk(succ, current, end_node, acc, n_node) do
    next = Enum.at(succ, current - 1)

    if is_integer(next) and next >= 1 and next <= n_node and next not in acc,
      do: walk(succ, next, end_node, [next | acc], n_node),
      else: :error
  end

  # ── small helpers ──────────────────────────────────────────────────────────

  # Every array that can be empty carries one trailing pad element: Solverl renders
  # an empty list as `array0d([])`, which MiniZinc rejects for a one-dimensional
  # array. The model declares these `array[int]` and reads only the first `n_*`
  # entries (see `mobile_visits.mzn`).
  defp pad(list, fill), do: list ++ [fill]

  defp instant(day_start, minutes), do: DateTime.add(day_start, minutes * 60, :second)

  defp floor_minute(%DateTime{} = at, day_start),
    do: Integer.floor_div(DateTime.diff(at, day_start, :second), 60)

  defp ceil_minute(%DateTime{} = at, day_start),
    do: -Integer.floor_div(-DateTime.diff(at, day_start, :second), 60)

  defp exact_minute(%DateTime{} = at, day_start), do: floor_minute(at, day_start)
end
