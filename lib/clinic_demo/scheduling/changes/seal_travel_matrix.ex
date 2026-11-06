defmodule ClinicDemo.Scheduling.Changes.SealTravelMatrix do
  @moduledoc """
  The write side of `TravelMatrix.publish`: validates the pairs, puts them in
  canonical order, assigns the next version for the key, stamps the publication
  instant and seals the content hash.

  A pair is valid when its two location ids are UUIDs and differ, it appears once,
  and it is either `reachable: true` with a whole-minute `duration_minutes >= 0`
  (and an optional `distance_m >= 0`) or `reachable: false` with no duration at all.
  An unreachable pair that carries a duration would be one careless edit away from a
  cheap leg, so it is refused here.

  The version is one more than the key's latest. Two racing publications of one key
  collide on the `(key, version)` identity: one of them fails, never both succeed.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias ClinicDemo.Scheduling.TravelMatrix

  @impl true
  def change(changeset, _opts, _context) do
    entries = Ash.Changeset.get_attribute(changeset, :entries) || []
    key = Ash.Changeset.get_attribute(changeset, :key)

    case normalize(entries) do
      {:ok, normalized} ->
        seal(changeset, key, normalized)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :entries, message: message)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context), do: {:not_atomic, "reads the key's latest version"}

  defp seal(%Ash.Changeset{valid?: false} = changeset, _key, _entries), do: changeset
  defp seal(changeset, nil, _entries), do: changeset

  defp seal(changeset, key, entries) do
    version = next_version(key)
    published_at = DateTime.utc_now()

    fields = %{
      key: key,
      version: version,
      mode: Ash.Changeset.get_attribute(changeset, :mode),
      provider: Ash.Changeset.get_attribute(changeset, :provider),
      collected_at: Ash.Changeset.get_attribute(changeset, :collected_at),
      entries: entries
    }

    if is_nil(fields.provider) or is_nil(fields.collected_at) do
      changeset
    else
      changeset
      |> Ash.Changeset.force_change_attribute(:entries, entries)
      |> Ash.Changeset.force_change_attribute(:version, version)
      |> Ash.Changeset.force_change_attribute(:published_at, published_at)
      |> Ash.Changeset.force_change_attribute(:content_hash, TravelMatrix.content_hash(fields))
    end
  end

  defp next_version(key) do
    latest =
      TravelMatrix
      |> Ash.Query.filter(key == ^key)
      |> Ash.Query.sort(version: :desc)
      |> Ash.Query.limit(1)
      |> Ash.read!(authorize?: false)

    case latest do
      [%{version: version}] -> version + 1
      [] -> 1
    end
  end

  # ── entries ────────────────────────────────────────────────────────────────

  defp normalize(entries) when is_list(entries) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
      case normalize_entry(entry) do
        {:ok, normalized} -> {:cont, {:ok, [normalized | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> check_unique(TravelMatrix.sort_entries(normalized))
      error -> error
    end
  end

  defp normalize(_other), do: {:error, "must be a list of pairs"}

  defp normalize_entry(%{} = entry) do
    entry = Map.new(entry, fn {k, v} -> {to_string(k), v} end)
    origin = entry["origin_id"]
    destination = entry["destination_id"]

    cond do
      not uuid?(origin) or not uuid?(destination) ->
        {:error, "a pair needs two location ids (UUIDs)"}

      origin == destination ->
        {:error, "a location to itself needs no pair: no travel is needed"}

      entry["reachable"] == true ->
        reachable(entry, origin, destination)

      entry["reachable"] == false ->
        unreachable(entry, origin, destination)

      true ->
        {:error, "a pair must say whether it is reachable (true or false)"}
    end
  end

  defp normalize_entry(_other), do: {:error, "a pair must be a map"}

  defp reachable(entry, origin, destination) do
    duration = entry["duration_minutes"]
    distance = entry["distance_m"]

    cond do
      not (is_integer(duration) and duration >= 0) ->
        {:error, "a reachable pair needs duration_minutes, a whole number >= 0"}

      not (is_nil(distance) or (is_integer(distance) and distance >= 0)) ->
        {:error, "distance_m must be a whole number >= 0 when given"}

      true ->
        base = %{
          "origin_id" => origin,
          "destination_id" => destination,
          "reachable" => true,
          "duration_minutes" => duration
        }

        {:ok, if(is_nil(distance), do: base, else: Map.put(base, "distance_m", distance))}
    end
  end

  defp unreachable(entry, origin, destination) do
    if is_nil(entry["duration_minutes"]) and is_nil(entry["distance_m"]) do
      {:ok, %{"origin_id" => origin, "destination_id" => destination, "reachable" => false}}
    else
      {:error, "an unreachable pair carries no duration or distance: it is never zero-cost"}
    end
  end

  defp check_unique(sorted) do
    pairs = Enum.map(sorted, &{&1["origin_id"], &1["destination_id"]})

    if length(pairs) == length(Enum.uniq(pairs)),
      do: {:ok, sorted},
      else: {:error, "a pair appears more than once"}
  end

  defp uuid?(value) when is_binary(value), do: match?({:ok, _}, Ecto.UUID.cast(value))
  defp uuid?(_other), do: false
end
