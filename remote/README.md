# Optional remote Brain

This area contains everything that exists only for an external Brain runner.
Local-only users can ignore it.

## Remote topology

| Component | Responsibility |
|---|---|
| Brain runner (for example a Mac mini) | canonical Markdown vault, Brain CLI, Librarian, automation, and Brain Agent |
| `gateway/` | pairing, authenticated API, MCP, capture and job ingress |
| D1 | operational device, capture, job, and recent health state |
| R2 | immutable binary originals |
| Queues | delivery from the gateway to the runner |
| Cloudflare Tunnel | outbound-only route to the runner API |
| Brain.app | paired client with an opaque Keychain device token |

## Setup

Remote operators provide their own:

- runner and absolute vault path;
- Cloudflare account, Worker, D1, R2, Queue, and Tunnel;
- public gateway and private runner hostname;
- instance identifier and secrets;
- optional MCP password and any third-party OAuth clients; and
- filesystem backup for the canonical vault.

The dependency-ordered setup, pairing, verification, cutover, and rollback
procedure is in [the remote instance runbook](setup.md).
Runner implementation details are in
[apps/brain-agent](../apps/brain-agent/README.md), gateway details in
[gateway](../gateway/README.md), and reliability behavior in
[the reliability runbook](reliability.md).

## Boundary from local mode

Remote settings appear under the **Remote** group in Brain.app only when remote
mode is selected. Gmail, MCP, gateway health, runner health, pairing, Cloudflare
resources, and remote job delivery are not loaded or required in local mode.

Remote mutation remains a fixed allowlist: capture, Process, Digest, and Ask.
Pairing never grants an arbitrary shell.
