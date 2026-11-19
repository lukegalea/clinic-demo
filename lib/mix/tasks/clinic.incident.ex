defmodule Mix.Tasks.Clinic.Incident do
  @shortdoc "CLIN-33: send the planted incident's documented request, with its trace"

  @moduledoc """
  Sends the documented request of the planted incident (`ClinicDemo.Incident`)
  and prints what happened as one JSON document.

      mix clinic.incident book                                   # healthy: the booking succeeds
      mix clinic.incident book --incident triage_vet_only        # the incident: it fails
      CLINIC_INCIDENT=triage_vet_only mix clinic.incident book   # the same, from the environment

  The request is a nurse at the front desk booking a visit (who books turns out not to matter)
  (`ClinicDemo.Incident.Fixture`). The JSON carries:

    * `incident` — the switch's state;
    * `outcome` — `"ok"` or `"error"`, with `error` the message the caller saw;
    * `correlation_id` and `spans` — the request's trace, ready for
      `bin/ash-agent trace` (`AshAgentTools.Trace.explain/2`);
    * `event_log` — the rows the request committed to the `ash_events` log. A
      failed booking rolls back, so under the incident this is `[]`: the
      database holds no trace of the failure and the spans are the only record.

  It writes to the database it points at (the fixture's veterinarian and
  patient, and the appointment when the booking succeeds), so point it at a
  scratch database: `MIX_ENV=test MIX_TEST_PARTITION=incident` after
  `mix ash.setup`, or a fresh dev database. The rule documents are published if
  they are not already.

  Stdout is the JSON and nothing else *once the project is compiled* (Mix's own
  compile notice would precede it, so run `mix compile` first); logging is sent
  to stderr.
  """

  use Mix.Task

  alias ClinicDemo.Events.Event
  alias ClinicDemo.Incident
  alias ClinicDemo.Incident.Fixture

  require Ash.Query

  @switches [incident: :string]

  @impl Mix.Task
  def run(argv) do
    {opts, args} = OptionParser.parse!(argv, strict: @switches)

    case args do
      ["book"] ->
        book(opts)

      _ ->
        Mix.raise(
          "usage: mix clinic.incident book [--incident #{Enum.join(Incident.known(), "|")}]"
        )
    end
  end

  defp book(opts) do
    Mix.Task.run("app.config")
    log_to_stderr()
    {:ok, _} = Application.ensure_all_started(:clinic_demo)
    Logger.configure(level: :warning)

    if name = opts[:incident], do: Incident.enable!(incident!(name))

    ClinicDemo.Rules.install!()
    fixture = Fixture.prepare!()
    last_event = last_event_id()

    %{result: result, correlation_id: correlation_id, spans: spans} =
      ClinicDemo.Trace.capture("book_appointment", fn -> Fixture.book(fixture) end)

    %{
      incident: Incident.active(),
      request: %{
        call: "ClinicDemo.Scheduling.book_appointment/2",
        actor: fixture.actor,
        params: Map.take(fixture.params, [:reason, :severity])
      },
      outcome: if(match?({:ok, _}, result), do: "ok", else: "error"),
      error: error_message(result),
      correlation_id: correlation_id,
      event_log: events_since(last_event),
      spans: spans
    }
    |> Jason.encode!()
    |> IO.puts()
  end

  # A running handler cannot change its device, so swap it for one on stderr.
  defp log_to_stderr do
    :ok = :logger.remove_handler(:default)

    :ok =
      :logger.add_handler(:default, :logger_std_h, %{
        config: %{type: :standard_error},
        formatter: Logger.Formatter.new()
      })
  end

  defp incident!(name) do
    Enum.find(Incident.known(), &(Atom.to_string(&1) == name)) ||
      Mix.raise("unknown incident #{inspect(name)}; known: #{inspect(Incident.known())}")
  end

  defp error_message({:error, error}), do: ClinicDemo.Trace.error_message(error)
  defp error_message(_ok), do: nil

  defp last_event_id do
    Event
    |> Ash.Query.sort(id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
    |> then(&(&1 && &1.id)) || 0
  end

  defp events_since(last_id) do
    Event
    |> Ash.Query.filter(id > ^last_id)
    |> Ash.Query.sort(:id)
    |> Ash.Query.load(:what)
    |> Ash.read!(authorize?: false)
    |> Enum.map(&String.replace(&1.what, "Elixir.", ""))
  end
end
