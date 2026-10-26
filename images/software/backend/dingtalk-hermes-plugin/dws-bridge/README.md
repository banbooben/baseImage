# dws-bridge — DingTalk platform plugin for Hermes Agent

Bridges DingTalk into Hermes under a **personal-account identity** (not a bot),
driven by the [dws CLI](https://www.npmjs.com/package/dws-cli). Inbound traffic
comes from long-lived `dws event +listen-im` NDJSON subscription processes;
outbound traffic goes through `dws chat` commands. The credential store lives in
`~/.dws` (device login via `dws auth login --device`) and is shared with the
dsh deployment on purpose — the login state carries over.

## Requirements

- `dws` binary on `PATH` (or `DWS_BIN` pointing at it)
- A device-authorized profile: `dws auth login --device`, then
  `DWS_PROFILE=<corpId:userId>` (check with `dws auth status --format json`)

## Configuration

Environment variables override `config.yaml` (`gateway.platforms.dws_bridge.extra`).

| Variable | Default | Meaning |
|---|---|---|
| `DWS_PROFILE` | — (required) | dws auth profile `corpId:userId` |
| `DWS_BIN` | `dws` | dws binary path |
| `DWS_BRIDGE_GROUPS` | — | CSV group openConversationIds to subscribe |
| `DWS_BRIDGE_DM_ENABLED` | `true` | Subscribe direct messages |
| `DWS_BRIDGE_REQUIRE_MENTION` | `true` | In groups, only answer the trigger prefix or replies to own messages |
| `DWS_BRIDGE_TRIGGER_PREFIX` | `/ai ` | Group trigger prefix |
| `DWS_BRIDGE_ALLOW_WRITES` | `false` | Master gate for outbound messages (listen-only when false) |
| `DWS_BRIDGE_HOME_CHANNEL` | — | Chat ID for cron / notification delivery |
| `DWS_BRIDGE_ALLOWED_USERS` | — | CSV sender staffIds allowed to talk to the agent |
| `DWS_BRIDGE_ALLOW_ALL_USERS` | — | Allow anyone (dev only) |

The plugin must be enabled in `~/.hermes/config.yaml`:

```yaml
plugins:
  enabled:
    - dws-bridge
```

## Warnings

- **Never run the dsh stack and this stack at the same time against the same
  dws volumes** — both consume the same DingTalk stream and would double-answer.
- `DWS_BRIDGE_ALLOW_WRITES=false` means strictly listen-only: the adapter
  answers every `send()` with a `forbidden` error and never invokes a dws send
  command. Verify inbound traffic first, then enable writes.
- DingTalk personal accounts carry real names / phone numbers (`pii_safe=False`).

## Error behaviour

- Auth failure (dws exit 2 or auth/token markers in stderr) → fatal,
  non-retryable; re-run `dws auth login --device` against the shared dws volume.
- Subscription crash → exponential backoff respawn (1s → 30s) until `disconnect()`.
- Own-send echo is suppressed three ways: `message_ai_send_flag=="DWS"`,
  tracked idempotency keys / returned message ids, and a TTL deduplicator.
