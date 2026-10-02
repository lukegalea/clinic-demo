defmodule Mix.Tasks.ClinicDemo.EvalSets.Splits do
  @shortdoc "Split assignment and eval_set_hash for a labelled eval set (S1-25 §6)"

  @moduledoc """
  Computes the §6 split assignment for an eval set and reports it: the
  `eval_set_hash`, the salt and proportions in force, and the split counts
  per family.

      mix clinic_demo.eval_sets.splits spike0
      mix clinic_demo.eval_sets.splits --write spike0   # pin the companion
      mix clinic_demo.eval_sets.splits --check spike0   # verify, exit 1 on drift

  The assignment is a pure function of `(salt, eval_set_hash, ids)` — see
  `ClinicDemo.EvalSets.Split`. `--write` records it beside the items
  (`splits.json`; never inside `items.jsonl`) with its hash, salt and
  proportions, pinning this set version's assignment. `--check` recomputes
  and compares: drift means the fixture changed without a deliberate
  re-split (a re-split is a new set version with a new hash). Split
  proportions are reported here because §6 requires them with every
  calibration run.

  No database, no model, no network (law 23).
  """

  use Mix.Task

  alias ClinicDemo.EvalSets.Split
  alias ClinicDemo.EvalSets.Store

  @switches [salt: :string, write: :boolean, check: :boolean]

  @impl Mix.Task
  def run(argv) do
    # Only what this task needs: no repo, no services (law 23).
    Mix.Task.run("app.config")

    {opts, args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    name = List.first(args) || "spike0"
    set = Store.load(name)
    salt = Keyword.get(opts, :salt, Split.default_salt())

    result = Split.assign(set.items, salt: salt)

    shell = Mix.shell()
    shell.info("eval set: #{set.name} — #{Path.relative_to(set.path, File.cwd!())}")
    shell.info("eval_set_hash: sha256:#{result.eval_set_hash}")
    shell.info("salt: \"#{result.salt}\"")

    shell.info(
      "proportions: #{Enum.map_join(Enum.sort(result.proportions), " / ", fn {name, share} -> "#{name} #{share}" end)}"
    )

    shell.info("")

    counts = Split.counts_by_family(set.items, result.assignment)

    for {family, family_counts} <- counts, family != :total do
      shell.info(
        "  #{pad(family)} n=#{Enum.sum(Map.values(family_counts))}  #{counts_line(family_counts)}"
      )
    end

    shell.info("  #{pad("total")} n=#{length(set.items)}  #{counts_line(counts.total)}")

    cond do
      opts[:write] ->
        path = Split.write_companion(set.name, result)
        shell.info("\npinned assignment to #{Path.relative_to(path, File.cwd!())}")

      opts[:check] ->
        case Split.verify(set.name, set.items, salt: salt) do
          :ok ->
            shell.info("\ncompanion matches this set version: OK")

          {:drift, fields} ->
            shell.error(
              "split drift for set #{inspect(set.name)} (#{Enum.join(fields, ", ")}): the fixture changed " <>
                "without a deliberate re-split, or the companion is stale. A re-split is a new set version " <>
                "with a new eval_set_hash — moving a row between splits is prohibited (design §6)."
            )

            exit({:shutdown, 1})
        end

      true ->
        :ok
    end
  end

  # --- output helpers ---------------------------------------------------------

  defp pad(name), do: String.pad_trailing(to_string(name), 18)

  defp counts_line(counts) do
    Split.split_names()
    |> Enum.map_join(" · ", fn name -> "#{name} #{Map.fetch!(counts, name)}" end)
  end
end
