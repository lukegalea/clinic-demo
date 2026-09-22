/*
 * Storybook JS entry point (dev-only).
 *
 * phoenix_storybook ships and mounts its own LiveView runtime; this bundle
 * exists for the opposite direction — handing the *app's* pieces to the
 * storybook. Anything registered on `window.storybook` below is available
 * to every rendered story:
 *
 *   - Hooks:    LiveView client hooks a story's LiveView should run with
 *   - Params:   extra `connectParams` merged into the story socket
 *   - Uploaders: LiveView upload handlers
 *
 * They are intentionally empty today: no current story needs them. Add
 * entries here (e.g. the app's canvas hook) rather than letting stories
 * reach into app.js.
 */
window.storybook = {
  Hooks: [],
  Params: [],
  Uploaders: []
};
