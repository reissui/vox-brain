/**
 * Single-user OAuth consent screen for the remote MCP server (epic Decision 4).
 *
 * `@cloudflare/workers-oauth-provider` (mounted in src/index.ts) implements the
 * OAuth 2.1 machinery — /token, /register, metadata, token checks on /mcp.
 * This module implements the one piece the library leaves to the app: the
 * `/authorize` endpoint. There is exactly one user (the owner), so consent is a
 * password prompt checked against secret MCP_PASSWORD in constant time. The
 * same comparison also backs the optional headless bearer-token path.
 */

import type { AuthRequest } from "@cloudflare/workers-oauth-provider";
import { base64Utf8 } from "./github";
import type { Env } from "./index";

/** The one user every grant belongs to. */
export const MCP_USER_ID = "owner";

/** Accept MCP_PASSWORD directly as a bearer token for clients that support it. */
export function resolveMcpPasswordToken(token: string, expected: string | undefined) {
  if (!expected || !timingSafeEqualStr(token, expected)) return null;
  return { props: { via: "mcp-password" } };
}

export async function handleAuthorize(request: Request, env: Env): Promise<Response> {
  if (request.method === "GET") return renderAuthorizeForm(request, env);
  if (request.method === "POST") return completeAuthorize(request, env);
  return new Response("method not allowed", { status: 405 });
}

/** GET /authorize — parse the OAuth request and show the password form. */
async function renderAuthorizeForm(request: Request, env: Env): Promise<Response> {
  let oauthReqInfo: AuthRequest;
  try {
    oauthReqInfo = await env.OAUTH_PROVIDER.parseAuthRequest(request);
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    return new Response(`invalid authorization request: ${detail}`, { status: 400 });
  }

  const client = await env.OAUTH_PROVIDER.lookupClient(oauthReqInfo.clientId);
  if (!client) return new Response("unknown client", { status: 400 });

  return htmlResponse(200, loginPage(client.clientName ?? oauthReqInfo.clientId, oauthReqInfo));
}

/** POST /authorize — check the password; on success mint the grant and redirect. */
async function completeAuthorize(request: Request, env: Env): Promise<Response> {
  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return new Response("expected form data", { status: 400 });
  }

  const rawOauth = form.get("oauth");
  const password = form.get("password");
  if (typeof rawOauth !== "string" || typeof password !== "string") {
    return new Response("missing form fields", { status: 400 });
  }

  let oauthReqInfo: AuthRequest;
  try {
    oauthReqInfo = JSON.parse(utf8FromBase64(rawOauth)) as AuthRequest;
  } catch {
    return new Response("invalid oauth state", { status: 400 });
  }

  const client = await env.OAUTH_PROVIDER.lookupClient(oauthReqInfo.clientId);
  if (!client) return new Response("unknown client", { status: 400 });

  if (!timingSafeEqualStr(password, env.MCP_PASSWORD)) {
    return htmlResponse(
      401,
      loginPage(client.clientName ?? oauthReqInfo.clientId, oauthReqInfo, "Wrong password."),
    );
  }

  const { redirectTo } = await env.OAUTH_PROVIDER.completeAuthorization({
    request: oauthReqInfo,
    userId: MCP_USER_ID,
    metadata: { authorizedAt: new Date().toISOString() },
    scope: oauthReqInfo.scope,
    props: { via: "mcp" },
  });

  return Response.redirect(redirectTo, 302);
}

/** Constant-time string comparison (length mismatch fails fast, which is fine). */
export function timingSafeEqualStr(a: string, b: string): boolean {
  const encoder = new TextEncoder();
  const aBytes = encoder.encode(a);
  const bBytes = encoder.encode(b);
  if (aBytes.byteLength !== bBytes.byteLength) return false;
  return crypto.subtle.timingSafeEqual(aBytes, bBytes);
}

function loginPage(clientName: string, oauthReqInfo: AuthRequest, error?: string): string {
  const state = base64Utf8(JSON.stringify(oauthReqInfo));
  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="robots" content="noindex">
  <title>Brain — authorize</title>
  <style>
    body { font: 16px/1.5 system-ui, sans-serif; max-width: 26rem; margin: 4rem auto; padding: 0 1rem; }
    input[type=password] { width: 100%; padding: .5rem; font-size: 1rem; box-sizing: border-box; }
    button { margin-top: .75rem; padding: .5rem 1.25rem; font-size: 1rem; cursor: pointer; }
    .error { color: #b00020; }
  </style>
</head>
<body>
  <h1>Brain</h1>
  <p><strong>${escapeHtml(clientName)}</strong> is asking to connect to your brain (save notes, search the vault).</p>
  ${error ? `<p class="error">${escapeHtml(error)}</p>` : ""}
  <form method="post" action="/authorize">
    <input type="hidden" name="oauth" value="${state}">
    <label for="password">Password</label>
    <input id="password" type="password" name="password" autocomplete="current-password" autofocus required>
    <button type="submit">Approve</button>
  </form>
</body>
</html>`;
}

function htmlResponse(status: number, html: string): Response {
  return new Response(html, {
    status,
    headers: { "content-type": "text/html; charset=utf-8" },
  });
}

function escapeHtml(value: string): string {
  return value
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#39;");
}

/** Inverse of `base64Utf8` in src/github.ts. */
function utf8FromBase64(value: string): string {
  const binary = atob(value);
  return new TextDecoder().decode(Uint8Array.from(binary, (char) => char.charCodeAt(0)));
}
