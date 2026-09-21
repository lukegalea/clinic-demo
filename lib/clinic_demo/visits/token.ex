defmodule ClinicDemo.Visits.Token do
  @moduledoc """
  Where an instance currently stands. A token holds node ids and status and
  nothing about the visit — that is read off the appointment, live, every time.
  """

  use AshBpmn.Resources.Token,
    domain: ClinicDemo.Visits,
    repo: ClinicDemo.Repo,
    instance: ClinicDemo.Visits.Instance,
    table: "bpmn_tokens"

  policies do
    policy action_type(:read) do
      authorize_if always()
    end
  end
end
