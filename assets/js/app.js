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
import {hooks as colocatedHooks} from "phoenix-colocated/alpaca_trader"
import topbar from "../vendor/topbar"

const Hooks = {
  CollapsibleJson: {
    mounted() { this._render() },
    updated() { this._render() },
    _render() {
      const data = JSON.parse(this.el.dataset.json)
      // Clear previous content safely
      while (this.el.firstChild) this.el.removeChild(this.el.firstChild)
      this.el.appendChild(buildJsonNode(data, 0, true))
    }
  }
}

function esc(s) {
  const d = document.createElement("span")
  d.textContent = s
  return d.textContent
}

function span(cls, text) {
  const el = document.createElement("span")
  el.className = cls
  el.textContent = text
  return el
}

function buildJsonNode(data, depth, open) {
  if (data === null) return span("text-gray-500", "null")
  if (typeof data === "boolean") return span("text-yellow-400", String(data))
  if (typeof data === "number") return span("text-purple-400", String(data))
  if (typeof data === "string") return span("text-green-300", `"${esc(data)}"`)

  const frag = document.createDocumentFragment()

  if (Array.isArray(data)) {
    if (data.length === 0) return span("text-gray-500", "[]")
    const details = document.createElement("details")
    if (open) details.open = true
    const summary = document.createElement("summary")
    summary.className = "cursor-pointer select-none hover:text-white text-gray-400 inline"
    summary.textContent = `Array(${data.length}) [`
    details.appendChild(summary)
    const content = document.createElement("div")
    content.className = "pl-4"
    data.forEach((v, i) => {
      const line = document.createElement("div")
      line.appendChild(buildJsonNode(v, depth + 1, false))
      if (i < data.length - 1) line.appendChild(document.createTextNode(","))
      content.appendChild(line)
    })
    details.appendChild(content)
    details.appendChild(document.createTextNode("]"))
    return details
  }

  if (typeof data === "object") {
    const keys = Object.keys(data)
    if (keys.length === 0) return span("text-gray-500", "{}")
    const details = document.createElement("details")
    if (open) details.open = true
    const summary = document.createElement("summary")
    summary.className = "cursor-pointer select-none hover:text-white text-gray-400 inline"
    summary.textContent = `{${keys.length} keys} {`
    details.appendChild(summary)
    const content = document.createElement("div")
    content.className = "pl-4"
    keys.forEach((k, i) => {
      const line = document.createElement("div")
      const key = span("text-cyan-400", `"${esc(k)}"`)
      line.appendChild(key)
      line.appendChild(document.createTextNode(": "))
      line.appendChild(buildJsonNode(data[k], depth + 1, false))
      if (i < keys.length - 1) line.appendChild(document.createTextNode(","))
      content.appendChild(line)
    })
    details.appendChild(content)
    details.appendChild(document.createTextNode("}"))
    return details
  }

  return span("text-gray-300", String(data))
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
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

