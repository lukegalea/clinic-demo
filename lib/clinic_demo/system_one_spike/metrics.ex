defmodule ClinicDemo.SystemOneSpike.Metrics do
  @moduledoc """
  The spike's measurements, as pure functions over `{p, gold?}` pairs and
  latency lists. No thresholds are asserted here; the spike measures and the
  report decides.

  With N around 24 per question, every number here has wide error bars. ECE in
  particular is unstable at this size: most of its 10 bins hold one or two
  items. The report states N next to every figure.
  """

  @doc """
  Area under the ROC curve, by the Mann-Whitney statistic: the probability that
  a random gold-positive item scores higher than a random gold-negative one,
  with ties counted as half. `nil` when either class is empty.
  """
  def auroc(pairs) do
    pos = for {p, true} <- pairs, do: p
    neg = for {p, false} <- pairs, do: p

    if pos == [] or neg == [] do
      nil
    else
      wins = for a <- pos, b <- neg, reduce: 0.0, do: (acc -> acc + win(a, b))

      wins / (length(pos) * length(neg))
    end
  end

  defp win(a, b) when a > b, do: 1.0
  defp win(a, b) when a == b, do: 0.5
  defp win(_a, _b), do: 0.0

  @doc "Brier score: mean squared error of p against the 0/1 outcome."
  def brier([]), do: nil

  def brier(pairs) do
    pairs |> Enum.map(fn {p, gold} -> :math.pow(p - bool(gold), 2) end) |> mean()
  end

  @doc """
  Expected calibration error over `bins` equal-width bins of p: the
  count-weighted mean of |mean p − observed rate| per bin.
  """
  def ece(pairs, bins \\ 10)
  def ece([], _bins), do: nil

  def ece(pairs, bins) do
    n = length(pairs)

    pairs
    |> Enum.group_by(fn {p, _} -> min(trunc(p * bins), bins - 1) end)
    |> Enum.map(fn {_bin, members} ->
      mean_p = members |> Enum.map(&elem(&1, 0)) |> mean()
      rate = members |> Enum.map(&bool(elem(&1, 1))) |> mean()
      length(members) / n * abs(mean_p - rate)
    end)
    |> Enum.sum()
  end

  @doc "The reliability table behind ECE: `[{bin_low, n, mean_p, observed_rate}]`."
  def reliability(pairs, bins \\ 10) do
    grouped = Enum.group_by(pairs, fn {p, _} -> min(trunc(p * bins), bins - 1) end)

    for bin <- 0..(bins - 1) do
      members = Map.get(grouped, bin, [])

      case members do
        [] ->
          {bin / bins, 0, nil, nil}

        _ ->
          {bin / bins, length(members), members |> Enum.map(&elem(&1, 0)) |> mean(),
           members |> Enum.map(&bool(elem(&1, 1))) |> mean()}
      end
    end
  end

  @doc "Accuracy when p ≥ 0.5 is read as yes."
  def accuracy([]), do: nil
  def accuracy(pairs), do: pairs |> Enum.map(fn {p, g} -> bool(p >= 0.5 == g) end) |> mean()

  @doc """
  Selective accuracy for a noul: keep only items whose answer is confident
  (p ≥ t or p ≤ 1 − t), then report `%{coverage, accuracy, n}` over those.
  """
  def selective(pairs, t) do
    kept = Enum.filter(pairs, fn {p, _} -> p >= t or p <= 1 - t end)

    %{
      threshold: t,
      n: length(kept),
      coverage: ratio(length(kept), length(pairs)),
      accuracy: accuracy(kept)
    }
  end

  @doc """
  Selective accuracy for a choice: keep only items whose top-option
  probability is ≥ t. Pairs are `{top_p, correct?}`.
  """
  def selective_choice(pairs, t) do
    kept = Enum.filter(pairs, fn {p, _} -> p >= t end)

    %{
      threshold: t,
      n: length(kept),
      coverage: ratio(length(kept), length(pairs)),
      accuracy: if(kept == [], do: nil, else: kept |> Enum.map(&bool(elem(&1, 1))) |> mean())
    }
  end

  @doc """
  The best selective operating point: the lowest threshold in 0.50..0.99 at
  which selective accuracy is at least `min_accuracy` with coverage of at least
  `min_coverage`, or `nil` if there is none. Used for the AC-4 go rule.
  """
  def operating_point(pairs, min_accuracy, min_coverage, selector \\ &selective/2) do
    50..99
    |> Enum.map(&(&1 / 100))
    |> Enum.map(&selector.(pairs, &1))
    |> Enum.find(fn %{accuracy: a, coverage: c} ->
      is_number(a) and a >= min_accuracy and c >= min_coverage
    end)
  end

  @doc "How many p fall strictly inside the middle band (0.2, 0.8)."
  def middle_band(pairs), do: Enum.count(pairs, fn {p, _} -> p > 0.2 and p < 0.8 end)

  @doc "Mean and median p for each gold class."
  def by_gold(pairs) do
    for gold <- [true, false], into: %{} do
      ps = for {p, ^gold} <- pairs, do: p
      {gold, %{n: length(ps), mean: mean(ps), median: percentile(ps, 50)}}
    end
  end

  @doc "Nearest-rank percentile, `nil` on an empty list."
  def percentile([], _q), do: nil

  def percentile(values, q) do
    sorted = Enum.sort(values)
    rank = max(ceil(q / 100 * length(sorted)), 1)
    Enum.at(sorted, rank - 1)
  end

  @doc "Population standard deviation."
  def stddev([]), do: nil
  def stddev([_]), do: 0.0

  def stddev(values) do
    m = mean(values)
    values |> Enum.map(&:math.pow(&1 - m, 2)) |> mean() |> :math.sqrt()
  end

  @doc "Arithmetic mean, `nil` on an empty list."
  def mean([]), do: nil
  def mean(values), do: Enum.sum(values) / length(values)

  defp ratio(_, 0), do: nil
  defp ratio(a, b), do: a / b

  defp bool(true), do: 1.0
  defp bool(false), do: 0.0
end
