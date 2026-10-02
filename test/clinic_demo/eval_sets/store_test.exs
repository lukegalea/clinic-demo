defmodule ClinicDemo.EvalSets.StoreTest do
  use ExUnit.Case, async: true

  alias ClinicDemo.EvalSets.Store

  test "load resolves the spike0 set from the fixture tree" do
    set = Store.load("spike0")
    assert set.name == "spike0"
    assert String.ends_with?(set.path, "priv/fixtures/system_one/spike0/items.jsonl")
    assert length(set.items) == 53
  end

  test "load accepts an explicit path and rejects unknown sets and bad names" do
    assert Store.load("priv/fixtures/system_one/spike0/items.jsonl").name == "items"

    assert_raise ArgumentError, fn -> Store.load("no-such-set") end
    assert_raise ArgumentError, fn -> Store.load("../etc") end
  end

  test "second-labeller identity is first-class: recorded value wins, absent falls back to the spike record" do
    items = Store.load("spike0").items

    # The committed fixture rows predate the field (additive convention);
    # every row resolves to the recorded second labeller of record.
    assert Enum.all?(items, fn item -> Store.second_labeller(item) == "ora-4" end)
    assert Enum.all?(items, fn item -> Store.first_labeller(item) == "author" end)

    assert Store.second_labeller(%{"second_labeller" => "named-human-2"}) == "named-human-2"
    assert Store.second_labeller(%{"second_labeller" => ""}) == "ora-4"
    assert Store.second_labeller(%{}) == "ora-4"
    assert Store.default_second_labeller() == "ora-4"
  end

  test "families come back in first-seen order with their item counts" do
    items = Store.load("spike0").items
    assert Store.families(items) == ["notes_follow_up", "presenting_urgency"]
    assert items |> Enum.count(&(&1["question"] == "notes_follow_up")) == 27
    assert items |> Enum.count(&(&1["question"] == "presenting_urgency")) == 26
  end

  test "answer pairs keep each question's own answer space, normalised to strings" do
    items = Store.load("spike0").items

    noul = Store.answer_pairs(items, "notes_follow_up")
    assert length(noul) == 27
    assert noul |> Enum.uniq() |> Enum.sort() == [{"false", "false"}, {"true", "true"}]

    choice = Store.answer_pairs(items, "presenting_urgency")
    assert length(choice) == 26
    assert {"insufficient_information", "insufficient_information"} in choice
    assert {"emergency", "emergency"} in choice
    # Nothing from one family leaks into the other's answer space.
    refute {"true", "true"} in choice
  end

  test "disposition derivation follows the documented mapping, never guessed" do
    assert Store.disposition(true) == "supports"
    assert Store.disposition(false) == "contradicts"
    assert Store.disposition("insufficient_information") == "insufficient"
    assert Store.disposition("emergency") == "supports"
    assert Store.disposition("routine") == "supports"
  end

  test "disposition pairs collapse to the design §1 vocabulary, pooled and per family" do
    items = Store.load("spike0").items

    pooled = Store.disposition_pairs(items)
    assert length(pooled) == 53

    classes =
      pooled
      |> Enum.flat_map(fn {a, b} -> [a, b] end)
      |> Enum.uniq()
      |> Enum.sort()

    assert classes == ["contradicts", "insufficient", "supports"]

    noul = Store.disposition_pairs(items, "notes_follow_up")
    noul_classes = noul |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.uniq() |> Enum.sort()
    assert noul_classes == ["contradicts", "supports"]

    choice = Store.disposition_pairs(items, "presenting_urgency")

    choice_classes =
      choice |> Enum.flat_map(fn {a, b} -> [a, b] end) |> Enum.uniq() |> Enum.sort()

    assert choice_classes == ["insufficient", "supports"]
  end

  test "unpaired reports rows whose blind second label was never filled" do
    assert Store.unpaired(Store.load("spike0").items) == []
    assert Store.unpaired([%{"id" => "x", "second_label" => nil}]) == ["x"]
  end
end
