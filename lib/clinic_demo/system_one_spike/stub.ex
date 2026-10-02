defmodule ClinicDemo.SystemOneSpike.Stub do
  @moduledoc """
  A deterministic stand-in for Ollaya, used when no model is reachable.

  **It measures nothing about any model.** It exists so that the harness
  (actions, wire encoding, decoding, casting, metrics, band table, report) runs
  end to end without a network, and so the committed stub fixtures exercise the
  replay path. Every result it produces carries provenance `"stub"`.

  It answers in the TypeSafe wire shape documented at docs.typesafe.ai and
  assumed for Ollaya:

      {"model": "...", "answers": {"<id>": {"type": "noul", "noul": 0.8}}, "usage": {...}}

  The heuristics are deliberately naive keyword matches. They get the clear
  cases right and several hard negatives wrong, so the metrics have something
  to show; any resemblance to a real model's accuracy is accidental.

  ## Context limits (assumed)

  A state longer than the model's context gets a `422` with code
  `STATE_TRUNCATED`. Ollaya documents that code for `laya:en`
  (ollaya.dev/docs/typesafe-compatibility); the exact body shape is **assumed**
  here, and the live run records the real one. Token counts are approximated as
  bytes of JSON state / 4.
  """

  @limits %{"laya:typed-decisions" => 1024, "winnow:e4b" => 8192}

  @follow_up ~r/\b(recheck|re-check|revisit|return (in|on)|booked|scheduled|referr|suture removal|course (ends|finishes)|until the course|follow-up (appointment|visit|call) (booked|on|in))/i
  @declined ~r/\b(no (recheck|follow-up|further)|not (required|needed)|declined|cancel+ed|if (it|she|he|signs|symptoms) (worsen|recur|persist)|as needed|\[template\]|unnecessary)/i

  @choice_cues [
    {"emergency",
     ~r/\b(collaps|seizur|not breathing|hit by a car|bleeding heavily|ate (rat|chocolate|lily|lilies)|straining .* no urine|bloat)/i},
    {"urgent",
     ~r/\b(vomit\w* (repeatedly|since)|won't bear weight|not eaten .* (two|2|three|3) days|squinting|swollen)/i},
    {"soon", ~r/\b(itch|scratching|ear|lump|mild|slightly|dandruff)/i},
    {"routine", ~r/\b(vaccin|booster|annual|nail trim|check-up|health check|dental clean)/i}
  ]

  @doc "The wire reply to a decoded request: `{status, body}`."
  def reply(%{"model" => model, "state" => state, "questions" => questions}, tag) do
    tokens = approx_tokens(state)
    limit = Map.get(@limits, model, 8192)

    if tokens > limit do
      {422,
       %{
         "error" => %{
           "code" => "STATE_TRUNCATED",
           "message" =>
             "state is ~#{tokens} tokens; #{model} accepts #{limit} (stub; body shape assumed)"
         }
       }}
    else
      text = text_of(state)

      answers =
        Map.new(questions, fn {id, question} -> {id, answer(question, text, tag <> id)} end)

      {200,
       %{
         "model" => model <> "+stub",
         "answers" => answers,
         "usage" => %{"input_tokens" => tokens, "output_tokens" => 0}
       }}
    end
  end

  def reply(_request, _tag), do: {400, %{"error" => %{"code" => "BAD_REQUEST"}}}

  @doc "Approximate token count of a state, as the stub and the report use it."
  def approx_tokens(state) when is_binary(state), do: div(byte_size(state), 4)
  def approx_tokens(state), do: state |> JSON.encode!() |> approx_tokens()

  defp answer(%{"type" => "noul"}, text, salt) do
    p =
      0.5
      |> Kernel.+(if Regex.match?(@follow_up, text), do: 0.4, else: -0.1)
      |> Kernel.-(if Regex.match?(@declined, text), do: 0.45, else: 0.0)
      |> Kernel.+(jitter(text, salt))
      |> clamp()

    %{"type" => "noul", "noul" => Float.round(p, 4)}
  end

  defp answer(%{"type" => "choice", "criteria" => criteria}, text, salt) do
    options = options(criteria)

    picked =
      Enum.find_value(@choice_cues, fn {option, cue} ->
        if option in options and Regex.match?(cue, text), do: option
      end) || fallback(options)

    rest = options -- [picked]
    top = clamp(0.7 + jitter(text, salt))
    each = if rest == [], do: 0.0, else: (1.0 - top) / length(rest)

    probabilities =
      Map.new(options, fn option ->
        {option, Float.round(if(option == picked, do: top, else: each), 4)}
      end)

    %{
      "type" => "choice",
      "choice" => picked,
      "probabilities" => probabilities,
      "confidence" => Float.round(top, 4)
    }
  end

  defp answer(question, _text, _salt),
    do: %{"type" => "error", "error" => "stub cannot answer #{inspect(question["type"])}"}

  defp options(criteria) when is_map(criteria), do: criteria |> Map.keys() |> Enum.sort()
  defp options(criteria) when is_list(criteria), do: Enum.map(criteria, &to_string/1)

  defp fallback(options) do
    if "insufficient_information" in options, do: "insufficient_information", else: hd(options)
  end

  # Small, deterministic per-repeat variation, so the variance metric has
  # something to measure. Never more than ±0.02.
  defp jitter(text, salt) do
    <<n::16, _::binary>> = :crypto.hash(:sha256, salt <> text)
    (n / 65_535 - 0.5) * 0.04
  end

  defp clamp(p), do: p |> max(0.03) |> min(0.97)

  defp text_of(state) when is_binary(state), do: state

  defp text_of(state) when is_map(state),
    do: state |> Map.values() |> Enum.map_join(" ", &text_of/1)

  defp text_of(state) when is_list(state), do: Enum.map_join(state, " ", &text_of/1)
  defp text_of(nil), do: ""
  defp text_of(other), do: to_string(other)
end
