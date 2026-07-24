/**
 * Minimal compatibility client for the retired GitHub-backed capture route.
 * New deployments should leave this route unconfigured and use `/v1/captures`.
 */

export const GITHUB_API_BASE = "https://api.github.com";
export type PutResult = { ok: true } | { ok: false; status: number; error: string };

/** Create `path` in the repo with `markdown` as its content. */
export async function putContents(
  token: string,
  repository: string,
  path: string,
  markdown: string,
  message: string,
): Promise<PutResult> {
  return putBase64Contents(token, repository, path, base64Utf8(markdown), message);
}

/** Create a binary file whose contents are already base64 encoded. */
export async function putBase64Contents(
  token: string,
  repository: string,
  path: string,
  content: string,
  message: string,
): Promise<PutResult> {
  const encodedPath = path.split("/").map(encodeURIComponent).join("/");
  let response: Response;
  try {
    const encodedRepository = repository.split("/").map(encodeURIComponent).join("/");
    response = await fetch(`${GITHUB_API_BASE}/repos/${encodedRepository}/contents/${encodedPath}`, {
      method: "PUT",
      headers: {
        authorization: `Bearer ${token}`,
        accept: "application/vnd.github+json",
        "content-type": "application/json",
        "user-agent": "brain-gw",
        "x-github-api-version": "2022-11-28",
      },
      body: JSON.stringify({ message, content }),
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return { ok: false, status: 0, error: `github request failed: ${detail}` };
  }
  if (!response.ok) {
    const body = (await response.text().catch(() => "")).slice(0, 200);
    return {
      ok: false,
      status: response.status,
      error: `github api responded ${response.status}${body ? `: ${body}` : ""}`,
    };
  }
  return { ok: true };
}

/** UTF-8-safe base64 (chunked to keep String.fromCharCode within argument limits). */
export function base64Utf8(value: string): string {
  const bytes = new TextEncoder().encode(value);
  let binary = "";
  const chunkSize = 0x2000;
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunkSize));
  }
  return btoa(binary);
}
