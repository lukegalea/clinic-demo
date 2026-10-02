defmodule ClinicDemo.SystemOneSpike.Report do
  @moduledoc """
  Renders a spike-0 summary as Markdown, for `summary.md` beside the raw
  results and for pasting into `docs/spikes/system-one-spike-0.md`.

  The first line always states the provenance, so a table produced from the
  stub can never be mistaken for a model's numbers.
  """

  @doc "The summary as Markdown."
  def markdown(summary) do
    specs = summary["specs"] |> Enum.sort_by(&elem(&1, 0))

    [
      provenance_line(summary),
      "",
      "Transport `#{summary["transport"]}`, #{summary["repeats"]} repeats. " <>
        "Metrics use the first repeat (`r1`); variance uses all repeats.",
      "",
      "### Noul: `notes_follow_up`",
      "",
      table(
        [
          "spec",
          "N (answered/errors)",
          "AUROC",
          "mean p gold+ / gold−",
          "median p gold+ / gold−",
          "in 0.2–0.8",
          "ECE (10 bins)",
          "Brier",
          "acc @0.5",
          "sel @0.9 (cov / acc)",
          "sel @0.8 (cov / acc)",
          "lowest t with acc≥0.95, cov≥0.4"
        ],
        Enum.map(specs, fn {spec, s} -> noul_row(spec, s["noul"]) end)
      ),
      "",
      "### Choice: `presenting_urgency`",
      "",
      table(
        [
          "spec",
          "N (answered/errors)",
          "accuracy",
          "ECE top-p",
          "Brier top-p",
          "sel @0.9 (cov / acc)",
          "sel @0.8 (cov / acc)",
          "band: suggested (acc)",
          "abstained / gold abstain"
        ],
        Enum.map(specs, fn {spec, s} -> choice_row(spec, s["choice"]) end)
      ),
      "",
      "### Latency, batching and variance",
      "",
      table(
        [
          "spec",
          "warm p50 / p95 ms (n)",
          "cold first request ms",
          "both vs separate ms (pairs)",
          "both: mean |Δp|, same choice",
          "repeat stddev p (mean / max)"
        ],
        Enum.map(specs, fn {spec, s} -> latency_row(spec, s) end)
      ),
      "",
      "### Context limit (length probes, `r1`)",
      "",
      table(
        ["item", "≈tokens", "gold" | Enum.map(specs, &elem(&1, 0))],
        context_rows(specs)
      ),
      "",
      "### Wire",
      "",
      table(
        ["spec", "Result.model values", "usage present", "errors by kind"],
        Enum.map(specs, fn {spec, s} ->
          w = s["wire"]

          [
            spec,
            w["result_models"] |> Enum.map_join(", ", &"`#{&1}`"),
            "#{w["usage_present"]}/#{w["answered"]}",
            w["errors_by_kind"] |> Enum.map_join("; ", fn {k, n} -> "#{k}: #{n}" end)
          ]
        end)
      ),
      "",
      "**Verdict (AC-4):** #{summary["verdict"]["outcome"]}",
      ""
    ]
    |> Enum.join("\n")
  end

  defp provenance_line(%{"provenance" => provenance}) do
    if Enum.all?(provenance, &(&1 in ["live", "recorded"])) do
      "> Provenance: **#{Enum.join(provenance, ", ")}**: answers came from the HTTP endpoint " <>
        "named in `environment.txt` beside this file. Check it is the pinned Ollaya before quoting."
    else
      "> Provenance: **#{Enum.join(provenance, ", ")}**. These numbers measure the harness, " <>
        "not a model. Do not quote them as model results."
    end
  end

  defp noul_row(spec, n) do
    gold_pos = n["by_gold"]["true"]
    gold_neg = n["by_gold"]["false"]

    [
      spec,
      "#{n["n_items"]} (#{n["n_answered"]}/#{n["n_errors"]})",
      f(n["auroc"]),
      "#{f(gold_pos[:mean])} / #{f(gold_neg[:mean])}",
      "#{f(gold_pos[:median])} / #{f(gold_neg[:median])}",
      "#{n["middle_band_0.2_0.8"]}",
      f(n["ece_10_bins"]),
      f(n["brier"]),
      f(n["accuracy_at_0.5"]),
      sel(n["selective_0.9"]),
      sel(n["selective_0.8"]),
      op(n["operating_point_acc95_cov40"])
    ]
  end

  defp choice_row(spec, c) do
    [
      spec,
      "#{c["n_items"]} (#{c["n_answered"]}/#{c["n_errors"]})",
      f(c["accuracy"]),
      f(c["ece_10_bins_top_p"]),
      f(c["brier_top_p"]),
      sel(c["selective_0.9"]),
      sel(c["selective_0.8"]),
      "#{c["band_suggested"]} (#{f(c["band_suggested_accuracy"])})",
      "#{c["abstention"]["abstained_when_gold_abstain"]} of #{c["abstention"]["gold_abstain"]} " <>
        "(#{c["abstention"]["model_abstained"]} abstentions in all)"
    ]
  end

  defp latency_row(spec, s) do
    l = s["latency"]
    b = s["batching"]
    v = s["noul"]["repeat_stddev"]

    [
      spec,
      "#{f(l["warm_p50_ms"])} / #{f(l["warm_p95_ms"])} (#{l["warm_n"]})",
      f(l["cold_first_request_ms"]),
      "#{f(b["both_mean_ms"])} vs #{f(b["separate_mean_ms"])} (#{b["pairs"]})",
      "#{f(b["mean_abs_p_delta"])}, #{b["same_choice"]}/#{b["pairs"]}",
      "#{f(v["mean"])} / #{f(v["max"])}"
    ]
  end

  defp context_rows([]), do: []

  defp context_rows([{_, first} | _] = specs) do
    for probe <- first["context_limit"] do
      outcomes =
        for {_spec, s} <- specs do
          s["context_limit"]
          |> Enum.find(&(&1["item_id"] == probe["item_id"]))
          |> probe_outcome()
        end

      [probe["item_id"], "#{probe["approx_tokens"]}", "#{probe["gold"]}" | outcomes]
    end
  end

  defp probe_outcome(%{"outcome" => %{"ok" => true, "p" => p}}), do: "p=#{f(p)}"

  defp probe_outcome(%{"outcome" => o}) do
    # Ollaya errors arrive in more than one shape: the body can be a plain
    # string ("winnow:e4b failed to load: ..."), or a map whose "error" is a
    # string, or a map with an error map carrying "code". Render them all.
    code = error_code(o["response_body"])
    "error #{o["status"]}#{if code, do: " #{code}"} (#{o["kind"]})"
  end

  defp probe_outcome(nil), do: "–"

  defp error_code(%{"error" => %{"code" => code}}), do: "#{code}"
  defp error_code(_), do: nil

  defp sel(nil), do: "–"
  defp sel(%{coverage: c, accuracy: a}), do: "#{f(c)} / #{f(a)}"

  defp op(nil), do: "none"
  defp op(%{threshold: t, coverage: c}), do: "#{f(t)} (cov #{f(c)})"

  defp f(nil), do: "–"
  defp f(x) when is_float(x), do: :erlang.float_to_binary(x, decimals: 3)
  defp f(x), do: to_string(x)

  defp table(header, rows) do
    [
      "| " <> Enum.join(header, " | ") <> " |",
      "|" <> String.duplicate("---|", length(header))
      | Enum.map(rows, &("| " <> Enum.join(&1, " | ") <> " |"))
    ]
    |> Enum.join("\n")
  end
end
