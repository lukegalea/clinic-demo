# Smoke: build every a2ui surface's bootstrap messages and fail loudly on
# any that cannot build. The compile-time verifiers prove the declarations;
# this proves the full ResolvedView -> encoder pipeline per surface.
#
#     mix run scripts/a2ui_smoke.exs

surfaces = [
  ClinicDemoWeb.A2ui.AppointmentUI,
  ClinicDemoWeb.A2ui.WorklistUI,
  ClinicDemoWeb.A2ui.VisitInstanceUI,
  ClinicDemoWeb.A2ui.PatientUI,
  ClinicDemoWeb.A2ui.ClinicianUI,
  ClinicDemoWeb.A2ui.ProcessDefinitionUI,
  ClinicDemoWeb.A2ui.DecisionDefinitionUI,
  ClinicDemoWeb.A2ui.EvaluationUI,
  ClinicDemoWeb.A2ui.EmergencyBoardUI
]

failures =
  for module <- surfaces, reduce: [] do
    acc ->
      # build_surface returns the bootstrap message list itself (untagged);
      # anything else is a failure.
      case AshA2ui.Info.build_surface(module, actor: nil) do
        messages when is_list(messages) ->
          IO.puts("OK    #{inspect(module)} (#{length(messages)} bootstrap messages)")
          acc

        other ->
          IO.puts("FAIL  #{inspect(module)}: #{inspect(other, pretty: true, limit: 20)}")
          [module | acc]
      end
  end

case failures do
  [] ->
    IO.puts("all #{length(surfaces)} surfaces build")

  failed ->
    IO.puts("#{length(failed)} surface(s) failed: #{inspect(failed)}")
    System.halt(1)
end
