# Remote reliability and recovery

Brain.app is the paired client health surface. The runner's `brain status`,
`brain doctor`, launchd state, and logs are the operator diagnostics beside the
canonical data folder.

## State and freshness

Checks report healthy, activity, warning, or failure. Live status requests pass
through Tunnel to the loopback Agent. D1 may retain a recent operational
snapshot; if the origin is unavailable, the gateway labels that response
**stale** with its age. Stale history must never appear as live green health.

An unpaired local-mode app makes no private remote request. A revoked remote
device reports authorization failure and never silently falls back to another
vault.

## Failure isolation

| Symptom | Inspect in order | Data impact |
|---|---|---|
| no HTTP 202 | device token/scope → D1 → R2 if binary → Queue publish | retry the same idempotency key |
| capture remains queued | Queue token → Agent poll/log → remote inbox → result callback | do not delete staged state |
| knowledge/Ask unavailable | Tunnel → origin token → Agent loopback API → data root | vault remains intact |
| status is stale | Worker → Tunnel connector → Agent launchd → heartbeat | D1 is context only |
| private site failed | process marker → publisher log → staging allowlist → Pages | vault remains canonical |
| Gmail unavailable | OAuth client/grant → Gmail API → signed callback | mailbox and Markdown unchanged |

D1 and Queue are operational. R2 retains immutable capture originals.
Markdown in `BRAIN_DATA_ROOT` is the recoverable knowledge record.

## Runner checks

```sh
cd "$HOME/dev/vox-brain"
scripts/brain status
scripts/brain doctor
scripts/brain automate status
codex login status
launchctl print "gui/$(id -u)/app.voxbrain.agent"
launchctl print "gui/$(id -u)/app.voxbrain.telegram"
remote/install-cloudflared.sh status
scripts/brain gmail status --check-api
```

Recovery commands:

```sh
launchctl kickstart -k "gui/$(id -u)/app.voxbrain.agent"
launchctl kickstart -k "gui/$(id -u)/app.voxbrain.telegram"
tail -n 200 -F "$HOME/Library/Application Support/Brain Agent/logs/agent.stderr.log"
tail -n 200 -F /tmp/app.voxbrain.telegram.log
```

Restart services before modifying state. Never delete a D1 row, Queue message,
R2 object, inbox file, or migration manifest just to clear a warning.

## Updates

1. Back up `BRAIN_DATA_ROOT`.
2. Retain the previous app/source artifact.
3. Fast-forward the source checkout.
4. Run `scripts/check`.
5. Apply D1 migrations before deploying the Worker.
6. Rerun the idempotent Agent installer when runner code/config changes.
7. Smoke-test live health, capture, Knowledge, Process, Digest, Ask, and MCP.

Use `apps/brain-agent/install.sh rollback` to restore the saved Agent runtime
configuration. Rollback does not roll back or delete vault data.

## Backup

Back up the data root with Time Machine or another filesystem backup. Back up
R2 separately if permanent originals matter to recovery. Do not treat the
source repository, D1, or a Pages build as a vault backup.
