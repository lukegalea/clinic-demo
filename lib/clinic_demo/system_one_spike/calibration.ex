defmodule ClinicDemo.SystemOneSpike.Calibration do
  @moduledoc """
  The calibration half of the eval-sets programme (S1-25), wired to the
  spike: turns one spike spec's answers over the **calibration split**
  into a §8.1-shaped calibration run — the record shape `ash_judgments`'
  `mix ash_judgments.calibrate` task records through its
  `CalibrationRun` store (the "calibrate-compatible" format).

  clinic-demo does not depend on `ash_judgments`; this module is the
  package-compatible PRODUCER, not a reimplementation of the store. The
  arithmetic it mirrors is `ClinicDemo.EvalSets.RiskControl` (the
  reference implementation of the same formulas) and the spike's own
  metrics; the §8.1 field names are pinned by tests against the
  documented record contract:

  `family, question_hashes, model_version, model_digest,
  runtime_version, eval_set_hash, region, n, n_per_class, metrics,
  ece, brier, conformal_thresholds, source, created_by,
  observations_digest, result, proposed_band_table, pass_bar,
  finished_at` — all numbers as decimal strings.

  ## The readings this module fixes (flagged, minimal)

  * **The conformal score.** noul: `p` against `gold == true`
    (the disposition layer's `supports`). choice: the top probability
    against `gold != "insufficient_information"` — the loss admits an
    error when the model confidently chose an option while the right
    answer was to abstain. Literal design §3 reading.
  * **The question hash.** SHA-256 over the action's question text (the
    `run evaluate(...)` description) — content-derived, stable across
    runs, no registry on this side of the fence.
  * **The model digest.** SHA-256 over `<model_id>/<result_model>` —
    the requested instrument plus what the server reported. A run whose
    rows disagree on what the server reported is refused: that is two
    runs, not one.
  * **The region.** `"homelab"` — the dev zone the instruments live in.
  * **The result.** The same n-threshold discipline as `ash_judgments`'
    proposal trigger: below `min_n` (62 at α = 0.016) nothing is
    proposed and the negative result is kept (`result: "no_table"`, the
    findings on the artefact wrapper, never invented into the record).
    Publication stays ash_decisions' lifecycle; certification stays a
    person's act.
  """

  alias ClinicDemo.EvalSets.RiskControl
  alias ClinicDemo.SystemOneSpike
  alias ClinicDemo.SystemOneSpike.Metrics

  @alpha 0.016
  @min_n RiskControl.min_calibration_n(0, @alpha)
  @region "homelab"
  @created_by "mix clinic.calibrate"

  # The spike's calibration families and their §8.1 answer kinds.
  @families %{notes_follow_up: :noul, presenting_urgency: :choice}

  # The exact field set `ash_judgments`' §8.1 CalibrationRun :record
  # action accepts — a run map never carries another key.
  @run_fields ~w(family question_hashes model_version model_digest runtime_version
                 eval_set_hash region n n_per_class metrics ece brier conformal_thresholds
                 source created_by observations_digest result proposed_band_table pass_bar
                 finished_at)a

  @doc "The target risk budget α (error ≤ 2% at planning coverage ≥ 80%)."
  def alpha, do: @alpha

  @doc "The n below which nothing is proposed (the design's e=0 row at α = 0.016)."
  def min_n, do: @min_n

  @doc "The region recorded on these runs."
  def region, do: @region

  @doc "The spike's calibration families, as `%{action_name => answer_kind}`."
  def families, do: @families

  @doc "The §8.1 record field set — the calibrate-compatible contract."
  def run_fields, do: @run_fields

  # --- the split --------------------------------------------------------------

  @doc """
  The calibration split's items: the rows the companion assigns to
  `"calibration"`. Rows the companion does not name are dropped — the
  assignment is total over the set, so a drop means drift, and the task
  verifies the companion before it ever calls a model.
  """
  def calibration_items(items, companion) do
    assignment = companion["assignment"] || %{}

    Enum.filter(items, &(Map.get(assignment, &1["id"]) == "calibration"))
  end

  # --- the §8.1 run map ---------------------------------------------------------

  @doc """
  The §8.1-shaped run map for one `(spec, family)` over the spike's
  result rows (the maps `ClinicDemo.SystemOneSpike.Runner.call/5`
  returns). `opts` requires `:eval_set_hash` — the set version the run
  consumed.

  Returns `{:ok, run}` — whose keys are exactly `run_fields/0` — or
  `{:error, reason}`: no answered row, no run (an artefact must never
  lie about an instrument).
  """
  def run_map(spec, family, rows, opts) do
    eval_set_hash = Keyword.fetch!(opts, :eval_set_hash)
    kind = Map.fetch!(@families, family)
    answered = Enum.filter(rows, & &1["ok"])

    with {:ok, model_version, model_digest} <- identity(spec, answered) do
      pairs = pairs(kind, answered)
      metrics = metrics(kind, pairs)
      conformal = conformal_thresholds(kind, answered)

      run = %{
        family: Atom.to_string(family),
        question_hashes: [question_hash(family)],
        model_version: model_version,
        model_digest: model_digest,
        runtime_version: Application.spec(:req_llm, :vsn) |> to_string(),
        eval_set_hash: eval_set_hash,
        region: @region,
        n: length(answered),
        n_per_class: n_per_class(answered),
        metrics: metrics,
        ece: metrics["ece"],
        brier: metrics["brier"],
        conformal_thresholds: conformal,
        source: "eval_set",
        created_by: @created_by,
        observations_digest: observations_digest(answered),
        pass_bar: %{},
        finished_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      }

      proposal_result = propose(run)

      {:ok,
       run
       |> Map.put(:result, result_of(proposal_result))
       |> Map.put(:proposed_band_table, proposal_of(proposal_result))}
    end
  end

  # The instrument identity: what the server reported must agree across
  # the run's rows.
  defp identity(spec, answered) do
    reported = answered |> Enum.map(& &1["result_model"]) |> Enum.uniq()

    cond do
      answered == [] ->
        {:error, :no_answered_rows}

      reported == [nil] or length(reported) > 1 ->
        {:error, {:mixed_or_missing_result_model, reported}}

      true ->
        model_id = SystemOneSpike.Models.model_id(spec)
        {:ok, hd(reported), digest(model_id <> "/" <> hd(reported))}
    end
  end

  @doc """
  The n-threshold discipline, mirrored from the design: below `min_n`
  nothing is proposed (`{:refused, findings}` — negative results are
  kept), as without an earned threshold at α. A passing run proposes
  `{:ok, proposal}` — the DRAFT band table as data; publication stays
  ash_decisions' lifecycle.
  """
  def propose(run) do
    cond do
      run.n < @min_n ->
        {:refused,
         [
           %{
             "finding" => "n_below_min",
             "family" => run.family,
             "required_n" => @min_n,
             "actual_n" => run.n,
             "model_digest" => run.model_digest
           }
         ]}

      threshold(run) == nil ->
        {:refused,
         [
           %{
             "finding" => "no_conformal_threshold_at_alpha",
             "family" => run.family,
             "alpha" => Float.to_string(@alpha)
           }
         ]}

      true ->
        {:ok,
         %{
           "definition_key" => "bands_" <> run.family,
           "family_tag" => "judgments:family:" <> run.family,
           "run_id" => nil,
           "question_hash" => hd(run.question_hashes),
           "model_digest" => run.model_digest,
           "runtime_version" => run.runtime_version,
           "region" => run.region,
           "alpha" => Float.to_string(@alpha),
           "thresholds" => %{"threshold" => threshold(run)},
           "note" =>
             "PROPOSED — never published here; a person certifies, ash_decisions activates"
         }}
    end
  end

  defp result_of({:ok, _}), do: "proposed_table"
  defp result_of({:refused, _}), do: "no_table"

  defp proposal_of({:ok, proposal}), do: proposal
  defp proposal_of({:refused, _}), do: nil

  defp threshold(run), do: run.conformal_thresholds[Float.to_string(@alpha)]["threshold"]

  defp conformal_thresholds(kind, answered) do
    case RiskControl.threshold(scored_pairs(kind, answered), @alpha) do
      nil -> %{}
      lambda -> %{Float.to_string(@alpha) => %{"threshold" => decimal_string(lambda)}}
    end
  end

  # --- pairs, scores, metrics ---------------------------------------------------

  defp pairs(:noul, answered), do: Enum.map(answered, &{&1["answer"]["p"], &1["gold"]})

  defp pairs(:choice, answered),
    do: Enum.map(answered, &{&1["answer"]["value"], &1["gold"]})

  @doc """
  The §3 scored pairs: `{score, gold_supports?}` — noul's score is `p`
  against `gold == true`; choice's is the top probability against
  `gold != "insufficient_information"` (the abstention reading).
  """
  def scored_pairs(:noul, answered),
    do: Enum.map(answered, &{&1["answer"]["p"], &1["gold"] == true})

  def scored_pairs(:choice, answered),
    do:
      Enum.map(
        answered,
        &{top_p(&1["answer"]["probabilities"]), &1["gold"] != "insufficient_information"}
      )

  defp top_p(probabilities) when is_map(probabilities) do
    probabilities |> Map.values() |> Enum.max(fn -> nil end)
  end

  defp top_p(_), do: nil

  @doc "The §8.1 metrics object for one family's `(prediction, gold)` pairs — decimal strings."
  def metrics(:noul, pairs) do
    %{"reliability_bins" => reliability_bins(pairs), "ece" => ece(pairs), "brier" => brier(pairs)}
  end

  def metrics(:choice, pairs) do
    classes =
      pairs
      |> Enum.flat_map(fn {value, gold} -> [to_s(value), to_s(gold)] end)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)

    per_class =
      Map.new(classes, fn class ->
        predicted = Enum.count(pairs, &(to_s(elem(&1, 0)) == class))
        golded = Enum.count(pairs, &(to_s(elem(&1, 1)) == class))
        correct = Enum.count(pairs, &(to_s(elem(&1, 0)) == class and to_s(elem(&1, 1)) == class))

        {class,
         %{
           "precision" => ratio(correct, predicted),
           "recall" => ratio(correct, golded),
           "n" => Integer.to_string(golded)
         }}
      end)

    accuracy =
      if pairs == [] do
        nil
      else
        ratio(Enum.count(pairs, &(to_s(elem(&1, 0)) == to_s(elem(&1, 1)))), length(pairs))
      end

    %{"per_class" => per_class, "accuracy" => accuracy}
  end

  # Tenth-width reliability bins, the §8.1 shape (the top bin closed at
  # 1.0) — the decimal-string mirror of the package's Metrics.
  def reliability_bins(pairs) do
    for i <- 0..9, into: %{} do
      lower = i / 10

      members =
        Enum.filter(pairs, fn {p, _} ->
          p >= lower and (p < lower + 1 / 10 or (i == 9 and p <= 1.0))
        end)

      n = length(members)
      confidence = if n == 0, do: nil, else: maybe_string(mean(Enum.map(members, &elem(&1, 0))))

      accuracy =
        if n == 0, do: nil, else: maybe_string(mean(Enum.map(members, &bool(elem(&1, 1)))))

      {"bin_#{i}",
       %{"n" => Integer.to_string(n), "confidence" => confidence, "accuracy" => accuracy}}
    end
  end

  defp ece(pairs), do: pairs |> Metrics.ece() |> maybe_string()
  defp brier(pairs), do: pairs |> Metrics.brier() |> maybe_string()

  defp n_per_class(answered), do: Map.new(Enum.frequencies_by(answered, &to_s(&1["gold"])))

  defp observations_digest(answered) do
    answered |> Enum.map(& &1["item_id"]) |> Enum.sort() |> Enum.join("\n") |> digest()
  end

  @doc "The §8.1 question hash: SHA-256 over the action's question text."
  def question_hash(family) do
    digest(Ash.Resource.Info.action(SystemOneSpike, family).description)
  end

  defp digest(content) do
    "sha256:" <> Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  # --- rendering helpers ---------------------------------------------------------

  defp ratio(_num, 0), do: nil
  defp ratio(num, den), do: decimal_string(num / den)

  defp mean([]), do: nil
  defp mean(values), do: Enum.sum(values) / length(values)

  defp bool(true), do: 1.0
  defp bool(false), do: 0.0

  defp maybe_string(nil), do: nil
  defp maybe_string(value) when is_float(value), do: decimal_string(value)

  defp decimal_string(value) when is_float(value),
    do: :erlang.float_to_binary(value, [:short])

  defp decimal_string(value) when is_integer(value), do: Integer.to_string(value)

  defp to_s(nil), do: nil
  defp to_s(value) when is_atom(value), do: Atom.to_string(value)
  defp to_s(value), do: to_string(value)
end
