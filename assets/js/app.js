// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/clinic_demo"
import topbar from "../vendor/topbar"

// A2UI rendering: @a2ui/lit web components driven by the @a2ui/web_core
// message processor. ash_a2ui ships the LiveView hook plus two catalogs: the
// merged catalog (native <select> choice pickers, typeahead comboboxes for
// searchable selects) and the semantic admin_v1 catalog (entityPage /
// dataGrid / recordPanel) that experience v2 selects server-side.
import "@a2ui/lit/v0_9"
import {basicCatalog, A2uiLitElement, A2uiController} from "@a2ui/lit/v0_9"
import {MessageProcessor, Catalog} from "@a2ui/web_core/v0_9"
import {ChoicePickerApi, ColumnApi} from "@a2ui/web_core/v0_9/basic_catalog"
import {html, css, nothing} from "lit"
import {z} from "zod"
import {createAshA2uiCatalog} from "../../deps/ash_a2ui/priv/js/ash_a2ui_catalog.js"
import {createAshAdminCatalog} from "../../deps/ash_a2ui/priv/js/ash_admin_catalog.js"
import {AshA2ui, configureAshA2ui} from "../../deps/ash_a2ui/priv/js/ash_a2ui_hook.js"
import "../../deps/ash_a2ui/priv/js/ash_a2ui_theme.css"

const a2uiCatalog = createAshA2uiCatalog({
  Catalog,
  basicCatalog,
  ChoicePickerApi,
  ColumnApi,
  A2uiLitElement,
  A2uiController,
  lit: {html, css, nothing},
})

const adminCatalog = createAshAdminCatalog({
  Catalog,
  // The admin catalog extends whatever basic catalog it is handed — give it
  // the merged one so its pickers keep the select/combobox upgrades.
  basicCatalog: a2uiCatalog,
  A2uiLitElement,
  A2uiController,
  z,
  lit: {html, css, nothing},
})

configureAshA2ui({MessageProcessor, catalogs: [a2uiCatalog, adminCatalog]})

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, AshA2ui},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

