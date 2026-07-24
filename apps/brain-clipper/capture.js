export function normalizeGatewayUrl(value) {
  const raw = String(value ?? "").trim().replace(/\/+$/, "")
  if (!raw) throw new Error("Add the Brain gateway URL in extension settings.")
  let url
  try {
    url = new URL(raw)
  } catch {
    throw new Error("The gateway URL is not valid.")
  }
  if (url.protocol !== "https:") throw new Error("The gateway URL must use HTTPS.")
  return url.toString().replace(/\/$/, "")
}

export function buildCapture({ url, note, text, type, image, source = "chrome-extension" }) {
  const payload = { source }
  if (String(url ?? "").trim()) payload.url = String(url).trim()
  if (String(note ?? "").trim()) payload.note = String(note).trim()
  if (String(text ?? "").trim()) payload.text = String(text).trim()
  if (type && type !== "auto") payload.type = type
  if (String(image ?? "").trim()) payload.image = String(image).trim()
  if (!payload.url && !payload.text) throw new Error("There is no page, link, or text to save.")
  return payload
}

export async function sendCapture(settings, capture, fetchImpl = fetch) {
  const gatewayUrl = normalizeGatewayUrl(settings.gatewayUrl)
  const token = String(settings.token ?? "").trim()
  if (!token) throw new Error("Add the capture token in extension settings.")
  const response = await fetchImpl(`${gatewayUrl}/capture`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${token}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify(capture),
  })
  let body
  try {
    body = await response.json()
  } catch {
    body = {}
  }
  if (!response.ok) throw new Error(body.error || `The gateway returned ${response.status}.`)
  if (!body.path) throw new Error("The gateway did not return a saved path.")
  return body
}
