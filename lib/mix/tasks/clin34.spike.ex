defmodule Mix.Tasks.Clin34.Spike do
  @shortdoc "CLIN-34: run the extract-then-verify spike on synthetic certificates"

  @moduledoc """
  Runs `ClinicDemo.EvidenceSpike.Runner` and writes the summary as JSON.

      mix clin34.spike                                  # replay the committed stub set
      mix clin34.spike --mode stub --record-stub        # regenerate the stub set
      mix clin34.spike --mode record --set recorded-2026-09-29 --n 20   # live, recording
      mix clin34.spike --mode replay --set recorded-2026-09-29          # replay a recorded set

  ## Options

    * `--mode` - `replay` (default), `record`, `live` or `stub`. `record` and
      `live` need `S1_GEN_BASE_URL` and `OLLAYA_BASE_URL` (see
      `ClinicDemo.EvidenceSpike.Models`); `scripts/clin34-live.sh` sets them
      from `~/.config/system-one/endpoints.env`.
    * `--set` - the fixture set name (default `stub`).
    * `--n` - how many certificates (default 20).
    * `--paths` - comma-separated, from `static,enum` (default both).
    * `--verifiers` - comma-separated Ollaya model ids (default
      `laya:typed-decisions,winnow:e4b`).
    * `--out` - where to write the summary JSON (default
      `docs/research/clin-34-results-<set>.json`).
    * `--record-stub` - in `stub` mode, also write the stub exchanges to the set,
      so `replay` can serve them.

  Starts only what it needs: config, telemetry, ReqLLM and Ash. It does not
  start the Repo or the endpoint. The ledger is in ETS.
  """

  use Mix.Task

  alias ClinicDemo.EvidenceSpike.{Models, Runner, Wire}

  @switches [
    mode: :string,
    set: :string,
    n: :integer,
    paths: :string,
    verifiers: :string,
    out: :string,
    record_stub: :boolean
  ]

  @modes %{"replay" => :replay, "record" => :record, "live" => :live, "stub" => :stub}
  @paths %{"static" => :static, "enum" => :enum}

  @impl Mix.Task
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    mode = Map.fetch!(@modes, Keyword.get(opts, :mode, "replay"))
    set = Keyword.get(opts, :set, "stub")

    if mode in [:record, :live] and not Models.live_configured?() do
      Mix.raise("""
      --mode #{mode} needs S1_GEN_BASE_URL and OLLAYA_BASE_URL. Run it through
      scripts/clin34-live.sh, which sources ~/.config/system-one/endpoints.env.
      """)
    end

    Mix.Task.run("app.config")
    # Ash logs every ETS create at :debug; the ledger is summarised instead.
    Logger.configure(level: :info)
    {:ok, _} = Application.ensure_all_started([:telemetry, :req_llm, :ash])

    Application.put_env(:clinic_demo, Wire,
      mode: mode,
      set: set,
      record_stub?: Keyword.get(opts, :record_stub, false)
    )

    if mode == :stub and Keyword.get(opts, :record_stub, false),
      do: File.rm(Wire.fixture_path(set))

    run_opts =
      [
        n: Keyword.get(opts, :n, 20),
        paths:
          opts
          |> Keyword.get(:paths, "static,enum")
          |> split()
          |> Enum.map(&Map.fetch!(@paths, &1)),
        verifiers: opts |> Keyword.get(:verifiers, "laya:typed-decisions,winnow:e4b") |> split()
      ]

    {summary, _certs} = Runner.run(run_opts)

    summary =
      Map.merge(summary, %{
        mode: mode,
        set: set,
        extractor: Wire.model_label(Models.extractor()),
        run_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      })

    out = Keyword.get(opts, :out, "docs/research/clin-34-results-#{set}.json")
    File.mkdir_p!(Path.dirname(out))
    json = JSON.encode!(summary)
    File.write!(out, json <> "\n")
    Mix.shell().info(json)
    Mix.shell().info("\nwrote #{out}")
  end

  defp split(csv), do: csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
