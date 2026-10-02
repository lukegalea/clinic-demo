defmodule ClinicDemo.EvalSets.Split do
  @moduledoc """
  §6 split discipline: four splits — `optimise`, `calibration`, `test`,
  `audit` — assigned at ingestion, before any model or optimiser sees a row.
  Moving a row between splits is prohibited; a re-split is a new eval-set
  version with a new `eval_set_hash`.

  ## The assignment rule, as implemented

  A uniform random draw by hash rank: within each family (the design's "rows
  are split before labelling assignment where possible, so no split's items
  are systematically easier" — stratification kept, not invented), rows are
  ordered by `SHA-256(salt <> ":" <> eval_set_hash <> ":" <> id)` and cut at
  the cumulative proportion boundaries. The draw is a pure function of
  `(salt, eval_set_hash, ids)`, so the same set version and salt always
  reproduce the identical assignment, and a label change — a new
  `eval_set_hash` — produces a fresh assignment while every earlier version's
  assignment remains reproducible from its recorded salt and hash.

  ## The two things §6 does not specify (minimal readings, flagged)

  * **Proportions.** The design requires proportions be *reported*, never
    fixes them. Default here: `optimise 0.2 / calibration 0.6 / test 0.2`,
    weighted for §3's bound (calibration is the consumer; search absorbs
    into `optimise`). The companion records what was used.
  * **The `audit` split is not drawn.** Per §5, audit rows arrive from
    production audits as provenance, not ingestion: a row may carry an
    explicit `"split"` field (audit today) and the draw honours it verbatim,
    drawing only the rest. `audit` has no ingestion share.

  The assignment is recorded beside the items (`splits.json`) with its
  `eval_set_hash`, salt and proportions — never inside `items.jsonl`.
  """

  @default_salt "s1-25-v1"
  @all_splits [:optimise, :calibration, :test, :audit]
  @default_proportions [optimise: 0.2, calibration: 0.6, test: 0.2]

  alias ClinicDemo.EvalSets.Store

  @type split_name :: :optimise | :calibration | :test | :audit

  # Assignment values are the split names as strings (they round-trip
  # through the JSON companion untouched).
  @type assignment :: %{String.t() => String.t()}
  @type result :: %{
          required(:eval_set_hash) => String.t(),
          required(:salt) => String.t(),
          required(:proportions) => %{String.t() => float()},
          required(:assignment) => assignment()
        }

  @doc "The default salt for the draw (recorded in the companion on write)."
  def default_salt, do: @default_salt

  @doc "Split names in stable display order; `audit` is provenance-assigned (§5)."
  def split_names, do: @all_splits

  @doc """
  Assigns every item to exactly one split. Deterministic in
  `(items, salt, proportions)`; honours explicit per-row `"split"` values
  (the §5 audit escape hatch) verbatim.
  """
  @spec assign([Store.item()], keyword()) :: result()
  def assign(items, opts \\ []) do
    salt = Keyword.get(opts, :salt, @default_salt)
    share_list = Keyword.get(opts, :proportions, @default_proportions)
    proportions = proportions(share_list)
    eval_set_hash = Store.eval_set_hash(items)

    drawn =
      items
      |> Enum.reject(&explicit_split/1)
      |> Enum.group_by(& &1["question"])
      |> Enum.flat_map(fn {family, members} ->
        draw_family(family, members, salt, eval_set_hash, share_list)
      end)
      |> Map.new()

    assignment =
      Map.new(items, fn item ->
        {item["id"], explicit_split(item) || Map.fetch!(drawn, item["id"])}
      end)

    %{eval_set_hash: eval_set_hash, salt: salt, proportions: proportions, assignment: assignment}
  end

  @doc "Split counts per family, plus the `:total` row, in stable split order."
  @spec counts_by_family([Store.item()], assignment()) :: %{
          String.t() => %{split_name() => non_neg_integer()},
          :total => %{split_name() => non_neg_integer()}
        }
  def counts_by_family(items, assignment) do
    names = @all_splits

    items
    |> Enum.group_by(& &1["question"])
    |> Map.new(fn {family, members} ->
      counts = count_rows(members, assignment, names)
      {family, counts}
    end)
    |> Map.put(:total, count_rows(items, assignment, names))
  end

  # --- the companion file (assignment pinned beside the items) ---------------

  @doc "Path of the split companion for set `name`."
  def companion_path(name), do: Path.join(Store.set_dir(name), "splits.json")

  @doc "Writes the assignment companion for set `name`."
  def write_companion(name, %{} = result) do
    File.mkdir_p!(Store.set_dir(name))
    File.write!(companion_path(name), JSON.encode!(result) <> "\n")
    companion_path(name)
  end

  @doc """
  Loads the companion for set `name`: `{:ok, map}`, or `:missing` when the
  set has never been split.
  """
  @spec load_companion(String.t()) :: {:ok, map()} | :missing
  def load_companion(name) do
    case File.read(companion_path(name)) do
      {:ok, contents} -> {:ok, JSON.decode!(contents)}
      {:error, :enoent} -> :missing
    end
  end

  @doc """
  Recomputes the assignment for `items` and compares it with the companion
  on disk: `:ok` when identical (same hash, salt, proportions, per-row
  splits); `{:drift, [what changed]}` otherwise — either the fixture
  changed without a deliberate re-split, or the companion is stale.
  """
  @spec verify(String.t(), [Store.item()], keyword()) :: :ok | {:drift, [String.t()]}
  def verify(name, items, opts \\ []) do
    case load_companion(name) do
      :missing ->
        {:drift, ["no companion at #{companion_path(name)}"]}

      {:ok, companion} ->
        fresh = assign(items, opts)

        drift =
          for {field, fresh_value} <- [
                {"eval_set_hash", fresh.eval_set_hash},
                {"salt", fresh.salt},
                {"proportions", normalise_for_compare(fresh.proportions)},
                {"assignment", normalise_for_compare(fresh.assignment)}
              ],
              not equal?(companion[field], fresh_value) do
            field
          end

        if drift == [], do: :ok, else: {:drift, drift}
    end
  end

  # --- internals ---------------------------------------------------------------

  defp proportions(list) when is_list(list) do
    shares = Map.new(list, fn {name, share} -> {Atom.to_string(name), share} end)

    total = shares |> Map.values() |> Enum.sum()

    unless abs(total - 1.0) < 1.0e-9 and Enum.all?(Map.values(shares), &(&1 >= 0.0)) do
      raise ArgumentError,
            "split proportions must be non-negative and sum to 1, got #{inspect(list)}"
    end

    shares
  end

  # §5's escape hatch: a row with an explicit split (audit rows arrive that
  # way) is honoured verbatim and excluded from the draw.
  defp explicit_split(%{"split" => split}) when is_binary(split) do
    if split in Enum.map(@all_splits, &Atom.to_string/1), do: split
  end

  defp explicit_split(_), do: nil

  defp draw_family(_family, members, salt, eval_set_hash, proportions) do
    n = length(members)
    names = Keyword.keys(proportions)

    # Cumulative boundaries: idx below round(cum_share * n) belongs to that
    # split. Kernel.round/1 keeps the cut deterministic.
    boundaries =
      proportions
      |> Keyword.values()
      |> Enum.scan(0, fn share, acc -> acc + share end)
      |> Enum.map(&Kernel.round(&1 * n))

    members
    |> Enum.map(&{rank(salt, eval_set_hash, &1["id"]), &1["id"]})
    |> Enum.sort()
    |> Enum.with_index()
    |> Map.new(fn {{_digest, id}, idx} -> {id, split_at(names, boundaries, idx)} end)
  end

  defp rank(salt, eval_set_hash, id) do
    :crypto.hash(:sha256, salt <> ":" <> eval_set_hash <> ":" <> id)
  end

  defp split_at(names, boundaries, idx) do
    names
    |> Enum.zip(boundaries)
    |> Enum.find(fn {_name, boundary} -> idx < boundary end)
    |> case do
      {name, _} -> Atom.to_string(name)
      # Numerical dust at the tail: the last split takes the remainder.
      nil -> Atom.to_string(List.last(names))
    end
  end

  defp count_rows(rows, assignment, names) do
    frequencies = Enum.frequencies_by(rows, &Map.fetch!(assignment, &1["id"]))

    Map.new(names, fn name -> {name, Map.get(frequencies, Atom.to_string(name), 0)} end)
  end

  # The companion round-trips through JSON (string keys); compare
  # structurally whatever the key type.
  defp normalise_for_compare(value) when is_map(value),
    do: Map.new(value, fn {k, v} -> {to_string(k), normalise_for_compare(v)} end)

  defp normalise_for_compare(value), do: value

  defp equal?(a, b), do: normalise_for_compare(a) == normalise_for_compare(b)
end
