defmodule ClinicDemoWeb.Storybook do
  @moduledoc """
  Backend module for the dev-only component storybook, mounted at
  `/storybook` (see `ClinicDemoWeb.Router`).

  Why a storybook here: the neobrutalist recipes in
  `assets/css/neobrutalism.css` only hold together when every component
  uses the same border/shadow/press idiom. The storybook is where those
  recipes can be eyeballed in isolation — without spinning up the clinic's
  data — before they drift.

  This module compiles in dev only: `mix.exs` keeps it out of the
  `elixirc_paths` for test/prod because the `phoenix_storybook` dep is
  `only: :dev`.

  The `css_path`/`js_path` entries point at the storybook asset profiles
  (see `config/config.exs`); `storybook.css` mirrors `app.css`'s source
  scanning so stories render with exactly the classes the app build would
  emit.
  """

  use PhoenixStorybook,
    otp_app: :clinic_demo,
    content_path: Path.expand("../../storybook", __DIR__),
    css_path: "/assets/css/storybook.css",
    js_path: "/assets/js/storybook.js",
    title: "ClinicDemo Storybook"
end
