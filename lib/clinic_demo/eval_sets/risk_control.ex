defmodule ClinicDemo.EvalSets.RiskControl do
  @moduledoc """
  The conformal-risk-control arithmetic the eval-sets design states (§3, §5) —
  the formulas only, as pure functions. What is *not* here: the calibration
  runs, split machinery and audit pipeline that would consume them (queued;
  the design's §6 split discipline is a programme of its own).

  §3, the bound being used. Conformal risk control for a monotone loss over
  selective auto-admission: the loss for calibration item i at threshold λ is
  `Lᵢ(λ) = 1` iff the model auto-admits i (score ≥ λ) **and** the gold label
  is not `supports`. The threshold is chosen by the fixed quantile rule

      λ̂ = inf { λ : ( Σᵢ Lᵢ(λ) + 1 ) / (n + 1) ≤ α }

  which — under exchangeability, monotone loss, the fixed rule (not a grid
  search minimiser) and a marginal (not per-item) reading — guarantees
  `E[L(λ̂)] ≤ α`. To certify conditional error ≤ 2% at planning coverage ≥ 80%,
  set α = 0.8 × 2% = 0.016. Feasibility rearranges to `n ≥ (e + 1)/α − 1`.

  §5, the audit alarm. Per family × region per window, m auto-admitted facts
  are audited; alarm at the smallest k with `P(Binomial(m, α₀) ≥ k) ≤ 0.05`,
  where α₀ is the family's *certified* level, not a constant.
  """

  @doc """
  Smallest calibration n at which `e` observed wrong auto-admissions still
  meet budget `α`: the design's `n ≥ (e + 1)/α − 1` (its worked table at
  α = 0.016: e 0→62, 1→124, 2→187, 3→249, 4→312).
  """
  def min_calibration_n(e, alpha) do
    ((e + 1) / alpha - 1) |> Float.ceil() |> trunc()
  end

  @doc """
  The most errors `e` a calibration run of `n` may show and still meet
  budget `α` (the feasibility condition read the other way). nil when even
  zero errors exceed the budget.
  """
  def tolerable_errors(n, alpha) do
    case alpha * (n + 1) - 1 do
      bound when bound < 0 -> nil
      bound -> trunc(Float.floor(bound))
    end
  end

  @doc """
  The §3 quantile rule. `scored` is a list of `{score, gold_supports?}`;
  the loss admits an error when `score ≥ λ` and the gold is not `supports`.
  Returns the smallest observed score λ with
  `(Σ Lᵢ(λ) + 1)/(n + 1) ≤ α`, or nil when no threshold meets the budget —
  including the zero-error case `1/(n + 1) > α`, which means the family
  cannot certify at this α at all (design §3's "bound doing its job").
  """
  def threshold(scored, alpha) do
    n = length(scored)

    scored
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.find(fn lam ->
      errors = Enum.count(scored, fn {score, supports?} -> score >= lam and not supports? end)
      (errors + 1) / (n + 1) <= alpha
    end)
  end

  @doc """
  The §5 alarm rule: the smallest `k` with `P(Binomial(m, α₀) ≥ k) ≤ level`
  (default 0.05). At m = 200, α₀ = 0.02 this is 8 — the design's window rule.
  """
  def alarm_threshold(m, alpha0, level \\ 0.05)

  def alarm_threshold(m, alpha0, level) when m > 0 and alpha0 > 0 do
    1..m
    |> Enum.find(fn k -> binomial_ge(m, k, alpha0) <= level end)
  end

  def alarm_threshold(_m, _alpha0, _level), do: nil

  @doc "Exact-ish upper tail `P(Binomial(m, p) ≥ k)` by direct summation."
  def binomial_ge(m, k, p) when k <= m do
    Enum.reduce(k..m//1, 0.0, fn i, acc -> acc + binomial_term(m, i, p) end)
  end

  def binomial_ge(_m, _k, _p), do: 0.0

  defp binomial_term(m, i, p) do
    # C(m, i) stays an exact integer (Elixir bignums); tiny power terms may
    # underflow to 0.0, which only zeroes terms too small to matter.
    choose(m, i) * :math.pow(p, i) * :math.pow(1.0 - p, m - i)
  end

  # Exact iterative binomial coefficient: after step i the accumulator is
  # C(n - r + i, i), an integer, so every division is exact.
  defp choose(_n, r) when r <= 0, do: if(r == 0, do: 1, else: 0)

  defp choose(n, r) do
    r = min(r, n - r)

    Enum.reduce(1..r//1, 1, fn i, acc -> div(acc * (n - r + i), i) end)
  end
end
