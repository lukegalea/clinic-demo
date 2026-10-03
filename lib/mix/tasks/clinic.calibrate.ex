defmodule Mix.Tasks.Clinic.Calibrate do
  @shortdoc "Calibrates the spike questions over the eval set's calibration split"
  @moduledoc """
  S1-25, the calibration-run harness wired to spike-0: runs the spike's
  own call path over the **calibration split** (§6, the split
  companion), and records the results as a calibration artefact in the
  calibrate-compatible format (the §8.1 run maps
  `ash_judgments`' `mix ash_judgments.calibrate` task records through
  its CalibrationRun store).

      mix clinic.calibrate spike0 --transport record --set calibration-2026-10-02
      mix clinic.calibrate spike0 --transport live --specs laya
      mix clinic.calibrate spike0 --transport record --set s2 --unload

  ## Options

    * `--transport` — `record` (default: to the model AND into the
      fixture set, so the run replays), `live`, `replay` or `stub`.
      `record` and `live` need `OLLAYA_BASE_URL`; source
      `~/.config/system-one/endpoints.env` first (`scripts/spike0-live.sh` does).
    * `--set` — the fixture set recorded into
      (`priv/fixtures/system_one/spike0/replay/<set>.jsonl`). One
      invocation is one complete fixture set: recording starts the set
      afresh. Default `calibration-<today>`.
    * `--specs` — comma-separated, from `laya,winnow`. Default both.
    * `--out` — results directory label under
      `priv/fixtures/system_one/spike0/results/`. Default
      `calibration-<today>`.
    * `--unload` — after the runs, ask each model's host to unload
      (`POST /api/decide` with `{"model": …, "keep_alive": 0}`), through
      the same host routing the calls resolved. Best effort: a failed
      unload warns, never fails the run.
    * `--limit` — items per family, for a quick check.

  The artefact lands at `<out>/calibration.json`: the §8.1 run map per
  `(spec, family)` — field-for-field what the package's CalibrationRun
  store records — beside the raw rows (`rows.jsonl`) and a summary
  (`summary.md`). Nothing publishes a table through this task: the
  proposal discipline (min_n, certification, publication) lives in
  `ash_judgments`, and the run maps carry the honest `result` either
  way.
  """

  use Mix.Task

  alias ClinicDemo.EvalSets.Split
  alias ClinicDemo.SystemOneSpike.Calibration
  alias ClinicDemo.SystemOneSpike.Models
  alias ClinicDemo.SystemOneSpike.Runner

  @switches [
    transport: :string,
    set: :string,
    specs: :string,
    out: :string,
    unload: :boolean,
    limit: :integer
  ]

  @results_dir "priv/fixtures/system_one/spike0/results"
  @set_name "spike0"

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    # Only what the spike needs: no repo, no endpoint, no process engine.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:telemetry, :req, :req_llm])

    transport = transport(Keyword.get(opts, :transport, "record"), set(opts))

    if match?({:record, _}, transport) or transport == :live do
      unless Models.live_configured?() do
        Mix.raise("OLLAYA_BASE_URL is not set. Source ~/.config/system-one/endpoints.env first.")
      end
    end

    companion = load_companion()
    items = calibration_items(companion, opts)
    specs = specs(opts[:specs])

    if match?({:record, _}, transport), do: reset_set(elem(transport, 1))

    %{rows: rows, runs: runs, failures: failures} =
      with_telemetry(fn ->
        calibrate(specs, transport, items, companion["eval_set_hash"], opts)
      end)

    unload(specs, opts[:unload] == true)

    out = Keyword.get(opts, :out, "calibration-" <> default_label())
    dir = Path.join(@results_dir, out)
    write(dir, rows, runs, failures, transport, companion, opts)

    Mix.shell().info(summary_text(runs, failures, dir))
  end

  # The calibration split, verified against the companion: a drifted
  # companion refuses the run before any model is called.
  defp load_companion do
    case Split.load_companion(@set_name) do
      :missing ->
        Mix.raise(
          "no split companion for #{@set_name} — run mix clinic_demo.eval_sets.splits --write first"
        )

      {:ok, companion} ->
        companion
    end
  end

  defp calibration_items(companion, opts) do
    items = Runner.items()

    case Split.verify(@set_name, items) do
      :ok ->
        split = Calibration.calibration_items(items, companion)

        if split == [], do: Mix.raise("the calibration split of #{@set_name} is empty")

        Mix.shell().info("calibration split: #{length(split)} items")
        limit_items(split, opts[:limit])

      {:drift, what} ->
        Mix.raise(
          "split companion drifted (#{Enum.join(what, ", ")}) — re-split deliberately, never silently"
        )
    end
  end

  defp transport("record", set), do: {:record, set}
  defp transport("live", _set), do: :live
  defp transport("replay", set), do: {:replay, set}
  defp transport("stub", _set), do: :stub

  defp transport(other, _set),
    do: Mix.raise("unknown --transport #{inspect(other)}; expected live, record, replay or stub")

  defp set(opts), do: Keyword.get(opts, :set, "calibration-" <> default_label())
  defp default_label, do: Date.utc_today() |> Date.to_iso8601()

  defp specs(nil), do: Models.names()

  defp specs(csv) do
    csv
    |> String.split(",", trim: true)
    |> Enum.map(fn name ->
      case Models.parse_name(String.trim(name)) do
        {:ok, spec} -> spec
        {:error, message} -> Mix.raise(message)
      end
    end)
  end

  defp limit_items(items, nil), do: items

  defp limit_items(items, n) do
    items
    |> Enum.group_by(& &1["question"])
    |> Enum.flat_map(fn {_, list} -> Enum.take(list, n) end)
  end

  # The runner's exchange telemetry fires in the calling process, so the
  # rows carry the same provenance/status/latency they do in the spike
  # task (Runner.run's handler, attached here for the calibrate loop).
  defp with_telemetry(fun) do
    handler_id = "clinic-calibrate-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler_id,
      ClinicDemo.SystemOneSpike.Transport.event(),
      &Runner.handle_exchange/4,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end
  end

  # One invocation is one complete fixture set: recording starts afresh.
  defp reset_set(set) do
    path = ClinicDemo.SystemOneSpike.Transport.fixture_path(set)

    if File.exists?(path), do: File.rm!(path)
    ClinicDemo.SystemOneSpike.Transport.forget(set)
  end

  # The spike's own call path, one row per calibration item; then the
  # §8.1 run map per (spec, family). A family with no answered row is a
  # recorded failure, never a fabricated run.
  defp calibrate(specs, transport, items, eval_set_hash, _opts) do
    rows_by =
      for spec <- specs, {family, _kind} <- Calibration.families(), into: %{} do
        rows =
          items
          |> Enum.filter(&(&1["question"] == Atom.to_string(family)))
          |> Enum.map(&Runner.call(spec, transport, family, &1, "r1"))

        {{spec, family}, rows}
      end

    {ok_runs, failures} =
      rows_by
      |> Enum.map(fn {{spec, family} = key, rows} ->
        case Calibration.run_map(spec, family, rows, eval_set_hash: eval_set_hash) do
          {:ok, run} ->
            {key, {:ok, run}}

          {:error, reason} ->
            Mix.shell().error("#{spec} #{family}: no run recorded — #{inspect(reason)}")
            {key, {:error, reason}}
        end
      end)
      |> Enum.split_with(fn {_key, outcome} -> match?({:ok, _}, outcome) end)

    %{
      rows: rows_by |> Map.values() |> List.flatten(),
      runs: Map.new(ok_runs, fn {key, {:ok, run}} -> {key, run} end),
      failures: Map.new(failures, fn {key, {:error, reason}} -> {key, reason} end)
    }
  end

  # Best-effort, through the same host routing the calls resolved;
  # never fails the run.
  defp unload(_specs, false), do: :ok

  defp unload(specs, true) do
    for spec <- specs do
      model_id = Models.model_id(spec)
      base = Models.ollaya_base_url(model_id)

      case Req.post(base <> "/api/decide", json: %{model: model_id, keep_alive: 0}) do
        {:ok, %Req.Response{status: status}} when status in 200..299 ->
          Mix.shell().info("unloaded #{model_id} (#{status})")

        {:ok, %Req.Response{status: status}} ->
          Mix.shell().error("unload of #{model_id} returned #{status} — leaving it as-is")

        {:error, reason} ->
          Mix.shell().error("unload of #{model_id} failed: #{inspect(reason)} — leaving it as-is")
      end
    end
  end

  defp write(dir, rows, runs, failures, transport, companion, opts) do
    File.mkdir_p!(dir)

    artefact = %{
      "format" => "ash_judgments.calibrate-compatible",
      "note" =>
        "§8.1 run maps — field-for-field what ash_judgments' CalibrationRun :record accepts; nothing is published here",
      "set" => @set_name,
      "split" => "calibration",
      "eval_set_hash" => companion["eval_set_hash"],
      "salt" => companion["salt"],
      "alpha" => Calibration.alpha(),
      "min_n" => Calibration.min_n(),
      "region" => Calibration.region(),
      "transport" => transport_label(transport),
      "limit" => opts[:limit],
      "ran_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      "runs" => stringified_runs(runs),
      "failures" =>
        Map.new(failures, fn {{spec, family}, reason} ->
          {"#{spec}.#{family}", inspect(reason)}
        end)
    }

    File.write!(Path.join(dir, "calibration.json"), JSON.encode!(artefact) <> "\n")

    lines = Enum.map_join(rows, "", &(JSON.encode!(&1) <> "\n"))
    File.write!(Path.join(dir, "rows.jsonl"), lines)

    File.write!(Path.join(dir, "summary.md"), summary_markdown(artefact, runs, failures))
  end

  defp stringified_runs(runs) do
    Map.new(runs, fn {{spec, family}, run} ->
      {"#{spec}.#{family}", run |> Map.new(fn {k, v} -> {Atom.to_string(k), jsonable(v)} end)}
    end)
  end

  defp jsonable(%Date{} = d), do: Date.to_iso8601(d)

  defp jsonable(v) when is_map(v),
    do: v |> Map.new(fn {k, x} -> {to_string(k), jsonable(x)} end) |> Enum.sort() |> Map.new()

  defp jsonable(v) when is_list(v), do: Enum.map(v, &jsonable/1)
  defp jsonable(v), do: v

  defp transport_label({mode, set}), do: "#{mode}:#{set}"
  defp transport_label(mode), do: Atom.to_string(mode)

  defp threshold_of(run) do
    run.conformal_thresholds[Float.to_string(Calibration.alpha())]["threshold"]
  rescue
    _ -> nil
  end

  defp summary_text(runs, failures, dir) do
    lines =
      Enum.map(runs, fn {{spec, family}, run} ->
        "  #{spec} #{family}: n=#{run.n} result=#{run.result} " <>
          "ece=#{inspect(run.ece)} threshold=#{inspect(threshold_of(run))}"
      end)

    lines =
      lines ++
        Enum.map(failures, fn {{spec, family}, reason} ->
          "  #{spec} #{family}: FAILED #{inspect(reason)}"
        end)

    ["calibration runs:", lines, "wrote #{Path.join(dir, "calibration.json")}"]
    |> List.flatten()
    |> Enum.join("\n")
  end

  defp summary_markdown(artefact, runs, failures) do
    header = """
    # Calibration over the calibration split (#{artefact["ran_at"]})

    Set `#{artefact["set"]}`, split `calibration`, eval_set_hash `#{artefact["eval_set_hash"]}`.
    Transport `#{artefact["transport"]}`; α = #{artefact["alpha"]}, min_n = #{artefact["min_n"]}.
    Calibrate-compatible §8.1 run maps: `calibration.json`; raw rows: `rows.jsonl`.
    """

    run_lines =
      Enum.map(runs, fn {{spec, family}, run} ->
        "- **#{spec} / #{family}** — n=#{run.n}, result `#{run.result}`" <>
          ", ece #{inspect(run.ece)}, brier #{inspect(run.brier)}" <>
          ", threshold #{inspect(threshold_of(run))}"
      end)

    failure_lines =
      Enum.map(failures, fn {{spec, family}, reason} ->
        "- **#{spec} / #{family}** — FAILED: `#{inspect(reason)}`"
      end)

    Enum.join([header, "## Runs", Enum.join(run_lines ++ failure_lines, "\n"), ""], "\n")
  end
end
