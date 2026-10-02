defmodule ClinicDemo.EvalSets.AgreementTest do
  use ExUnit.Case, async: true

  alias ClinicDemo.EvalSets.{Agreement, Store}

  # The recorded spike-0 second-labelling numbers
  # (docs/spikes/system-one-spike-0.md, "Second labelling record (2026-10-02)"):
  # 53/53 raw agreement, zero disagreements; kappa = 1.000 in both families
  # (noul p_e 0.5336, choice p_e 0.2160, combined disposition-layer p_e
  # 0.4731); PABAK = AC1 = 1.000 where the <10%-prevalence rule triggers
  # (combined-layer insufficient, 8/106 pooled = 7.55%). These are pinned:
  # any drift is a bug in the measurement core, not in the record.
  @noul_pe 389 / 729
  @choice_pe 146 / 676
  @combined_pe 1329 / 2809

  defp spike0, do: Store.load("spike0")

  test "golden: the spike0 set reproduces the recorded second-labelling record exactly" do
    %{items: items} = spike0()
    assert length(items) == 53
    assert Store.unpaired(items) == []

    # Per family, answer layer: 27 noul + 26 choice, all agreeing, kappa 1.000.
    noul = Agreement.summarise(Store.answer_pairs(items, "notes_follow_up"))
    assert noul.n == 27
    assert noul.agreements == 27
    assert noul.agreement == 1.0
    assert noul.pe == @noul_pe
    assert Float.round(noul.pe, 4) == 0.5336
    assert noul.kappa == 1.0
    assert noul.pabak == 1.0
    assert noul.ac1 == 1.0
    refute noul.extreme_prevalence?
    assert noul.headline == {:kappa, 1.0}

    choice = Agreement.summarise(Store.answer_pairs(items, "presenting_urgency"))
    assert choice.n == 26
    assert choice.agreements == 26
    assert choice.pe == @choice_pe
    assert Float.round(choice.pe, 4) == 0.2160
    assert choice.kappa == 1.0
    assert choice.pabak == 1.0
    assert choice.ac1 == 1.0
    refute choice.extreme_prevalence?
    assert choice.headline == {:kappa, 1.0}

    # Pooled, the disposition layer: supports 32 / contradicts 17 / insufficient 4,
    # pe 0.4731, and the <10%-prevalence rule triggers on `insufficient`.
    combined = Agreement.summarise(Store.disposition_pairs(items))
    assert combined.n == 53
    assert combined.agreements == 53
    assert combined.classes == ["contradicts", "insufficient", "supports"]
    # pe equals 1329/2809; the float sum-of-products differs from the closed
    # form only in the last ulp, and the recorded figure is the 4-decimal one.
    assert abs(combined.pe - @combined_pe) < 1.0e-12
    assert Float.round(combined.pe, 4) == 0.4731
    assert combined.kappa == 1.0
    assert combined.pabak == 1.0
    assert combined.ac1 == 1.0
    assert combined.extreme_prevalence?
    assert combined.extreme_classes == ["insufficient"]
    assert Float.round(combined.prevalence["insufficient"], 4) == 0.0755
    assert Float.round(combined.prevalence["supports"], 4) == 0.6038
    assert Float.round(combined.prevalence["contradicts"], 4) == 0.3208
    assert combined.headline == {:ac1, 1.0}

    # Per-class specific agreement is 1.0 everywhere at full agreement.
    assert Map.values(combined.specific_agreement) == [1.0, 1.0, 1.0]
  end

  test "the gate passes at the default 0.7 on the spike0 disposition layer" do
    summary = Agreement.summarise(Store.disposition_pairs(spike0().items))
    assert Agreement.gate?(summary)
    assert Agreement.gate?(summary, Agreement.default_gate())
    assert Agreement.gate?(summary, 1.0)
    refute Agreement.gate?(summary, 1.1)
  end

  test "the §2 caveat, mechanically: skewed prevalence compresses kappa and hands the headline to AC1" do
    # The design's own example: 95% of rows are `supports`. One disagreement
    # in 20 keeps raw agreement at 0.95 while kappa collapses to 0 — and the
    # `contradicts` class sits at 2.5% pooled prevalence, so the <10% rule
    # triggers and Gwet's AC1 carries the headline instead.
    same = List.duplicate({"supports", "supports"}, 19)
    pairs = same ++ [{"contradicts", "supports"}]
    s = Agreement.summarise(pairs)

    assert s.agreement == 0.95
    assert s.kappa == 0.0
    assert Float.round(s.ac1, 4) == 0.9474
    assert s.extreme_prevalence?
    assert s.extreme_classes == ["contradicts"]
    assert s.headline |> elem(0) == :ac1
    # The gate reads on AC1, prevalence stated — kappa never silently dropped.
    assert Agreement.gate?(s, Agreement.default_gate())
  end

  test "the extreme-prevalence rule switches the headline to AC1 with the classes named" do
    # insufficient at 3/40 pooled = 7.5% < 10%, while contradicts sits exactly
    # at the 10% boundary (not below it, so it does not trigger).
    pairs =
      List.duplicate({"supports", "supports"}, 16) ++
        List.duplicate({"contradicts", "contradicts"}, 2) ++
        [{"insufficient", "insufficient"}, {"supports", "insufficient"}]

    s = Agreement.summarise(pairs)
    assert Float.round(s.prevalence["insufficient"], 4) == 0.075
    assert Float.round(s.prevalence["contradicts"], 4) == 0.1
    assert s.extreme_classes == ["insufficient"]
    assert s.headline |> elem(0) == :ac1
  end

  test "unit edges: single-class and empty inputs do not crash" do
    empty = Agreement.summarise([])
    assert empty.n == 0
    assert empty.kappa == nil
    assert Agreement.gate?(empty) == false

    one = Agreement.summarise([{"supports", "supports"}])
    assert one.n == 1
    assert one.pabak == 1.0
    assert one.ac1 == 1.0
  end
end
