defmodule ClinicDemo.SystemOneSpike.CalibrationTest do
  @moduledoc """
  The calibrate-compatible run maps: the split filter, the §8.1 field
  contract, the golden metrics (decimal strings), the §3 scored-pair
  readings, the n-threshold discipline, and the identity rules that
  keep an artefact from lying about its instrument.
  """

  use ExUnit.Case, async: true

  alias ClinicDemo.SystemOneSpike.Calibration

  @eval_set_hash String.duplicate("5", 64)

  # ── fixtures ──────────────────────────────────────────────────────────────

  defp companion do
    %{
      "eval_set_hash" => @eval_set_hash,
      "assignment" => %{
        "n-pos-01" => "calibration",
        "n-neg-02" => "calibration",
        "c-urg-01" => "calibration",
        "c-abst-01" => "optimise"
      }
    }
  end

  defp noul_item(id, gold), do: %{"id" => id, "question" => "notes_follow_up", "gold" => gold}

  defp choice_item(id, gold),
    do: %{"id" => id, "question" => "presenting_urgency", "gold" => gold}

  # A spike row as Runner.call/5 returns it (the fields this module reads).
  defp noul_row(item, p, result_model \\ "laya:typed-decisions") do
    %{
      "ok" => true,
      "item_id" => item["id"],
      "gold" => item["gold"],
      "result_model" => result_model,
      "answer" => %{"p" => p}
    }
  end

  defp choice_row(item, value, probabilities, result_model \\ "laya:typed-decisions") do
    %{
      "ok" => true,
      "item_id" => item["id"],
      "gold" => item["gold"],
      "result_model" => result_model,
      "answer" => %{"value" => value, "probabilities" => probabilities, "confidence" => nil}
    }
  end

  defp errored_row(item) do
    %{"ok" => false, "item_id" => item["id"], "gold" => item["gold"], "error" => %{"kind" => "x"}}
  end

  # ── the split ─────────────────────────────────────────────────────────────

  test "calibration_items keeps exactly the companion's calibration rows" do
    items = [
      noul_item("n-pos-01", true),
      noul_item("n-neg-02", false),
      choice_item("c-urg-01", "urgent"),
      choice_item("c-abst-01", "insufficient_information")
    ]

    kept = Calibration.calibration_items(items, companion())

    assert Enum.map(kept, & &1["id"]) == ["n-pos-01", "n-neg-02", "c-urg-01"]
  end

  # ── the §8.1 field contract ───────────────────────────────────────────────

  test "a run map carries exactly the §8.1 record fields, nothing invented" do
    {:ok, run} =
      Calibration.run_map(:laya, :notes_follow_up, [noul_row(noul_item("n-pos-01", true), 0.9)],
        eval_set_hash: @eval_set_hash
      )

    assert MapSet.new(Map.keys(run)) == MapSet.new(Calibration.run_fields())
  end

  test "identity: model digest over requested/reported, runtime from req_llm, region homelab" do
    {:ok, run} =
      Calibration.run_map(:laya, :notes_follow_up, [noul_row(noul_item("n-pos-01", true), 0.9)],
        eval_set_hash: @eval_set_hash
      )

    expected_digest =
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, "laya:typed-decisions/laya:typed-decisions"),
          case: :lower
        )

    assert run.model_version == "laya:typed-decisions"
    assert run.model_digest == expected_digest
    assert run.runtime_version == to_string(Application.spec(:req_llm, :vsn))
    assert run.region == "homelab"
    assert run.source == "eval_set"
    assert run.created_by == "mix clinic.calibrate"
    assert run.eval_set_hash == @eval_set_hash
    assert String.starts_with?(run.question_hashes |> hd(), "sha256:")
    assert run.question_hashes == [Calibration.question_hash(:notes_follow_up)]
  end

  test "no answered row, no run — and a mixed report is two runs, not one" do
    item = noul_item("n-pos-01", true)

    assert {:error, :no_answered_rows} =
             Calibration.run_map(:laya, :notes_follow_up, [errored_row(item)],
               eval_set_hash: @eval_set_hash
             )

    mixed = [noul_row(item, 0.9, "laya:a"), noul_row(noul_item("n-neg-02", false), 0.1, "laya:b")]

    assert {:error, {:mixed_or_missing_result_model, _}} =
             Calibration.run_map(:laya, :notes_follow_up, mixed, eval_set_hash: @eval_set_hash)
  end

  test "observations_digest is over the sorted answered ids; errors shrink n" do
    item_a = noul_item("n-pos-01", true)
    item_b = noul_item("n-neg-02", false)
    item_c = noul_item("n-neg-03", false)

    {:ok, run} =
      Calibration.run_map(
        :laya,
        :notes_follow_up,
        [noul_row(item_a, 0.9), errored_row(item_b), noul_row(item_c, 0.2)],
        eval_set_hash: @eval_set_hash
      )

    assert run.n == 2

    expected =
      "sha256:" <>
        Base.encode16(:crypto.hash(:sha256, Enum.join(Enum.sort(["n-pos-01", "n-neg-03"]), "\n")),
          case: :lower
        )

    assert run.observations_digest == expected
  end

  # ── the metrics (golden) ──────────────────────────────────────────────────

  test "noul metrics: golden decimal strings over a hand-checked set" do
    pairs = [{1.0, true}, {1.0, true}, {0.0, false}, {0.0, true}]
    metrics = Calibration.metrics(:noul, pairs)

    # bin 0: mean p 0.0, observed 0.5 → |Δ| 0.5, weight 2/4 = 0.25;
    # bin 9: mean p 1.0, observed 1.0 → 0.
    assert metrics["ece"] == "0.25"
    # (0 + 0 + 0 + 1²) / 4.
    assert metrics["brier"] == "0.25"
    assert metrics["reliability_bins"]["bin_0"]["n"] == "2"
    assert metrics["reliability_bins"]["bin_0"]["confidence"] == "0.0"
    assert metrics["reliability_bins"]["bin_0"]["accuracy"] == "0.5"
    assert metrics["reliability_bins"]["bin_9"]["n"] == "2"
    assert metrics["reliability_bins"]["bin_9"]["confidence"] == "1.0"
    assert metrics["reliability_bins"]["bin_5"]["n"] == "0"
    assert metrics["reliability_bins"]["bin_5"]["confidence"] == nil
  end

  test "choice metrics: per-class precision, recall and accuracy as decimal strings" do
    pairs = [
      {"urgent", "urgent"},
      {"urgent", "routine"},
      {"routine", "routine"},
      {"routine", "routine"},
      {"insufficient_information", "urgent"}
    ]

    metrics = Calibration.metrics(:choice, pairs)

    assert metrics["accuracy"] == "0.6"
    assert metrics["per_class"]["urgent"]["n"] == "2"
    assert metrics["per_class"]["urgent"]["precision"] == "0.5"
    assert metrics["per_class"]["urgent"]["recall"] == "0.5"

    assert metrics["per_class"]["routine"]["n"] == "3"
    assert metrics["per_class"]["routine"]["precision"] == "1.0"
    assert metrics["per_class"]["routine"]["recall"] == "0.6666666666666666"

    # The abstention class is a class like any other.
    assert metrics["per_class"]["insufficient_information"]["n"] == "0"
    assert metrics["per_class"]["insufficient_information"]["recall"] == nil
  end

  # ── the §3 scored pairs ───────────────────────────────────────────────────

  test "noul scored pairs read supports as gold true" do
    answered = [noul_row(noul_item("a", true), 0.9), noul_row(noul_item("b", false), 0.8)]

    assert Calibration.scored_pairs(:noul, answered) == [{0.9, true}, {0.8, false}]
  end

  test "choice scored pairs read supports as gold NOT insufficient_information" do
    answered = [
      choice_row(choice_item("a", "urgent"), "urgent", %{"urgent" => 0.9, "routine" => 0.1}),
      choice_row(choice_item("b", "insufficient_information"), "routine", %{
        "routine" => 0.95,
        "urgent" => 0.05
      })
    ]

    # The second row: a confident option while the right answer was to
    # abstain — the loss this calibration guards, scored as not-supports.
    assert Calibration.scored_pairs(:choice, answered) == [{0.9, true}, {0.95, false}]
  end

  # ── the n-threshold discipline ────────────────────────────────────────────

  test "below min_n the run keeps its negative result and names the finding" do
    rows =
      for i <- 1..10 do
        noul_row(noul_item("n-#{i}", rem(i, 2) == 0), 0.9)
      end

    {:ok, run} =
      Calibration.run_map(:laya, :notes_follow_up, rows, eval_set_hash: @eval_set_hash)

    assert run.n == 10
    assert run.result == "no_table"
    assert run.proposed_band_table == nil

    assert {:refused, [finding]} = Calibration.propose(run)
    assert finding["finding"] == "n_below_min"
    assert finding["required_n"] == 62
    assert finding["actual_n"] == 10
  end

  test "at min_n with a clean run, the proposal is the draft band table as data" do
    rows =
      for i <- 1..62 do
        noul_row(noul_item("n-#{String.pad_leading(Integer.to_string(i), 3, "0")}", true), 0.95)
      end

    {:ok, run} =
      Calibration.run_map(:laya, :notes_follow_up, rows, eval_set_hash: @eval_set_hash)

    assert run.result == "proposed_table"

    proposal = run.proposed_band_table
    assert proposal["definition_key"] == "bands_notes_follow_up"
    assert proposal["family_tag"] == "judgments:family:notes_follow_up"
    assert proposal["thresholds"]["threshold"] == "0.95"
    assert proposal["alpha"] == "0.016"
    assert proposal["note"] =~ "PROPOSED"
    assert proposal["note"] =~ "never published"
  end

  test "no earned threshold at α keeps the negative result too" do
    # A single error over 62 rows: (1+1)/63 > α = 0.016 — the bound
    # doing its job; no λ qualifies.
    rows =
      for i <- 1..62 do
        gold = i == 1
        noul_row(noul_item("n-#{String.pad_leading(Integer.to_string(i), 3, "0")}", gold), 0.95)
      end

    {:ok, run} =
      Calibration.run_map(:laya, :notes_follow_up, rows, eval_set_hash: @eval_set_hash)

    assert run.conformal_thresholds == %{}
    assert run.result == "no_table"

    assert {:refused, [finding]} = Calibration.propose(run)
    assert finding["finding"] == "no_conformal_threshold_at_alpha"
  end
end
