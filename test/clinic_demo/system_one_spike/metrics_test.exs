defmodule ClinicDemo.SystemOneSpike.MetricsTest do
  use ExUnit.Case, async: true

  alias ClinicDemo.SystemOneSpike.Metrics

  test "AUROC is 1 for perfect separation, 0 for reversed, 0.5 for ties" do
    assert Metrics.auroc([{0.9, true}, {0.8, true}, {0.2, false}, {0.1, false}]) == 1.0
    assert Metrics.auroc([{0.1, true}, {0.9, false}]) == 0.0
    assert Metrics.auroc([{0.5, true}, {0.5, false}]) == 0.5
    assert Metrics.auroc([{0.5, true}]) == nil
  end

  test "Brier and ECE are zero for confident, correct answers" do
    pairs = [{1.0, true}, {0.0, false}]
    assert Metrics.brier(pairs) == 0.0
    assert Metrics.ece(pairs) == 0.0
  end

  test "ECE measures the gap between mean p and the observed rate per bin" do
    # One bin (0.7–0.8), mean p 0.75, observed rate 0.5.
    assert_in_delta Metrics.ece([{0.75, true}, {0.75, false}]), 0.25, 1.0e-9
  end

  test "selective accuracy keeps only confident answers, both ways" do
    pairs = [{0.95, true}, {0.03, false}, {0.6, false}, {0.4, true}]
    assert %{n: 2, coverage: 0.5, accuracy: 1.0} = Metrics.selective(pairs, 0.9)
  end

  test "the operating point is the lowest threshold meeting both bars" do
    pairs = [{0.95, true}, {0.97, true}, {0.6, false}, {0.55, false}]
    assert %{threshold: t, coverage: 0.5} = Metrics.operating_point(pairs, 0.95, 0.4)
    assert t > 0.6 and t <= 0.95
    assert Metrics.operating_point(pairs, 0.95, 0.9) == nil
  end

  test "nearest-rank percentiles" do
    values = Enum.to_list(1..20)
    assert Metrics.percentile(values, 50) == 10
    assert Metrics.percentile(values, 95) == 19
    assert Metrics.percentile([], 50) == nil
  end

  test "middle band counts strictly between 0.2 and 0.8" do
    assert Metrics.middle_band([{0.2, true}, {0.5, true}, {0.8, false}, {0.79, false}]) == 2
  end
end
