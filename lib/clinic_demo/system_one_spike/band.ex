defmodule ClinicDemo.SystemOneSpike.Band do
  @moduledoc """
  The spike-only urgency suggestion band,
  `priv/decisions/spike/urgency_suggestion_band.dmn`.

  It turns a presenting-urgency choice into `"suggest"` or `"ask_human"`, from
  the top option, its probability and its margin over the runner-up. The
  probability is an input to a crisp rule; it is never passed on.

  The document is compiled and verified here rather than published through
  `ClinicDemo.Decisions`, because it is not a clinic rule and must not appear
  among the clinic's published decisions. `verify/0` runs the same
  `AshDecisions.Compiler` and `AshDecisions.Verifier` pass that the publish
  path runs.
  """

  alias AshDecisions.Compiler
  alias AshDecisions.Evaluator
  alias AshDecisions.Verifier

  @path "priv/decisions/spike/urgency_suggestion_band.dmn"
  @external_resource @path
  @xml File.read!(@path)

  @doc "The DMN source."
  def xml, do: @xml

  @doc "Compiles and verifies the document: `{:ok, verification}` or the compile errors."
  def verify(xml \\ @xml) do
    with {:ok, graph} <- Compiler.compile(xml) do
      {:ok, Verifier.verify(graph)}
    end
  end

  @doc """
  The band's answer for one choice. Takes the choice's `value` and
  `probabilities` and returns `{:ok, "suggest" | "ask_human", inputs}`.
  """
  def decide(value, probabilities) do
    [top, second | _] =
      probabilities |> Map.values() |> Enum.sort(:desc) |> Kernel.++([0.0, 0.0])

    inputs = %{
      "topOption" => to_string(value),
      "topProbability" => top,
      "margin" => top - second
    }

    case Evaluator.evaluate(definition(), inputs, record: false) do
      {:ok, %{outputs: output}} -> {:ok, output, inputs}
      {:error, reason} -> {:error, reason}
    end
  end

  defp definition do
    case :persistent_term.get({__MODULE__, :definition}, nil) do
      nil ->
        {:ok, graph} = Compiler.compile(@xml)

        definition = %{
          xml: @xml,
          graph: graph,
          key: "spike.urgency_suggestion_band",
          version: 0,
          content_hash: :crypto.hash(:sha256, @xml) |> Base.encode16(case: :lower)
        }

        :persistent_term.put({__MODULE__, :definition}, definition)
        definition

      definition ->
        definition
    end
  end
end
