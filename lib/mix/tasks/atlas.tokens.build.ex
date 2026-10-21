defmodule Mix.Tasks.Atlas.Tokens.Build do
  @shortdoc "Generates assets/css/atlas.css from the Atlas token and bridge files"
  @moduledoc """
  Writes `assets/css/atlas.css` from `priv/atlas/tokens.json` and
  `priv/atlas/bridge.json` (see `Atlas.Tokens`).

      mix atlas.tokens.build
      mix atlas.tokens.build --check   # exit 1 if the committed file is stale

  ## Options

    * `--check` — compare instead of write; fails when `atlas.css` does not
      match what the JSON would generate. For CI.
  """

  use Mix.Task

  @out "assets/css/atlas.css"

  @impl true
  def run(args) do
    {opts, _, _} = OptionParser.parse(args, strict: [check: :boolean])
    css = Atlas.Tokens.css()

    if opts[:check] do
      if File.read(@out) == {:ok, css},
        do: Mix.shell().info("#{@out} is up to date"),
        else: Mix.raise("#{@out} is stale: run `mix atlas.tokens.build`")
    else
      File.write!(@out, css)
      Mix.shell().info("wrote #{@out}")
    end
  end
end
