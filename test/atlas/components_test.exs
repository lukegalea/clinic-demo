defmodule Atlas.ComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.Component
  import Phoenix.LiveViewTest

  test "the Tag twin renders the recipe's classes for the chosen variants" do
    assigns = %{}

    html =
      rendered_to_string(
        ~H|<Atlas.Components.tag color="gold" size="sm">Pending</Atlas.Components.tag>|
      )

    recipe = Atlas.Components.recipes()["Tag"]

    for class <-
          String.split(
            recipe["base"] <>
              " " <>
              recipe["variants"]["color"]["gold"] <> " " <> recipe["variants"]["size"]["sm"]
          ) do
      assert html =~ class
    end

    assert html =~ ~s(data-atlas="Tag/gold/sm")
    assert html =~ ">Pending</span>"
  end

  test "omitted axes fall back to the recipe's defaults" do
    assigns = %{}
    html = rendered_to_string(~H|<Atlas.Components.tag>Draft</Atlas.Components.tag>|)
    assert html =~ ~s(data-atlas="Tag/neutral/md")
  end

  test "an unknown value falls back to the default rather than emitting no styles" do
    {_classes, tag} =
      Atlas.Components.resolve(Atlas.Components.recipes()["Tag"], %{
        color: "chartreuse",
        size: "sm"
      })

    assert tag == "Tag/neutral/sm"
  end

  test "only static recipes get a twin" do
    for {name, recipe} <- Atlas.Components.recipes() do
      fun = Atlas.Components.function_name(name)

      assert (fun != nil and function_exported?(Atlas.Components, fun, 1)) ==
               (recipe["kind"] == "static"),
             name
    end
  end
end
