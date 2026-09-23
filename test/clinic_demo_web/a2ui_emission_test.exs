defmodule ClinicDemoWeb.A2uiEmissionTest do
  @moduledoc """
  The renderer contract, enforced where it is cheapest to enforce.

  The compile-time Spark verifiers prove surface *declarations* against the
  domain; this test proves the *emitted messages* against what the shipped
  renderer stack can actually render. It exists because of a real escape:
  with `experience_version: 2` + `catalog: :admin_v1` the wire stays
  schema-valid (ash_a2ui's conformance suite passes) while the client never
  hydrates the reserved-path bindings — every bound label renders as
  `[object Object]` and the grid stays empty. Schema-valid is not
  renderable.

  The supported cell today is the default experience (basic emission + the
  merged catalog), which config/config.exs pins with the evidence trail.
  This test fails if any text position of any surface's bootstrap carries an
  object — the wire signature of that breakage.
  """

  use ClinicDemo.DataCase, async: false

  alias AshA2ui.Info

  surfaces = [
    ClinicDemoWeb.A2ui.AppointmentUI,
    ClinicDemoWeb.A2ui.IntakeUI,
    ClinicDemoWeb.A2ui.BoardUI,
    ClinicDemoWeb.A2ui.WorklistUI,
    ClinicDemoWeb.A2ui.VisitInstanceUI,
    ClinicDemoWeb.A2ui.PatientUI,
    ClinicDemoWeb.A2ui.ClinicianUI,
    ClinicDemoWeb.A2ui.ProcessDefinitionUI,
    ClinicDemoWeb.A2ui.DecisionDefinitionUI,
    ClinicDemoWeb.A2ui.EvaluationUI,
    ClinicDemoWeb.A2ui.EmergencyBoardUI
  ]

  # Positions a renderer interpolates as text. `value` is excluded here: it
  # may legitimately be a %{"path" => path} state binding, which the healthy
  # default-emission path resolves through the data model.
  @text_positions ~w(text label title buttonText description placeholder emptyText)

  for surface <- surfaces do
    test "emitted messages keep every text position of #{inspect(surface)} renderable" do
      messages = Info.build_surface(unquote(surface), actor: nil)

      assert [] = object_text_positions(messages)
    end
  end

  defp object_text_positions(messages) do
    messages
    |> walk([], [])
    |> Enum.reverse()
  end

  defp walk(term, _path, acc) when is_binary(term), do: acc
  defp walk(term, _path, acc) when is_number(term), do: acc
  defp walk(term, _path, acc) when is_boolean(term), do: acc
  defp walk(nil, _path, acc), do: acc

  defp walk(%{} = map, path, acc) do
    Enum.reduce(map, acc, fn {key, value}, acc ->
      child_path = path ++ [key]

      case value do
        %{} = value when key in @text_positions ->
          [{child_path, value} | acc]

        _ ->
          walk(value, child_path, acc)
      end
    end)
  end

  defp walk(list, path, acc) when is_list(list) do
    Enum.with_index(list, fn item, index -> walk(item, path ++ [index], acc) end)
    |> List.last(acc)
  end
end
