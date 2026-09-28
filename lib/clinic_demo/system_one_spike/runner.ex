defmodule ClinicDemo.SystemOneSpike.Runner do
  @moduledoc """
  Runs spike-0: every labelled item, against every spec, through the three
  actions, and summarises what came back.

  The runner calls the actions exactly as an application would
  (`Ash.run_action/1`). It never talks to a model itself. How the request
  leaves the process is the `transport` (see `ClinicDemo.SystemOneSpike.Models`).

  ## What is run, per spec

  1. With `cold: true`, one cold request first (tag `"cold"`). In `:live` and
     `{:record, _}` it runs `S1_OLLAYA_UNLOAD_CMD` before the request, with
     `{model}` replaced by the model id, e.g. `ssh laptop ollaya stop {model}`.
  2. Every `notes_follow_up` and `presenting_urgency` item, `repeats` times
     (tags `"r1"`, `"r2"`, ...).
  3. `both`, once per pair of a non-probe noul item and a choice item, to
     compare one batched request with two separate ones.

  ## Latency

  In replay, the latency reported is the one recorded from the live model,
  taken from the transport's telemetry. In `:live` it is the wall time of the
  action call. In `:stub` it is zero, and the report says so.
  """

  alias ClinicDemo.SystemOneSpike
  alias ClinicDemo.SystemOneSpike.Band
  alias ClinicDemo.SystemOneSpike.Metrics
  alias ClinicDemo.SystemOneSpike.Models
  alias ClinicDemo.SystemOneSpike.Transport

  @items_path "priv/fixtures/system_one/spike0/items.jsonl"
  @questions [:notes_follow_up, :presenting_urgency]

  @doc "The labelled items."
  def items(path \\ @items_path) do
    path
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&JSON.decode!/1)
  end

  @doc """
  Runs the spike and returns `%{rows: rows, summary: summary}`.

  Options: `:specs` (default all), `:transport` (default `:stub`),
  `:repeats` (default 3), `:cold` (default false), `:limit` (items per
  question, default all), `:items` (override the item list).
  """
  def run(opts \\ []) do
    specs = Keyword.get(opts, :specs, Models.names())
    transport = Keyword.get(opts, :transport, :stub)
    repeats = Keyword.get(opts, :repeats, 3)
    items = Keyword.get_lazy(opts, :items, &items/0) |> limit(Keyword.get(opts, :limit))

    handler = attach_telemetry()

    try do
      rows =
        Enum.flat_map(specs, fn spec ->
          cold_rows(spec, transport, items, Keyword.get(opts, :cold, false)) ++
            question_rows(spec, transport, items, repeats) ++
            both_rows(spec, transport, items)
        end)

      %{rows: rows, summary: summarize(rows, specs, transport, repeats)}
    after
      :telemetry.detach(handler)
    end
  end

  defp limit(items, nil), do: items

  defp limit(items, n) do
    items
    |> Enum.group_by(& &1["question"])
    |> Enum.flat_map(fn {_, list} -> Enum.take(list, n) end)
  end

  # ── what is run ──────────────────────────────────────────────────────────

  defp cold_rows(_spec, _transport, _items, false), do: []

  defp cold_rows(spec, transport, items, true) do
    item =
      Enum.find(items, &(&1["question"] == "notes_follow_up" and &1["stratum"] != "length_probe"))

    unload(spec, transport)
    [call(spec, transport, :notes_follow_up, item, "cold")]
  end

  defp question_rows(spec, transport, items, repeats) do
    for question <- @questions,
        item <- Enum.filter(items, &(&1["question"] == Atom.to_string(question))),
        r <- 1..repeats do
      call(spec, transport, question, item, "r#{r}")
    end
  end

  defp both_rows(spec, transport, items) do
    for {noul, choice} <- pairs(items) do
      pair = %{
        "id" => noul["id"] <> "+" <> choice["id"],
        "question" => "both",
        "state" => Map.merge(noul["state"], choice["state"]),
        "gold" => %{"follow_up" => noul["gold"], "urgency" => choice["gold"]},
        "stratum" => "pair",
        "approx_tokens" => nil,
        "pair" => [noul["id"], choice["id"]]
      }

      call(spec, transport, :both, pair, "r1")
    end
  end

  @doc "The (noul, choice) item pairs `both` is run over."
  def pairs(items) do
    nouls =
      Enum.filter(
        items,
        &(&1["question"] == "notes_follow_up" and &1["stratum"] != "length_probe")
      )

    choices = Enum.filter(items, &(&1["question"] == "presenting_urgency"))
    Enum.zip(nouls, choices)
  end

  defp unload(spec, :live), do: run_unload(spec)
  defp unload(spec, {:record, _set}), do: run_unload(spec)
  defp unload(_spec, _transport), do: :ok

  defp run_unload(spec) do
    case System.get_env("S1_OLLAYA_UNLOAD_CMD") do
      cmd when is_binary(cmd) and cmd != "" ->
        command = String.replace(cmd, "{model}", Models.model_id(spec))
        {_out, status} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)
        if status != 0, do: IO.puts(:stderr, "unload command exited #{status}: #{command}")

      _ ->
        IO.puts(
          :stderr,
          "S1_OLLAYA_UNLOAD_CMD is not set, so the 'cold' request for #{spec} may be warm"
        )
    end
  end

  # ── one call ─────────────────────────────────────────────────────────────

  @doc false
  def call(spec, transport, action, item, tag) do
    flush_exchanges()
    context = %{system_one_spike: %{spec: spec, transport: transport, tag: tag}}
    started = System.monotonic_time(:microsecond)

    outcome =
      try do
        SystemOneSpike
        |> Ash.ActionInput.for_action(action, item["state"], context: context)
        |> Ash.run_action()
      rescue
        e -> {:crash, Exception.format(:error, e, __STACKTRACE__)}
      end

    wall_us = System.monotonic_time(:microsecond) - started
    exchange = last_exchange()

    base = %{
      "spec" => Atom.to_string(spec),
      "model_id" => Models.model_id(spec),
      "action" => Atom.to_string(action),
      "item_id" => item["id"],
      "tag" => tag,
      "gold" => item["gold"],
      "stratum" => item["stratum"],
      "approx_tokens" => item["approx_tokens"],
      "provenance" => provenance(transport, exchange),
      "status" => exchange && exchange.status,
      "latency_us" => latency(transport, exchange, wall_us),
      "wall_us" => wall_us
    }

    Map.merge(base, outcome_fields(action, outcome))
  end

  defp provenance(:live, _), do: "live"
  defp provenance(_, %{provenance: provenance}), do: provenance
  defp provenance(_, nil), do: "none"

  defp latency(:live, _exchange, wall_us), do: wall_us
  defp latency(_, %{latency_us: us}, _wall_us), do: us
  defp latency(_, nil, wall_us), do: wall_us

  defp outcome_fields(action, {:ok, %AshAi.Actions.Result{} = result}) do
    %{
      "ok" => true,
      "result_model" => result.model,
      "input_tokens" => result.usage && (result.usage[:input_tokens] || result.usage[:input]),
      "answer" => answer(action, result.result)
    }
  end

  defp outcome_fields(_action, {:error, error}) do
    %{"ok" => false, "error" => describe_error(error)}
  end

  defp outcome_fields(_action, {:crash, formatted}) do
    %{
      "ok" => false,
      "error" => %{"kind" => "crash", "message" => String.slice(formatted, 0, 2000)}
    }
  end

  defp answer(:notes_follow_up, %AshAi.Evaluate.Noul{probability: p}), do: %{"p" => p}

  defp answer(:presenting_urgency, %AshAi.Evaluate.Choice{} = choice), do: choice_answer(choice)

  defp answer(:both, %{follow_up: noul, urgency: choice}),
    do: %{"follow_up" => %{"p" => noul.probability}, "urgency" => choice_answer(choice)}

  defp choice_answer(%AshAi.Evaluate.Choice{value: value, probabilities: probabilities} = choice) do
    band =
      case Band.decide(value, probabilities) do
        {:ok, output, inputs} -> %{"output" => output, "inputs" => inputs}
        {:error, reason} -> %{"error" => inspect(reason)}
      end

    %{
      "value" => to_string(value),
      "probabilities" => Map.new(probabilities, fn {k, v} -> {to_string(k), v} end),
      "confidence" => choice.confidence,
      "band" => band
    }
  end

  @doc """
  A JSON-safe description of an action error: the error class, and for an
  HTTP error the status and the server's response body. The request body is
  deliberately left out; ReqLLM's error carries the whole request, state
  included.
  """
  def describe_error(error) do
    api = find_api_error(error)

    %{
      "kind" => error |> Map.get(:__struct__) |> inspect(),
      "class" => error |> Map.get(:class) |> to_string(),
      "cause" => api && inspect(api.__struct__),
      "status" => api && Map.get(api, :status),
      "response_body" => api && Map.get(api, :response_body),
      "message" =>
        if(api,
          do: Map.get(api, :reason),
          else: error |> Exception.message() |> String.slice(0, 500)
        )
    }
  end

  defp find_api_error(%{status: status} = e) when is_integer(status), do: e
  defp find_api_error(%{cause: cause}) when is_map(cause), do: find_api_error(cause)
  defp find_api_error(%{error: error}) when is_map(error), do: find_api_error(error)

  defp find_api_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_api_error/1)

  defp find_api_error(_), do: nil

  # ── telemetry ────────────────────────────────────────────────────────────

  # Req runs the transport plug in the calling process, so the handler runs
  # there too and can post to its own mailbox.
  defp attach_telemetry do
    id = "spike0-runner-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      Transport.event(),
      &__MODULE__.handle_exchange/4,
      nil
    )

    id
  end

  @doc false
  def handle_exchange(_event, measurements, metadata, _config) do
    send(self(), {:spike0_exchange, Map.merge(metadata, measurements)})
  end

  defp flush_exchanges do
    receive do
      {:spike0_exchange, _} -> flush_exchanges()
    after
      0 -> :ok
    end
  end

  defp last_exchange(last \\ nil) do
    receive do
      {:spike0_exchange, exchange} -> last_exchange(exchange)
    after
      0 -> last
    end
  end

  # ── summary ──────────────────────────────────────────────────────────────

  @doc "Summarises result rows per spec and question."
  def summarize(rows, specs, transport, repeats) do
    provenances = rows |> Enum.map(& &1["provenance"]) |> Enum.uniq() |> Enum.sort()

    per_spec =
      Map.new(specs, fn spec ->
        spec_rows = Enum.filter(rows, &(&1["spec"] == Atom.to_string(spec)))

        {Atom.to_string(spec),
         %{
           "model_id" => Models.model_id(spec),
           "noul" => noul_summary(spec_rows),
           "choice" => choice_summary(spec_rows),
           "latency" => latency_summary(spec_rows),
           "batching" => batching_summary(spec_rows),
           "context_limit" => context_summary(spec_rows),
           "wire" => wire_summary(spec_rows)
         }}
      end)

    %{
      "transport" => transport_label(transport),
      "provenance" => provenances,
      "repeats" => repeats,
      "specs" => per_spec,
      "verdict" => verdict(per_spec, provenances)
    }
  end

  defp transport_label({mode, set}), do: "#{mode}:#{set}"
  defp transport_label(mode), do: Atom.to_string(mode)

  defp rows_for(rows, action, tag),
    do: Enum.filter(rows, &(&1["action"] == action and &1["tag"] == tag))

  defp noul_summary(rows) do
    primary = rows_for(rows, "notes_follow_up", "r1")
    ok = Enum.filter(primary, & &1["ok"])
    pairs = Enum.map(ok, &{&1["answer"]["p"], &1["gold"]})

    %{
      "n_items" => length(primary),
      "n_answered" => length(ok),
      "n_errors" => length(primary) - length(ok),
      "auroc" => Metrics.auroc(pairs),
      "by_gold" => pairs |> Metrics.by_gold() |> Map.new(fn {k, v} -> {to_string(k), v} end),
      "middle_band_0.2_0.8" => Metrics.middle_band(pairs),
      "ece_10_bins" => Metrics.ece(pairs),
      "brier" => Metrics.brier(pairs),
      "accuracy_at_0.5" => Metrics.accuracy(pairs),
      "selective_0.9" => Metrics.selective(pairs, 0.9),
      "selective_0.8" => Metrics.selective(pairs, 0.8),
      "operating_point_acc95_cov40" => Metrics.operating_point(pairs, 0.95, 0.40),
      "reliability" => pairs |> Metrics.reliability() |> Enum.map(&Tuple.to_list/1),
      "by_stratum" => by_stratum(ok, fn row -> row["answer"]["p"] >= 0.5 == row["gold"] end),
      "repeat_stddev" => repeat_spread(rows, "notes_follow_up", fn row -> row["answer"]["p"] end)
    }
  end

  defp choice_summary(rows) do
    primary = rows_for(rows, "presenting_urgency", "r1")
    ok = Enum.filter(primary, & &1["ok"])
    correct = fn row -> row["answer"]["value"] == row["gold"] end
    pairs = Enum.map(ok, &{&1["answer"]["confidence"] || top_p(&1), correct.(&1)})
    suggested = Enum.filter(ok, &(get_in(&1, ["answer", "band", "output"]) == "suggest"))
    abstain_gold = Enum.filter(ok, &(&1["gold"] == "insufficient_information"))
    abstain_said = Enum.filter(ok, &(&1["answer"]["value"] == "insufficient_information"))

    %{
      "n_items" => length(primary),
      "n_answered" => length(ok),
      "n_errors" => length(primary) - length(ok),
      "accuracy" => ok |> Enum.map(&if(correct.(&1), do: 1.0, else: 0.0)) |> Metrics.mean(),
      "ece_10_bins_top_p" => Metrics.ece(pairs),
      "brier_top_p" => Metrics.brier(pairs),
      "selective_0.9" => Metrics.selective_choice(pairs, 0.9),
      "selective_0.8" => Metrics.selective_choice(pairs, 0.8),
      "operating_point_acc95_cov40" =>
        Metrics.operating_point(pairs, 0.95, 0.40, &Metrics.selective_choice/2),
      "band_suggested" => length(suggested),
      "band_suggested_accuracy" =>
        suggested |> Enum.map(&if(correct.(&1), do: 1.0, else: 0.0)) |> Metrics.mean(),
      "abstention" => %{
        "gold_abstain" => length(abstain_gold),
        "model_abstained" => length(abstain_said),
        "abstained_when_gold_abstain" => Enum.count(abstain_gold, correct)
      },
      "by_stratum" => by_stratum(ok, correct),
      "repeat_stddev_top_p" => repeat_spread(rows, "presenting_urgency", &top_p/1)
    }
  end

  defp top_p(row), do: row["answer"]["probabilities"] |> Map.values() |> Enum.max(fn -> nil end)

  defp by_stratum(rows, correct?) do
    rows
    |> Enum.group_by(& &1["stratum"])
    |> Map.new(fn {stratum, members} ->
      {stratum, %{"n" => length(members), "correct" => Enum.count(members, correct?)}}
    end)
  end

  defp repeat_spread(rows, action, value) do
    spreads =
      rows
      |> Enum.filter(
        &(&1["action"] == action and &1["ok"] and String.starts_with?(&1["tag"], "r"))
      )
      |> Enum.group_by(& &1["item_id"])
      |> Enum.filter(fn {_, members} -> length(members) > 1 end)
      |> Enum.map(fn {_, members} -> members |> Enum.map(value) |> Metrics.stddev() end)

    %{
      "items" => length(spreads),
      "mean" => Metrics.mean(spreads),
      "max" => Enum.max(spreads, fn -> nil end)
    }
  end

  defp latency_summary(rows) do
    warm =
      rows
      |> Enum.filter(
        &(&1["ok"] and &1["action"] != "both" and String.starts_with?(&1["tag"], "r"))
      )
      |> Enum.map(& &1["latency_us"])

    cold = Enum.find(rows, &(&1["tag"] == "cold"))

    %{
      "warm_n" => length(warm),
      "warm_p50_ms" => ms(Metrics.percentile(warm, 50)),
      "warm_p95_ms" => ms(Metrics.percentile(warm, 95)),
      "cold_first_request_ms" => cold && ms(cold["latency_us"]),
      "cold_ok" => cold && cold["ok"]
    }
  end

  defp batching_summary(rows) do
    separate =
      rows
      |> Enum.filter(
        &(&1["tag"] == "r1" and &1["action"] in ["notes_follow_up", "presenting_urgency"])
      )
      |> Map.new(&{&1["item_id"], &1})

    comparisons =
      rows
      |> Enum.filter(&(&1["action"] == "both" and &1["ok"]))
      |> Enum.flat_map(fn both ->
        [noul_id, choice_id] = String.split(both["item_id"], "+")

        case {separate[noul_id], separate[choice_id]} do
          {%{"ok" => true} = n, %{"ok" => true} = c} -> [{both, n, c}]
          _ -> []
        end
      end)

    %{
      "pairs" => length(comparisons),
      "both_mean_ms" =>
        comparisons |> Enum.map(fn {b, _, _} -> b["latency_us"] end) |> Metrics.mean() |> ms(),
      "separate_mean_ms" =>
        comparisons
        |> Enum.map(fn {_, n, c} -> n["latency_us"] + c["latency_us"] end)
        |> Metrics.mean()
        |> ms(),
      "mean_abs_p_delta" =>
        comparisons
        |> Enum.map(fn {b, n, _} -> abs(b["answer"]["follow_up"]["p"] - n["answer"]["p"]) end)
        |> Metrics.mean(),
      "same_choice" =>
        Enum.count(comparisons, fn {b, _, c} ->
          b["answer"]["urgency"]["value"] == c["answer"]["value"]
        end)
    }
  end

  defp context_summary(rows) do
    rows
    |> Enum.filter(&(&1["stratum"] == "length_probe" and &1["tag"] == "r1"))
    |> Enum.sort_by(& &1["approx_tokens"])
    |> Enum.map(fn row ->
      %{
        "item_id" => row["item_id"],
        "approx_tokens" => row["approx_tokens"],
        "gold" => row["gold"],
        "outcome" =>
          if row["ok"] do
            %{"ok" => true, "p" => row["answer"]["p"]}
          else
            error = row["error"]

            %{
              "ok" => false,
              "status" => error["status"],
              "kind" => error["kind"],
              "cause" => error["cause"],
              "response_body" => error["response_body"]
            }
          end
      }
    end)
  end

  defp wire_summary(rows) do
    ok = Enum.filter(rows, & &1["ok"])

    %{
      "result_models" => ok |> Enum.map(& &1["result_model"]) |> Enum.uniq(),
      "usage_present" => Enum.count(ok, &is_integer(&1["input_tokens"])),
      "answered" => length(ok),
      "errors_by_kind" =>
        rows
        |> Enum.reject(& &1["ok"])
        |> Enum.frequencies_by(&"#{&1["error"]["kind"]} #{&1["error"]["status"]}")
    }
  end

  defp ms(nil), do: nil
  defp ms(us), do: Float.round(us / 1000, 1)

  # AC-4: go only if some spec reaches, on the noul, AUROC ≥ 0.85, selective
  # accuracy ≥ 0.95 at ≥ 40% coverage, and warm p95 ≤ 250 ms. Stub and replayed
  # stub results cannot earn a verdict: they measure the harness.
  defp verdict(per_spec, provenances) do
    if Enum.all?(provenances, &(&1 in ["live", "recorded"])) do
      passing =
        for {spec, s} <- per_spec,
            is_number(s["noul"]["auroc"]) and s["noul"]["auroc"] >= 0.85,
            s["noul"]["operating_point_acc95_cov40"] != nil,
            is_number(s["latency"]["warm_p95_ms"]) and s["latency"]["warm_p95_ms"] <= 250,
            do: spec

      %{
        "evaluable" => true,
        "go_specs" => passing,
        "outcome" => if(passing == [], do: "no-go or go-with-conditions (see doc)", else: "go")
      }
    else
      %{
        "evaluable" => false,
        "outcome" =>
          "not evaluable: results are not from a live model (provenance #{Enum.join(provenances, ", ")})"
      }
    end
  end
end
