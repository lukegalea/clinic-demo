defmodule ClinicDemo.EvalSets.Agreement do
  @extreme_prevalence 0.10
  @gate_default 0.7

  @moduledoc """
  Inter-rater agreement over label pairs — the measurement core of the
  eval-sets programme (S1-25 design v1, §2).

  Pure functions over loaded label pairs. A *pair* is `{first, second}` — the
  same item labelled independently by two raters, labels compared as opaque
  class keys (any term; the store normalises to strings). Nothing here knows
  where pairs came from: `ClinicDemo.EvalSets.Store` loads them.

  ## The prevalence caveat, stated with every report

  kappa depends on prevalence: a skewed set compresses kappa toward zero even
  at high raw agreement, and a balanced artificially-easy set can overstate it.
  kappa >= #{@gate_default} is a gate, not the report. Every summary therefore
  carries class prevalence, raw percent agreement, and per-class specific
  agreement alongside kappa (design §2). When any class present sits below
  `10%` prevalence, a prevalence-adjusted statistic is reported alongside
  (PABAK and Gwet's AC1) and the headline gate reads on AC1, prevalence
  stated — per the design's §2 allowance (its open question 4 records that
  literal-kappa-always remains an open owner ruling; pass a stricter gate
  at the call site if that ruling lands).
  """

  @typedoc "A label pair: `{first_labeller_label, second_labeller_label}`."
  @type pair :: {term(), term()}

  @typedoc "The full agreement summary for one set of pairs (one layer, any grouping)."
  @type summary :: %{
          required(:n) => non_neg_integer(),
          required(:agreements) => non_neg_integer(),
          required(:agreement) => float() | nil,
          required(:classes) => [term()],
          required(:marginals) => %{term => float()},
          required(:prevalence) => %{term() => float()},
          required(:specific_agreement) => %{term() => float() | nil},
          required(:pe) => float(),
          required(:kappa) => float() | nil,
          required(:pabak) => float() | nil,
          required(:ac1) => float() | nil,
          required(:extreme_prevalence?) => boolean(),
          required(:extreme_classes) => [term()],
          required(:headline) => {:kappa | :ac1, float() | nil}
        }

  @doc "The prevalence below which a present class counts as extreme (design §2)."
  def extreme_prevalence_threshold, do: @extreme_prevalence

  @doc "The default kappa-gate level (design §2)."
  def default_gate, do: @gate_default

  @doc """
  The full §2 summary for `pairs`. Prevalence is the pooled share of each
  class across both raters; specific agreement for a class is
  `2·n_cc / (row_c + col_c)` (nil when the class never appears).
  """
  @spec summarise([pair()]) :: summary()
  def summarise([]) do
    %{
      n: 0,
      agreements: 0,
      agreement: nil,
      classes: [],
      marginals: %{},
      prevalence: %{},
      specific_agreement: %{},
      pe: 0.0,
      kappa: nil,
      pabak: nil,
      ac1: nil,
      extreme_prevalence?: false,
      extreme_classes: [],
      headline: {:kappa, nil}
    }
  end

  def summarise(pairs) do
    n = length(pairs)
    classes = classes(pairs)
    counts = first_counts(pairs, classes)
    k = length(classes)

    prevalence =
      Map.new(classes, fn c ->
        {c, (counts.first[c] + counts.second[c]) / (2 * n)}
      end)

    po = raw_agreement(pairs)
    pe = pe(pairs)
    pe_gamma = ac1_pe(counts, classes, n)

    specific =
      Map.new(classes, fn c ->
        row = counts.first[c]
        col = counts.second[c]
        both = agreements_on(pairs, c)
        {c, if(row + col == 0, do: nil, else: 2 * both / (row + col))}
      end)

    # classes/1 already returns only classes present on at least one side.
    extreme_classes =
      Enum.filter(classes, fn c -> Map.fetch!(prevalence, c) < @extreme_prevalence end)

    kappa = if pe == 1.0, do: nil, else: (po - pe) / (1 - pe)
    pabak = if k < 2, do: if(po == 1.0, do: 1.0, else: nil), else: (k * po - 1) / (k - 1)
    ac1 = if pe_gamma == 1.0, do: nil, else: (po - pe_gamma) / (1 - pe_gamma)

    extreme? = extreme_classes != []

    headline =
      if extreme? do
        {:ac1, ac1}
      else
        {:kappa, kappa}
      end

    %{
      n: n,
      agreements: agreements(pairs),
      agreement: po,
      classes: classes,
      marginals: %{
        first: first_marginals(counts, classes, n),
        second: second_marginals(counts, classes, n)
      },
      prevalence: prevalence,
      specific_agreement: specific,
      pe: pe,
      kappa: kappa,
      pabak: pabak,
      ac1: ac1,
      extreme_prevalence?: extreme?,
      extreme_classes: extreme_classes,
      headline: headline
    }
  end

  @doc "Raw percent agreement — the share of pairs where both raters gave the same label."
  def raw_agreement([]), do: nil

  def raw_agreement(pairs) do
    agreements(pairs) / length(pairs)
  end

  @doc "The count of pairs where both raters gave the same label."
  def agreements(pairs), do: Enum.count(pairs, fn {a, b} -> a == b end)

  @doc """
  Cohen's kappa with the chance-agreement term pe = Σ r_c · s_c over the two
  raters' marginal class distributions. `nil` for a single-class set, where
  kappa is 0/0 (the summary falls back to PABAK/AC1).
  """
  def kappa(pairs) do
    summarise(pairs).kappa
  end

  @doc "The chance-agreement term of Cohen's kappa."
  def pe(pairs) do
    n = length(pairs)
    classes = classes(pairs)
    counts = first_counts(pairs, classes)

    Enum.reduce(classes, 0.0, fn c, acc ->
      acc + counts.first[c] / n * (counts.second[c] / n)
    end)
  end

  @doc """
  PABAK: the prevalence-adjusted, bias-adjusted kappa — `(k·po − 1)/(k − 1)`
  over the k classes present. 1.0 trivially at full agreement; `nil` for a
  single-class set that is not in full agreement (undefined there).
  """
  def pabak(pairs), do: summarise(pairs).pabak

  @doc """
  Gwet's AC1: agreement with the chance term
  `pe_γ = (1/(k−1)) Σ π_c (1 − π_c)` over pooled marginals π. Unlike kappa it
  stays stable under skewed prevalence, which is why design §2 names it as
  the alongside statistic when a class drops below 10%.
  """
  def ac1(pairs), do: summarise(pairs).ac1

  @doc "Classes present (on at least one side), sorted for stable output."
  def classes(pairs) do
    pairs
    |> Enum.flat_map(fn {a, b} -> [a, b] end)
    |> Enum.uniq()
    |> Enum.sort_by(&to_string/1)
  end

  @doc "The κ-gate: the headline statistic (§2 rule) reaches `min` (default 0.7)."
  def gate?(summary, min \\ @gate_default)

  def gate?(_summary, nil), do: true

  def gate?(summary, min) do
    case summary.headline do
      {_, value} when is_float(value) or is_integer(value) -> value >= min
      _ -> false
    end
  end

  # --- internals ------------------------------------------------------------

  defp agreements_on(pairs, class) do
    Enum.count(pairs, fn {a, b} -> a == class and b == class end)
  end

  defp first_counts(pairs, classes) do
    init = Map.new(classes, fn c -> {c, 0} end)

    {first, second} =
      Enum.reduce(pairs, {init, init}, fn {a, b}, {f, s} ->
        {%{f | a => f[a] + 1}, %{s | b => s[b] + 1}}
      end)

    %{first: first, second: second}
  end

  defp first_marginals(counts, classes, n) do
    Map.new(classes, fn c -> {c, counts.first[c] / n} end)
  end

  defp second_marginals(counts, classes, n) do
    Map.new(classes, fn c -> {c, counts.second[c] / n} end)
  end

  defp ac1_pe(counts, classes, n) do
    k = length(classes)

    if k < 2 do
      if counts.first == counts.second, do: 0.0, else: 1.0
    else
      Enum.reduce(classes, 0.0, fn c, acc ->
        pi = (counts.first[c] + counts.second[c]) / (2 * n)
        acc + pi * (1 - pi)
      end) / (k - 1)
    end
  end
end
