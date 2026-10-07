defmodule ClinicDemoWeb.GateHTML do
  @moduledoc """
  The gate page's one template: a standalone, self-contained document —
  no root layout, one inline style block (the app CSP allows inline
  styles), no app JS. A locked door should not need the house.
  """

  use ClinicDemoWeb, :html

  embed_templates "gate_html/*"
end
