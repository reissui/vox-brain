import { buildCapture, sendCapture } from "./capture.js"
import { collectDesignEvidence } from "./design.js"

const menus = [
  { id: "brain-save-page", title: "Save page to Brain", contexts: ["page", "action"] },
  { id: "brain-save-selection", title: "Save selection to Brain", contexts: ["selection"] },
  { id: "brain-save-link", title: "Save link to Brain", contexts: ["link"] },
  { id: "brain-save-design", title: "Save to Brain as design", contexts: ["page", "link", "image"] },
]

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.removeAll(() => {
    for (const menu of menus) chrome.contextMenus.create(menu)
  })
})

chrome.contextMenus.onClicked.addListener(async (info, tab) => {
  const isSelection = info.menuItemId === "brain-save-selection"
  const isDesign = info.menuItemId === "brain-save-design"
  const url = isDesign
    ? info.linkUrl || info.pageUrl || tab?.url || info.srcUrl || ""
    : info.linkUrl || info.srcUrl || info.pageUrl || tab?.url || ""
  try {
    const evidence = isDesign
      ? await collectDesignEvidence(tab, {
          targetUrl: url,
          sourceImageUrl: info.srcUrl,
          selection: info.selectionText,
        })
      : { text: isSelection ? info.selectionText : "", image: "" }
    const capture = buildCapture({
      url,
      text: evidence.text,
      type: isDesign ? "design" : "auto",
      image: evidence.image,
    })
    const settings = await chrome.storage.local.get(["gatewayUrl", "token"])
    const saved = await sendCapture(settings, capture)
    const message = isDesign && saved.evidence?.visual
      ? "Saved with a local visual and source context."
      : "It is queued for the Librarian."
    notify("Saved to Brain", message)
  } catch (error) {
    if (/settings|token/i.test(error.message)) chrome.runtime.openOptionsPage()
    notify("Brain capture failed", error.message)
  }
})

function notify(title, message) {
  chrome.notifications.create({ type: "basic", title, message, iconUrl: "icon.svg" })
}
