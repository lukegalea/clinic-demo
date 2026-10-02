defmodule ClinicDemo.EvalSets.SplitTest do
  use ExUnit.Case, async: true

  alias ClinicDemo.EvalSets.{Split, Store}

  # The design's split names, §6.
  @names ["optimise", "calibration", "test", "audit"]

  defp spike0, do: Store.load("spike0")

  test "determinism: same set + salt gives the identical assignment" do
    items = spike0().items
    assert Split.assign(items, salt: "s1") == Split.assign(items, salt: "s1")
  end

  test "disjointness and completeness: every item in exactly one split" do
    items = spike0().items
    assignment = Split.assign(items).assignment

    assert MapSet.size(MapSet.new(Map.values(assignment))) <= 4
    assert MapSet.new(Map.keys(assignment)) == MapSet.new(items, & &1["id"])
    assert Enum.all?(Map.values(assignment), &(&1 in @names))

    assert Enum.all?(
             items,
             &(Map.fetch!(assignment, &1["id"]) in ["optimise", "calibration", "test"])
           )
  end

  test "stratification: every family is cut across all drawn splits at spike0's size" do
    items = spike0().items
    assignment = Split.assign(items).assignment

    for {family, members} <- Enum.group_by(items, & &1["question"]) do
      family_splits = members |> Enum.map(&Map.fetch!(assignment, &1["id"]))
      splits = Enum.uniq(family_splits)

      assert length(splits) == 3,
             "family #{family} landed in #{inspect(splits)}; the draw must cut every family"

      # Per-family shares within rounding of the default proportions.
      counts = Enum.frequencies(family_splits)
      assert abs(counts["calibration"] / length(members) - 0.6) < 0.1
      assert counts["optimise"] >= 1 and counts["test"] >= 1
    end
  end

  test "custom proportions are honoured and validated" do
    items = spike0().items

    assignment =
      Split.assign(items, proportions: [optimise: 0.5, calibration: 0.5, test: 0.0]).assignment

    counts = Enum.frequencies(Map.values(assignment))
    assert counts["optimise"] + counts["calibration"] + (counts["test"] || 0) == length(items)

    assert_raise ArgumentError, ~r/sum to 1/, fn ->
      Split.assign(items, proportions: [optimise: 0.5, calibration: 0.5, test: 0.5])
    end
  end

  test "the §5 escape hatch: an explicit split is honoured verbatim and kept out of the draw" do
    items = spike0().items
    [audited | rest] = items
    audited = Map.put(audited, "split", "audit")

    result = Split.assign([audited | rest])

    assert Map.fetch!(result.assignment, audited["id"]) == "audit"
    # Drawn rows never land in audit: the draw has no audit share.
    drawn = result.assignment |> Map.delete(audited["id"]) |> Map.values()
    refute "audit" in drawn
  end

  test "eval_set_hash: canonical (row order and key order never move it), label-sensitive" do
    items = spike0().items
    hash = Store.eval_set_hash(items)

    # Shuffled rows, shuffled keys — same canonical JSON, same hash.
    reshuffled = items |> Enum.reverse() |> Enum.map(&Map.new(Enum.shuffle(Map.to_list(&1))))
    assert Store.eval_set_hash(reshuffled) == hash

    # A label change is a new set version.
    [item | rest] = items
    relabelled = [%{item | "gold" => not item["gold"]} | rest]
    assert Store.eval_set_hash(relabelled) != hash

    assert String.length(hash) == 64
  end

  test "a new eval_set_hash re-splits while the old assignment stays reproducible" do
    items = spike0().items
    first = Split.assign(items, salt: "s1")

    [item | rest] = items
    relabelled = [%{item | "second_label" => :new_value} | rest]
    second = Split.assign(relabelled, salt: "s1")

    # New hash, and the re-split actually moves rows (design §6: a re-split
    # is a new version — never a per-row patch).
    assert second.eval_set_hash != first.eval_set_hash
    assert second.assignment != first.assignment

    # The old version reproduces exactly from its recorded inputs.
    assert Split.assign(items, salt: "s1") == first

    # A different salt is a different draw on the same version.
    assert Split.assign(items, salt: "s2").assignment != first.assignment
    assert Split.assign(items, salt: "s2").eval_set_hash == first.eval_set_hash
  end

  test "golden stability: the committed spike0 companion matches this set version" do
    set = spike0()

    # The companion is pinned once and committed; it must never drift from a
    # recomputation. (A failure here means items.jsonl changed without a
    # deliberate re-split — design §6.)
    assert {:ok, companion} = Split.load_companion(set.name)
    assert companion["eval_set_hash"] == Store.eval_set_hash(set.items)
    assert :ok = Split.verify(set.name, set.items)

    # And the companion's own assignment is exactly what the recorded salt
    # and hash reproduce.
    fresh = Split.assign(set.items, salt: companion["salt"])
    assert fresh.eval_set_hash == companion["eval_set_hash"]
    assert fresh.assignment == companion["assignment"]
  end

  test "verify reports the fields that drifted" do
    set = spike0()
    assert :ok = Split.verify(set.name, set.items)

    tampered = Enum.map(set.items, &Map.put(&1, "gold", "tampered"))
    assert {:drift, fields} = Split.verify(set.name, tampered)
    assert "eval_set_hash" in fields
    assert "assignment" in fields

    assert {:drift, ["no companion" <> _]} = Split.verify("no-such-split-set", set.items)
  end

  test "counts_by_family reports per family and total in stable split order" do
    items = spike0().items
    result = Split.assign(items)
    counts = Split.counts_by_family(items, result.assignment)

    assert Map.has_key?(counts, :total)
    assert MapSet.new(Map.keys(counts[:total])) == MapSet.new(Split.split_names())
    assert Enum.sum(Map.values(counts[:total])) == length(items)

    for {family, family_counts} <- counts, family != :total do
      members = Enum.count(items, &(&1["question"] == family))
      assert Enum.sum(Map.values(family_counts)) == members
    end
  end
end
