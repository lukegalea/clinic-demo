defmodule Mix.Tasks.ClinicDemo.EvalSets.Agreement do
  @shortdoc "Inter-rater agreement statistics for a labelled eval set (S1-25 §2)"

  @moduledoc """
  Loads a labelled eval set and prints the full agreement block — the same
  shape as the spike-0 second-labelling record in
  `docs/spikes/system-one-spike-0.md` — then applies the κ-gate.

      mix clinic_demo.eval_sets.agreement             # the spike0 set
      mix clinic_demo.eval_sets.agreement spike0
      mix clinic_demo.eval_sets.agreement --min 0.9 spike0

  Reported, per design §2: raw agreement, Cohen's κ with its chance term p_e
  per family (answer layer) and pooled (disposition layer), class prevalence,
  per-class specific agreement, and — when any class present sits below 10%
  prevalence — PABAK and Gwet's AC1, which then carry the gate with the
  prevalence stated. Prevalence is always printed; κ is never dropped in
  favour of raw agreement.

  Exits non-zero when the gate fails: the headline statistic of the
  disposition layer (design §2 gates the disposition label) below `--min`
  (default 0.7).

  No database, no model, no network: reads the set's `items.jsonl`, runs
  `ClinicDemo.EvalSets.Agreement`, prints, gates.
  """

  use Mix.Task

  alias ClinicDemo.EvalSets.{Agreement, Store}

  @switches [min: :float]

  @impl Mix.Task
  def run(argv) do
    # Only what this task needs: no repo, no services (design law 23).
    Mix.Task.run("app.config")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    name = List.first(args) || "spike0"
    min = Keyword.get(opts, :min, Agreement.default_gate())

    set = Store.load(name)
    items = set.items
    unpaired = Store.unpaired(items)

    shell = Mix.shell()
    shell.info("eval set: #{set.name} — #{Path.relative_to(set.path, File.cwd!())}")
    shell.info("items: #{length(items) - length(unpaired)} paired, #{length(unpaired)} unpaired")

    labellers =
      items
      |> Enum.map(&{Store.first_labeller(&1), Store.second_labeller(&1)})
      |> Enum.uniq()

    for {first, second} <- labellers do
      shell.info(~s(labellers: first "#{first}" · second "#{second}"))
    end

    shell.info("")

    # Per family, the answer layer (each question's own answer space).
    shell.info("per family, answer layer:")

    for family <- Store.families(items) do
      pairs = Store.answer_pairs(items, family)
      s = Agreement.summarise(pairs)

      shell.info(
        "  #{pad(family)} n=#{s.n}  agreement #{s.agreements}/#{s.n} = #{r4(s.agreement)}  kappa #{num(s.kappa)} (pe #{r4(s.pe)})#{extreme_note(s)}"
      )
    end

    # Pooled, the disposition layer — the one design §2 gates on.
    pairs = Store.disposition_pairs(items)
    s = Agreement.summarise(pairs)

    shell.info("")
    shell.info("combined, disposition layer (#{Enum.join(s.classes, " / ")}):")

    shell.info(
      "  n=#{s.n}  agreement #{s.agreements}/#{s.n} = #{r4(s.agreement)}  kappa #{num(s.kappa)} (pe #{r4(s.pe)})"
    )

    shell.info("  prevalence: #{prevalence_line(s)}")

    if s.extreme_prevalence? do
      shell.info(
        "  classes below the 10% rule: #{Enum.map_join(s.extreme_classes, ", ", &(&1 <> " " <> r4_percent(s.prevalence[&1])))} — PABAK #{num(s.pabak)} · Gwet AC1 #{num(s.ac1)} reported alongside (design §2)"
      )
    end

    shell.info("")

    {stat, value} = s.headline
    passed? = Agreement.gate?(s, min)

    shell.info(
      "gate (disposition layer, #{stat}, threshold >= #{min}): #{if passed?, do: "PASS (#{num(value)})", else: "FAIL (#{num(value)})"}"
    )

    unless passed? do
      shell.error(
        "kappa-gate failed for set #{inspect(set.name)}: headline #{stat} #{num(value)} < #{min}. Per design §2 the family's guidelines are revised and the disputed items re-labelled; the set is not used in the meantime."
      )

      exit({:shutdown, 1})
    end
  end

  # --- output helpers ---------------------------------------------------------

  defp pad(family), do: String.pad_trailing(family, 18)

  defp num(nil), do: "n/a"
  defp num(value), do: :erlang.float_to_binary(Float.round(value * 1.0, 4), decimals: 4)

  defp r4(nil), do: "n/a"
  defp r4(value), do: :erlang.float_to_binary(Float.round(value * 1.0, 4), decimals: 4)

  defp r4_percent(value), do: r4(value * 100) <> "%"

  defp extreme_note(s) do
    if s.extreme_prevalence?,
      do: "  [extreme prevalence: #{Enum.join(s.extreme_classes, ", ")}]",
      else: ""
  end

  defp prevalence_line(s) do
    s.classes
    |> Enum.map_join(" · ", fn c -> "#{c} #{r4_percent(s.prevalence[c])}" end)
  end
end
