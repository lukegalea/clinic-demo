defmodule ClinicDemo.Trace.Tracer do
  @moduledoc """
  The `Ash.Tracer` behind `ClinicDemo.Trace.capture/2`.

  Registered globally (`config :ash, tracer: [...]`) because the spans that
  matter are not the ones of the action the caller named: the booking's failure
  is two actions deeper, in a write the visit-process engine makes as a
  separate Ash call that no `tracer:` option would reach. A global tracer sees
  that call too.

  It records only while a capture window is open in this process (or in a
  process Ash spawned with the window's span context); everywhere else
  `start_span/2` pushes a placeholder and `stop_span/0` pops it.
  """

  @behaviour Ash.Tracer

  alias Ash.Policy.Check

  @ctx :clinic_trace_ctx
  @stack :clinic_trace_stack

  @impl true
  def start_span(type, name) do
    span =
      case Process.get(@ctx) do
        nil ->
          nil

        ctx ->
          %{
            name: to_string(name),
            kind: :internal,
            status: :unset,
            attributes: %{"ash.span_type" => to_string(type)},
            start: System.monotonic_time(:microsecond),
            end: nil,
            trace_id: ctx.trace_id,
            span_id: Ash.UUID.generate(),
            parent_id: parent_id(ctx)
          }
      end

    Process.put(@stack, [span | Process.get(@stack, [])])
    :ok
  end

  @impl true
  def stop_span do
    case Process.get(@stack, []) do
      [] ->
        :ok

      [nil | rest] ->
        Process.put(@stack, rest)
        :ok

      [span | rest] ->
        Process.put(@stack, rest)
        deliver(%{span | end: System.monotonic_time(:microsecond)})
    end
  end

  @impl true
  def get_span_context do
    case Process.get(@ctx) do
      nil -> nil
      ctx -> %{ctx | parent_id: parent_id(ctx)}
    end
  end

  @impl true
  def set_span_context(nil), do: :ok

  def set_span_context(ctx) do
    Process.put(@ctx, ctx)
    :ok
  end

  @impl true
  def trace_type?(_type), do: true

  @impl true
  def set_metadata(_type, metadata) when is_map(metadata) do
    update_top(fn span ->
      %{span | attributes: Map.merge(span.attributes, attributes(metadata))}
    end)
  end

  def set_metadata(_type, _metadata), do: :ok

  @impl true
  def set_error(error), do: set_error(error, [])

  @impl true
  def set_error(error, _opts), do: mark_error(error)

  @impl true
  def set_handled_error(error, _opts), do: mark_error(error)

  # -- spans ----------------------------------------------------------------

  defp parent_id(ctx) do
    case Process.get(@stack, []) do
      [%{span_id: id} | _] -> id
      _ -> ctx.parent_id
    end
  end

  defp update_top(fun) do
    case Process.get(@stack, []) do
      [%{} = span | rest] -> Process.put(@stack, [fun.(span) | rest])
      _ -> :ok
    end

    :ok
  end

  defp deliver(span) do
    case Process.get(@ctx) do
      %{owner: owner, trace_id: trace_id} -> send(owner, {:clinic_span, trace_id, span})
      _ -> :ok
    end

    :ok
  end

  # A returned error and a raised one are both "the span failed". The policy
  # refusal also gets a sibling span of its own, because that is where the
  # reduction looks for it and where the decision's reason is recorded.
  defp mark_error(error) do
    message = ClinicDemo.Trace.error_message(error)

    update_top(fn span ->
      %{span | status: %{code: :error, message: message}}
    end)

    case Process.get(@stack, []) do
      [%{} = span | _] -> policy_spans(error, span)
      _ -> :ok
    end

    :ok
  end

  defp policy_spans(error, parent) do
    for %Ash.Error.Forbidden.Policy{} = policy <- flatten(error) do
      now = System.monotonic_time(:microsecond)

      deliver(%{
        name: "ash.policy #{inspect(policy.resource)}.#{policy.action && policy.action.name}",
        kind: :internal,
        status: %{code: :error, message: "forbidden"},
        attributes: %{
          "ash.resource" => inspect(policy.resource),
          "ash.action" => policy.action && to_string(policy.action.name),
          "ash.actor" => actor_label(policy.actor),
          "ash.policy.decision" => decision(policy)
        },
        start: now,
        end: now,
        trace_id: parent.trace_id,
        span_id: Ash.UUID.generate(),
        parent_id: parent.span_id
      })
    end

    :ok
  end

  defp flatten(%{errors: errors}) when is_list(errors), do: Enum.flat_map(errors, &flatten/1)
  defp flatten(error), do: [error]

  # What refused, in the policy author's own words: the description of every
  # policy that applied to the request and that no `authorize_if` passed, and
  # the conditions under which it applies. Read off the facts the authorizer
  # already computed, so nothing is evaluated twice.
  defp decision(%{policies: policies, facts: facts, actor: actor}) do
    refusals =
      policies
      |> List.wrap()
      |> Enum.filter(&refused?(&1, facts))
      |> Enum.map(&describe_refusal/1)

    case refusals do
      [] -> "forbidden"
      refusals -> "forbidden by: #{Enum.join(refusals, "; ")} [actor #{actor_label(actor)}]"
    end
  end

  defp refused?(policy, facts) do
    applies? = Enum.all?(List.wrap(policy.condition), &(facts[&1] == true))

    authorized? =
      Enum.any?(policy.policies, fn check ->
        check.type == :authorize_if and facts[{check.check_module, check.check_opts}] == true
      end)

    applies? and not authorized?
  end

  defp describe_refusal(policy) do
    conditions =
      policy.condition
      |> List.wrap()
      |> Enum.map_join(" and ", &describe_condition/1)

    "#{policy.description || "an undescribed policy"} (applies when #{conditions})"
  end

  defp describe_condition({module, opts}), do: Check.describe(module, opts)
  defp describe_condition(other), do: inspect(other)

  defp attributes(metadata) do
    %{
      "ash.resource" => metadata[:resource] && inspect(metadata[:resource]),
      "ash.action" => metadata[:action] && to_string(action_name(metadata[:action])),
      "ash.actor" => actor_label(metadata[:actor])
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp action_name(%{name: name}), do: name
  defp action_name(name), do: name

  defp actor_label(nil), do: nil

  # The engine's own writes carry a named system actor, not a person: say so in
  # the stable form ash_bpmn gives it, rather than as a role-less map.
  defp actor_label(%AshBpmn.SystemActor{} = actor), do: AshBpmn.SystemActor.to_string(actor)

  defp actor_label(actor) when is_map(actor) do
    "role=#{inspect(Map.get(actor, :role))} id=#{inspect(Map.get(actor, :id))}"
  end

  defp actor_label(actor), do: inspect(actor)
end
