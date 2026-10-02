defmodule ClinicDemo.EvalSets.RiskControlTest do
  use ExUnit.Case, async: true

  alias ClinicDemo.EvalSets.RiskControl

  @alpha 0.016

  test "min_calibration_n reproduces the design's worked table (§3, α = 0.016)" do
    # Errors tolerated → minimum calibration n.
    assert RiskControl.min_calibration_n(0, @alpha) == 62
    assert RiskControl.min_calibration_n(1, @alpha) == 124
    assert RiskControl.min_calibration_n(2, @alpha) == 187
    assert RiskControl.min_calibration_n(3, @alpha) == 249
    assert RiskControl.min_calibration_n(4, @alpha) == 312
  end

  test "tolerable_errors reads the feasibility condition the other way" do
    # The design's own reads: n = 200 tolerates e ≤ 2 at the strict reading;
    # n = 187 tolerates two; n = 249 tolerates three.
    assert RiskControl.tolerable_errors(200, @alpha) == 2
    assert RiskControl.tolerable_errors(187, @alpha) == 2
    assert RiskControl.tolerable_errors(249, @alpha) == 3
    # Below n = 62 not even zero errors meet the budget.
    assert RiskControl.tolerable_errors(61, @alpha) == nil
  end

  test "threshold applies the fixed quantile rule, not a grid search" do
    # n = 4, α = 0.3 → budget (e+1)/5 ≤ 0.3 holds only for e = 0.
    # The two wrong-gold items sit at 0.6 and below; λ̂ is the smallest score
    # whose admitted set contains no wrong-gold item: 0.8.
    scored = [{0.9, true}, {0.8, true}, {0.6, false}, {0.4, true}]
    assert RiskControl.threshold(scored, 0.3) == 0.8

    # A looser budget admits the earlier threshold: e ≤ 1 at α = 0.4 → λ̂ = 0.4.
    assert RiskControl.threshold(scored, 0.4) == 0.4
  end

  test "threshold reports nil when no threshold meets the budget, zero errors included" do
    # (0 + 1)/(3 + 1) = 0.25 > 0.2 even with no wrong-gold item at all.
    assert RiskControl.threshold([{0.9, true}, {0.8, true}, {0.7, true}], 0.2) == nil
  end

  test "the audit alarm rule: m = 200, α₀ = 0.02 alarms at 8 errors, not 7 (§5)" do
    assert RiskControl.alarm_threshold(200, 0.02) == 8
    assert RiskControl.binomial_ge(200, 8, 0.02) <= 0.05
    # The design's stated non-alarm: 7 errors gives p ≈ 0.109.
    assert_in_delta RiskControl.binomial_ge(200, 7, 0.02), 0.109, 0.001
    assert RiskControl.binomial_ge(200, 7, 0.02) > 0.05
  end

  test "binomial_ge is exact against hand values" do
    assert_in_delta RiskControl.binomial_ge(10, 10, 0.5), 0.0009765625, 1.0e-9
    # k above m is an empty tail: zero.
    assert RiskControl.binomial_ge(10, 11, 0.5) == 0.0
    # The tail from 0 is the whole distribution.
    assert_in_delta RiskControl.binomial_ge(4, 0, 0.5), 1.0, 1.0e-12
  end
end
