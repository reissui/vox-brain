import { normalizeGatewayUrl } from "./capture.js"

const form = document.querySelector("#settingsForm")
const gatewayUrl = document.querySelector("#gatewayUrl")
const token = document.querySelector("#token")
const status = document.querySelector("#status")
const saved = await chrome.storage.local.get(["gatewayUrl", "token"])
gatewayUrl.value = saved.gatewayUrl || ""
token.value = saved.token || ""

document.querySelector("#paste").addEventListener("click", async () => {
  try {
    token.value = (await navigator.clipboard.readText()).trim()
    setStatus(token.value ? "Token pasted. Test the connection to finish." : "The clipboard is empty.")
  } catch {
    setStatus("Chrome could not read the clipboard. Paste with Command-V instead.", "error")
  }
})

form.addEventListener("submit", async (event) => {
  event.preventDefault()
  setStatus("Testing…")
  try {
    const normalized = normalizeGatewayUrl(gatewayUrl.value)
    const response = await fetch(`${normalized}/health`)
    const body = await response.json()
    if (!response.ok || body.ok !== true) throw new Error("The gateway health check failed.")
    await chrome.storage.local.set({ gatewayUrl: normalized, token: token.value.trim() })
    setStatus("Connected. Toolbar and right-click capture are ready.", "success")
  } catch (error) {
    setStatus(error.message, "error")
  }
})

function setStatus(message, kind = "") {
  status.textContent = message
  status.className = kind
}
