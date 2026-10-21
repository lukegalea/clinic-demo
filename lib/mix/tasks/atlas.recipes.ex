defmodule Mix.Tasks.Atlas.Recipes do
  @shortdoc "Exports the Atlas Lit recipes to priv/atlas/recipes.json"
  @moduledoc """
  Runs `assets/js/atlas/export-recipes.mjs`, which writes every Atlas recipe to
  `priv/atlas/recipes.json`. `Atlas.Components` generates the HEEx twins of
  static components from that file at compile time.

      mix atlas.recipes
      mix atlas.recipes --check   # exit 1 if recipes.json is stale (CI)
  """

  use Mix.Task

  @impl true
  def run(args) do
    script = Path.join(["assets", "js", "atlas", "export-recipes.mjs"])
    {output, status} = System.cmd("node", [script | args], stderr_to_stdout: true)
    Mix.shell().info(String.trim(output))
    if status != 0, do: Mix.raise("mix atlas.recipes failed")
  end
end
