defmodule Mix.Tasks.Clinic.Spike0 do
  @shortdoc "Runs System One spike-0 (ash_ai evaluate against Ollaya)"

  @moduledoc """
  Runs spike-0 and writes the raw results and a summary.

      mix clinic.spike0                                # replay the committed stub set
      mix clinic.spike0 --transport stub               # stub answers, no fixture needed
      mix clinic.spike0 --transport record --set live-2026-09-29 --cold
      mix clinic.spike0 --transport replay --set live-2026-09-29
      mix clinic.spike0 --transport live --specs laya --repeats 1 --limit 1

  ## Options

    * `--transport` — `replay` (default), `stub`, `record` or `live`.
      `record` and `live` need `OLLAYA_BASE_URL`; source
      `~/.config/system-one/endpoints.env` first (`scripts/spike0-live.sh` does).
    * `--set` — the fixture set to replay or record into
      (`priv/fixtures/system_one/spike0/replay/<set>.jsonl`). Default `stub`.
    * `--record-stub` — with `--transport stub`, also write the stub exchanges
      to `--set`. This is how the committed stub set is produced.
    * `--specs` — comma-separated, from `laya,winnow`. Default both.
    * `--repeats` — per item. Default 3.
    * `--cold` — send one cold request per spec first (runs
      `S1_OLLAYA_UNLOAD_CMD` in `record`/`live`).
    * `--limit` — items per question, for a quick check.
    * `--out` — results directory label. Default: the set name, or the transport.

  Results go to `priv/fixtures/system_one/spike0/results/<out>/`: one
  `<spec>.jsonl` of raw rows per spec, `summary.json` and `summary.md`.
  """

  use Mix.Task

  alias ClinicDemo.SystemOneSpike.Models
  alias ClinicDemo.SystemOneSpike.Report
  alias ClinicDemo.SystemOneSpike.Runner
  alias ClinicDemo.SystemOneSpike.Transport

  @switches [
    transport: :string,
    set: :string,
    record_stub: :boolean,
    specs: :string,
    repeats: :integer,
    cold: :boolean,
    limit: :integer,
    out: :string
  ]

  @results_dir "priv/fixtures/system_one/spike0/results"

  @impl Mix.Task
  def run(argv) do
    {opts, _args, invalid} = OptionParser.parse(argv, strict: @switches)
    if invalid != [], do: Mix.raise("unknown options: #{inspect(invalid)}")

    # Only what the spike needs: no repo, no endpoint, no process engine.
    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:telemetry, :req, :req_llm])

    set = Keyword.get(opts, :set, "stub")
    transport = transport(Keyword.get(opts, :transport, "replay"), set, opts[:record_stub])
    specs = specs(Keyword.get(opts, :specs))

    if match?({:record, _}, transport) or transport == :live do
      unless Models.live_configured?() do
        Mix.raise("OLLAYA_BASE_URL is not set. Source ~/.config/system-one/endpoints.env first.")
      end
    end

    if match?({:record, _}, transport) or match?({:stub_record, _}, transport) do
      reset_set(set)
    end

    %{rows: rows, summary: summary} =
      Runner.run(
        specs: specs,
        transport: transport,
        repeats: Keyword.get(opts, :repeats, 3),
        cold: Keyword.get(opts, :cold, false),
        limit: Keyword.get(opts, :limit)
      )

    out = Keyword.get(opts, :out, default_out(transport))
    dir = Path.join(@results_dir, out)
    write(dir, specs, rows, summary)

    markdown = Report.markdown(summary)
    Mix.shell().info(markdown)
    Mix.shell().info("\nWrote #{length(rows)} rows to #{dir}/")
  end

  defp transport("replay", set, _), do: {:replay, set}
  defp transport("record", set, _), do: {:record, set}
  defp transport("stub", set, true), do: {:stub_record, set}
  defp transport("stub", _set, _), do: :stub
  defp transport("live", _set, _), do: :live
  defp transport(other, _, _), do: Mix.raise("unknown --transport #{inspect(other)}")

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

  defp default_out({_, set}), do: set
  defp default_out(mode), do: Atom.to_string(mode)

  # Recording starts the set afresh, so a set never mixes two runs.
  defp reset_set(set) do
    path = Transport.fixture_path(set)
    if File.exists?(path), do: File.rm!(path)
    Transport.forget(set)
  end

  defp write(dir, specs, rows, summary) do
    File.mkdir_p!(dir)

    for spec <- specs do
      name = Atom.to_string(spec)

      lines =
        rows
        |> Enum.filter(&(&1["spec"] == name))
        |> Enum.map_join("", &(JSON.encode!(&1) <> "\n"))

      File.write!(Path.join(dir, name <> ".jsonl"), lines)
    end

    File.write!(Path.join(dir, "summary.json"), JSON.encode!(summary))
    File.write!(Path.join(dir, "summary.md"), Report.markdown(summary))
  end
end
