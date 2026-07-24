import { buildCapture, sendCapture } from "./capture.js"
import { collectDesignEvidence } from "./design.js"

const form = document.querySelector("#captureForm")
const note = document.querySelector("#note")
const type = document.querySelector("#type")
const status = document.querySelector("#status")
const submit = form.querySelector('button[type="submit"]')
const [tab] = await chrome.tabs.query({ active: true, currentWindow: true })
document.querySelector("#pageTitle").textContent = tab?.title || "Current page"

let selection = ""
if (tab?.id && /^https?:/.test(tab.url || "")) {
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      func: () => window.getSelection()?.toString() || "",
    })
    selection = String(result?.result || "").trim()
    document.querySelector("#selectionHint").hidden = !selection
  } catch {
    // Browser-internal pages cannot be scripted; the URL can still be saved.
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault()
  setStatus("Saving…")
  submit.disabled = true
  try {
    const settings = await chrome.storage.local.get(["gatewayUrl", "token"])
    const evidence = type.value === "design"
      ? await collectDesignEvidence(tab, { targetUrl: tab?.url, selection })
      : { text: selection, image: "" }
    const capture = buildCapture({
      url: tab?.url,
      note: note.value,
      text: evidence.text,
      type: type.value,
      image: evidence.image,
    })
    const saved = await sendCapture(settings, capture)
    const message = type.value === "design" && saved.evidence?.visual
      ? "Saved with a local visual and source context."
      : "Saved. The Librarian will take it from here."
    setStatus(message, "success")
    setTimeout(() => window.close(), 850)
  } catch (error) {
    setStatus(error.message, "error")
    if (/settings|token/i.test(error.message)) setTimeout(() => chrome.runtime.openOptionsPage(), 500)
  } finally {
    submit.disabled = false
  }
})

document.querySelector("#settings").addEventListener("click", () => chrome.runtime.openOptionsPage())

function setStatus(message, kind = "") {
  status.textContent = message
  status.className = kind
}
