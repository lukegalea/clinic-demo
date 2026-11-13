defmodule ClinicDemo.Trace do
  @moduledoc """
  An in-process span capture, in the shape `AshAgentTools.Trace.explain/2` reads.

  `AshAgentTools.Trace.explain/2` is a pure reduction over a span list; it
  deliberately has no source of spans of its own. This is the demo's source: a
  `capture/2` window around one request, during which `ClinicDemo.Trace.Tracer`
  (registered as Ash's tracer in `config/config.exs`) records every Ash action,
  change, validation and hook as a span, stamped with one correlation id.

      %{result: result, correlation_id: id, spans: spans} =
        ClinicDemo.Trace.capture("book", fn ->
          ClinicDemo.Scheduling.book_appointment(params, actor: actor)
        end)

      AshAgentTools.explain_trace(spans)

  Outside a `capture/2` window the tracer is a no-op: a pair of process
  dictionary reads per span, no allocation, nothing retained.

  ## Why capture, and why in process

  A failed booking rolls its transaction back, so the database — the schedule,
  the audit trail, the event log — holds nothing about it. The trace is the only
  witness, and it has to be taken while the request runs. That is also why this
  is not a collector service: nothing here needs to survive the request, and
  the spans of an interesting failure are exactly the ones nobody turned a
  collector on for in advance.

  Spans from processes Ash spawns for the request (Ash hands the span context to
  them) are delivered to the capturing process by message, so they join the same
  trace. A span that never finishes (the window closed first) is not reported.

  ## What a span carries

  The keys `AshAgentTools.Trace` documents: `name`, `kind`, `status` (`:ok`,
  `:error`, or a map with a message), `attributes`, `start`/`end` (microseconds,
  monotonic), `trace_id` (the correlation id), `span_id`, `parent_id`. Attributes
  the demo adds: `ash.resource`, `ash.action`, `ash.actor` (the actor's role and
  id, never the whole actor), and on a refused action a sibling span named
  `ash.policy <Resource>.<action>` whose `ash.policy.decision` names the
  policies that refused — the thing the reduction's `policy` section reports.
  """

  @ctx :clinic_trace_ctx
  @message_cap 300

  @type span :: map()
  @type capture :: %{result: term(), correlation_id: String.t(), spans: [span()]}

  @doc """
  Runs `fun` inside a capture window and returns its result with the spans.

  `name` labels the request — it becomes the root span, `request <name>`, which
  every span recorded in the window hangs from, and which is marked failed when
  `fun` returns `{:error, _}` or raises. Spans come back ordered by start time.
  The window is closed whatever `fun` does; an exception is re-raised after the
  window closes, so the caller still sees it.
  """
  @spec capture(String.t(), (-> term())) :: capture()
  def capture(name, fun) when is_binary(name) and is_function(fun, 0) do
    correlation_id = Ash.UUID.generate()
    root_id = Ash.UUID.generate()
    previous = Process.get(@ctx)
    started = System.monotonic_time(:microsecond)

    Process.put(@ctx, %{trace_id: correlation_id, owner: self(), parent_id: root_id})

    try do
      result = fun.()

      root = root_span(name, correlation_id, root_id, started, status(result))
      %{result: result, correlation_id: correlation_id, spans: collect(correlation_id, [root])}
    after
      restore(previous)
    end
  end

  defp root_span(name, correlation_id, root_id, started, status) do
    %{
      name: "request #{name}",
      kind: :server,
      status: status,
      attributes: %{"request" => name},
      start: started,
      end: System.monotonic_time(:microsecond),
      trace_id: correlation_id,
      span_id: root_id,
      parent_id: nil
    }
  end

  defp status({:error, error}),
    do: %{code: :error, message: error_message(error)}

  defp status(_result), do: %{code: :ok, message: nil}

  @doc """
  An error as a span carries it: the innermost error's own message, without the
  bread-crumb header Splode puts in front of it, capped at #{@message_cap} characters.
  """
  @spec error_message(term()) :: String.t()
  def error_message(%{__exception__: true, errors: [first | _]}), do: error_message(first)

  def error_message(%{__exception__: true} = error) do
    error
    |> Exception.message()
    |> String.replace(~r/\A\s*Bread Crumbs:\n(?:\s*> .*\n)+\s*/, "")
    |> String.slice(0, @message_cap)
  end

  def error_message(error), do: error |> inspect() |> String.slice(0, @message_cap)

  defp restore(nil), do: Process.delete(@ctx)
  defp restore(previous), do: Process.put(@ctx, previous)

  defp collect(correlation_id, spans) do
    receive do
      {:clinic_span, ^correlation_id, span} -> collect(correlation_id, [span | spans])
    after
      0 -> Enum.sort_by(spans, &{&1.start, &1.span_id})
    end
  end
end
