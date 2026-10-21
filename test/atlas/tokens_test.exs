defmodule Atlas.TokensTest do
  use ExUnit.Case, async: true

  alias Atlas.Tokens

  describe "flatten/1" do
    test "resolves aliases through to their value" do
      tokens =
        Tokens.flatten(%{
          "a" => %{"$value" => "#000000"},
          "b" => %{"$value" => "{a}"},
          "c" => %{"$value" => "{b}"}
        })

      assert tokens["c"] == "#000000"
    end

    test "an alias to a missing token fails, naming both" do
      assert_raise ArgumentError, ~r/b aliases unknown token \{nope\}/, fn ->
        Tokens.flatten(%{"b" => %{"$value" => "{nope}"}})
      end
    end

    test "ignores $-prefixed metadata keys" do
      assert Tokens.flatten(%{
               "$description" => "x",
               "a" => %{"$type" => "color", "$value" => "#fff"}
             }) == %{"a" => "#fff"}
    end
  end

  describe "css/2" do
    test "a bridge entry naming a missing token fails the build" do
      assert_raise ArgumentError, ~r/--x names unknown Atlas token \{nope\}/, fn ->
        Tokens.css(%{"a" => "#fff"}, %{"g" => %{"--x" => "{nope}"}})
      end
    end

    test "the committed atlas.css matches what the JSON generates" do
      assert File.read!("assets/css/atlas.css") == Tokens.css(),
             "assets/css/atlas.css is stale: run `mix atlas.tokens.build`"
    end
  end

  # WCAG 2.2 1.4.3: 4.5:1 for body text. Each paired fill must carry its
  # partner foreground at AA, computed from resolved token values, as the
  # Atlas Accessibility page does.
  describe "paired contrast" do
    @pairs ~w(brand danger success warning pending info inverse)

    for pair <- @pairs do
      test "bg.#{pair} + text.on-#{pair} meets AA" do
        tokens = Tokens.load()
        ratio = contrast(tokens["bg.#{unquote(pair)}"], tokens["text.on-#{unquote(pair)}"])

        assert ratio >= 4.5,
               "bg.#{unquote(pair)} on text.on-#{unquote(pair)} is #{Float.round(ratio, 2)}:1"
      end
    end

    test "text tokens on bg.surface meet AA (placeholder and disabled excepted, as on the Accessibility page)" do
      tokens = Tokens.load()

      for name <- ~w(primary secondary tertiary brand danger success warning pending) do
        ratio = contrast(tokens["bg.surface"], tokens["text.#{name}"])
        assert ratio >= 4.5, "text.#{name} on bg.surface is #{Float.round(ratio, 2)}:1"
      end
    end
  end

  defp contrast(a, b) do
    [l1, l2] = Enum.sort([luminance(a), luminance(b)], :desc)
    (l1 + 0.05) / (l2 + 0.05)
  end

  defp luminance("#" <> hex) do
    [r, g, b] =
      for <<c::binary-size(2) <- hex>> do
        v = String.to_integer(c, 16) / 255
        if v <= 0.04045, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
      end

    0.2126 * r + 0.7152 * g + 0.0722 * b
  end
end
