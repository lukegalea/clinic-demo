defmodule ClinicDemo.Spikes do
  @moduledoc """
  Throwaway experiments. Nothing in this domain is part of the clinic.

  `ClinicDemo.SystemOneSpike` is spike-0 of the System One programme: it asks
  local decision models, served by Ollaya, typed questions about synthetic
  clinical text, and measures the answers. See `docs/spikes/system-one-spike-0.md`.
  It has no data layer, writes nothing, and is not called by the application.
  """

  use Ash.Domain

  resources do
    resource ClinicDemo.SystemOneSpike
  end
end
