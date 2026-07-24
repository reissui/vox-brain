const MAX_IMAGE_BYTES = 4 * 1024 * 1024
const MAX_CONTEXT_CHARS = 12000

export async function collectDesignEvidence(tab, options = {}) {
  const targetUrl = String(options.targetUrl || tab?.url || "")
  const sourceImageUrl = String(options.sourceImageUrl || "")
  const selection = String(options.selection || "").trim()
  const pageIsTarget = samePage(targetUrl, tab?.url || "")
  const page = tab?.id && pageIsTarget ? await inspectPage(tab.id, targetUrl, sourceImageUrl) : {}
  const text = formatPageEvidence({ ...page, selection })
  const imageUrl = sourceImageUrl || page.imageUrl || ""
  const image = await imageDataUrl(imageUrl) || (pageIsTarget ? await visibleTabImage(tab) : "")
  return { text, image }
}

export function formatPageEvidence({ title = "", description = "", content = "", selection = "" }) {
  const sections = []
  const cleanTitle = compact(title)
  const cleanDescription = compact(description)
  const cleanContent = String(content).trim()
  const cleanSelection = String(selection).trim()
  if (cleanTitle) sections.push(`PAGE TITLE: ${cleanTitle}`)
  if (cleanDescription && cleanDescription !== cleanTitle) sections.push(`DESCRIPTION: ${cleanDescription}`)
  if (cleanContent) sections.push(`VISIBLE DESIGN CONTEXT:\n${cleanContent}`)
  if (cleanSelection && !cleanContent.includes(cleanSelection)) sections.push(`SELECTED TEXT:\n${cleanSelection}`)
  return sections.join("\n\n").slice(0, MAX_CONTEXT_CHARS).trim()
}

async function inspectPage(tabId, targetUrl, sourceImageUrl) {
  try {
    const [result] = await chrome.scripting.executeScript({
      target: { tabId },
      args: [targetUrl, sourceImageUrl, MAX_CONTEXT_CHARS],
      func: (requestedUrl, requestedImage, maxChars) => {
        const title = document.title || ""
        const description = document.querySelector('meta[property="og:description"], meta[name="description"]')?.content || ""
        const statusId = /\/status\/(\d+)/.exec(requestedUrl)?.[1] || /\/status\/(\d+)/.exec(location.href)?.[1] || ""
        const articles = Array.from(document.querySelectorAll("article"))
        const article = statusId
          ? articles.find((candidate) => candidate.querySelector(`a[href*="/status/${statusId}"]`))
          : articles.find((candidate) => {
              const box = candidate.getBoundingClientRect()
              return box.width > 0 && box.height > 0 && box.bottom > 0 && box.top < innerHeight
            })
        const root = article || document.querySelector("main")
        const content = (root?.innerText || "").trim().slice(0, maxChars)
        const images = Array.from((article || document).querySelectorAll("img"))
        const sourceImage = images.find((candidate) => candidate.src.includes("pbs.twimg.com/media/"))
          || images.find((candidate) => candidate.naturalWidth >= 400 && candidate.naturalHeight >= 250)
        return {
          title,
          description,
          content,
          imageUrl: requestedImage || sourceImage?.currentSrc || sourceImage?.src || "",
        }
      },
    })
    return result?.result || {}
  } catch {
    return {}
  }
}

async function imageDataUrl(url) {
  if (!/^https?:/i.test(url)) return ""
  try {
    const response = await fetch(url)
    if (!response.ok) return ""
    const bytes = await boundedBytes(response, MAX_IMAGE_BYTES)
    if (!bytes) return ""
    const mime = imageMime(response.headers.get("content-type"), bytes)
    if (!mime) return ""
    return `data:${mime};base64,${base64(bytes)}`
  } catch {
    return ""
  }
}

async function visibleTabImage(tab) {
  if (tab?.windowId === undefined) return ""
  try {
    return await chrome.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 82 })
  } catch {
    return ""
  }
}

async function boundedBytes(response, limit) {
  const declared = Number(response.headers.get("content-length") || "0")
  if (Number.isFinite(declared) && declared > limit) return null
  if (!response.body) return null
  const reader = response.body.getReader()
  const chunks = []
  let total = 0
  while (true) {
    const { done, value } = await reader.read()
    if (done) break
    total += value.byteLength
    if (total > limit) {
      await reader.cancel()
      return null
    }
    chunks.push(value)
  }
  const bytes = new Uint8Array(total)
  let offset = 0
  for (const chunk of chunks) {
    bytes.set(chunk, offset)
    offset += chunk.byteLength
  }
  return bytes
}

function imageMime(header, bytes) {
  const mime = String(header || "").split(";", 1)[0].trim().toLowerCase()
  if (["image/jpeg", "image/png", "image/webp"].includes(mime)) return mime
  if (bytes[0] === 0xff && bytes[1] === 0xd8) return "image/jpeg"
  if (bytes.length >= 8 && String.fromCharCode(...bytes.slice(0, 8)) === "\x89PNG\r\n\x1a\n") return "image/png"
  if (bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === "RIFF" && String.fromCharCode(...bytes.slice(8, 12)) === "WEBP") return "image/webp"
  return ""
}

function base64(bytes) {
  let binary = ""
  for (let index = 0; index < bytes.length; index += 0x2000) {
    binary += String.fromCharCode(...bytes.slice(index, index + 0x2000))
  }
  return btoa(binary)
}

function compact(value) {
  return String(value).replace(/\s+/g, " ").trim()
}

function samePage(target, current) {
  if (!target || !current) return true
  try {
    const a = new URL(target)
    const b = new URL(current)
    const aStatus = /\/status\/(\d+)/.exec(a.pathname)?.[1]
    const bStatus = /\/status\/(\d+)/.exec(b.pathname)?.[1]
    if (aStatus || bStatus) return Boolean(aStatus && aStatus === bStatus)
    return a.origin === b.origin && a.pathname === b.pathname
  } catch {
    return target === current
  }
}
