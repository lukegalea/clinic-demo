defmodule ClinicDemo.EvidenceSpike.Stub do
  @moduledoc """
  A deterministic stand-in for the two models, for exercising the harness.

  **Numbers produced with the stub measure the harness, not a model.** The stub
  exists so that every path the runner takes can run without an endpoint: the
  cast, the checks, the citations, the verifier and the ledger. Stub replies
  are labelled `"stub"` wherever they are recorded.

  It plants known faults at fixed positions, so the metrics have something to
  find:

    * every 7th certificate: the policy number is read from the broker-licence
      distractor, so the value is wrong but still well-formed;
    * every 9th: the policy number is malformed and breaks the regex, so Ash
      must reject the cast;
    * every 6th: the insurer cites atom `a99`, which no packet has. It does this
      only when the schema it was sent leaves `source_ids` open. A schema that
      enumerates the packet's ids leaves the stub, like a grammar-constrained
      decoder, no way to say `a99`.

  The verifier stub answers from the cited atoms' text: high if they carry
  both the field's label and the value, low otherwise. Each verifier model
  gets slightly different numbers.
  """

  alias ClinicDemo.EvidenceSpike.Certificates

  # The stub verifier says yes only when the cited text carries both the
  # field's label and the value. Question phrase => the label it looks for.
  @labels [
    {"the named insured", "named insured"},
    {"the policy number", "policy number"},
    {"the insurer", "insurer:"},
    {"the coverage type", "coverage:"},
    {"the first day", "policy period"},
    {"the last day", "policy period"},
    {"the each-claim limit", "each claim"},
    {"the aggregate limit", "aggregate"}
  ]

  @doc "The reply object for one request payload."
  def answer(model_label, %{op: "generate_object", messages: messages, schema: schema}) do
    text = Enum.map_join(messages, "\n", & &1.text)
    [_, n] = Regex.run(~r/SYNTHETIC SPECIMEN (\d+)/, text)
    n = String.to_integer(n)
    cert = n |> Certificates.generate() |> List.last()
    enum = source_id_enum(schema)

    result =
      Map.new(cert.gold, fn {field, gold} ->
        {to_string(field), fault(field, gold, cert, n, enum)}
      end)

    _ = model_label
    %{"result" => result}
  end

  def answer(model_label, %{op: "evaluate", state: state, questions: questions}) do
    atoms = Map.get(state, "atoms") || Map.get(state, :atoms) || %{}
    cited = atoms |> Map.values() |> Enum.join(" ") |> String.downcase()
    {hi, lo} = if String.contains?(model_label, "winnow"), do: {0.88, 0.14}, else: {0.93, 0.07}

    Map.new(questions, fn {id, question} ->
      instructions = Map.get(question, :instructions) || Map.get(question, "instructions")
      [_, value] = Regex.run(~r/is `([^`]*)`/, instructions)

      label =
        Enum.find_value(@labels, "", fn {phrase, label} ->
          String.contains?(instructions, phrase) && label
        end)

      yes? = String.contains?(cited, label) and String.contains?(cited, String.downcase(value))
      {id, %{"probability" => if(yes?, do: hi, else: lo)}}
    end)
  end

  defp fault(:policy_number, _gold, cert, n, _enum) when rem(n, 9) == 0 do
    %{
      "value" => "CLV-12AB",
      "status" => "found",
      "source_ids" => [atom_with(cert, "Policy number")]
    }
  end

  defp fault(:policy_number, _gold, cert, n, _enum) when rem(n, 7) == 0 do
    id = atom_with(cert, "Broker licence")
    text = Enum.find(cert.atoms, &(&1.id == id)).text
    [_, value] = Regex.run(~r/(BRK-\d{7})/, text)
    %{"value" => value, "status" => "found", "source_ids" => [id]}
  end

  defp fault(:insurer, gold, _cert, n, nil) when rem(n, 6) == 0 do
    gold |> wire() |> Map.put("source_ids", ["a99"])
  end

  defp fault(_field, gold, _cert, _n, _enum), do: wire(gold)

  defp wire(%{value: value, status: status, source_ids: ids}) do
    %{"value" => wire_value(value), "status" => to_string(status), "source_ids" => ids}
  end

  defp wire_value(%Date{} = d), do: Date.to_iso8601(d)
  defp wire_value(v) when is_atom(v) and v not in [nil, true, false], do: to_string(v)
  defp wire_value(v), do: v

  defp atom_with(cert, prefix),
    do: Enum.find(cert.atoms, &String.starts_with?(&1.text, prefix)).id

  defp source_id_enum(schema) do
    get_in(schema, [
      "properties",
      "result",
      "properties",
      "insurer",
      "properties",
      "source_ids",
      "items",
      "enum"
    ])
  end
end
