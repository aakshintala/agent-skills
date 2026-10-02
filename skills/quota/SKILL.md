---
name: quota
description: Check how much AI subscription quota is left (Claude, Codex, Cursor, OpenCode Go) via the local QuotaBar feed. Use when asked about remaining quota, usage, rate limits, headroom, or when resets happen, or before picking a model for delegated work.
---

# Quota

QuotaBar serves live quota on localhost. Query it with:

```bash
curl -s 127.0.0.1:8787/quotas
```

It refreshes before answering (up to 20 s). Connection refused means QuotaBar is not running or its feed is off (Settings, Quota feed); say so rather than guessing.

## Shape

```json
{"providers": [{"id": "claude", "tier": "Max", "status": "healthy",
  "quotas": [{"key": "session", "label": "Session", "percentRemaining": 94,
              "resetsAt": "2026-10-02T04:00:00Z", "resetText": "Resets in 2h",
              "status": "healthy"}]}]}
```

- Provider ids: `claude`, `codex`, `cursor`, `opencode-go`.
- `status` is pace-aware: `healthy`, `warning`, `critical`, `depleted`.
- A provider's headroom is the lowest `percentRemaining` across its quotas.
- Some quotas carry `unitsUsed`/`unitsLimit` or `balanceRemaining`/`balanceCap` instead of or alongside the percent.

One line per provider:

```bash
curl -s 127.0.0.1:8787/quotas | jq -r '.providers[] | "\(.id): \([.quotas[] | "\(.label) \(.percentRemaining|floor)% (\(.resetText))"] | join(", "))"'
```
