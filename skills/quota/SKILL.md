---
name: quota
description: Quota left on the AI subscriptions (Claude, Codex, Cursor, OpenCode Go), read live from QuotaBar. Use when asked how much quota remains or when it resets, or when picking a model by headroom.
---

# Quota

Read the feed with this one-liner, which prints one line per provider:

```bash
curl -s --max-time 25 127.0.0.1:8787/quotas | jq -r '.providers[] | "\(.id) [\(.status)]: \([.quotas[] | "\(.label) \(if .percentRemaining then "\(.percentRemaining|floor)%" else "\(.balanceRemaining) \(.balanceUnit // "")" end) (\(.resetText // "no reset"))"] | join(", "))"'
```

Done when every enabled provider has a line. Drop the `jq` stage for fields it hides, such as `resetsAt`, `unitsUsed` or `balanceCap`.

An empty result means QuotaBar is not running or its feed is off: report that, and point the user to QuotaBar's settings to turn on the feed.

## Reading it

- **Headroom** is a provider's lowest `percentRemaining` across its quotas. Rank providers by headroom when picking a model.
- **`status`** (`healthy`, `warning`, `critical`, `depleted`) is pace-aware: it weighs the percent left against the time left until reset. A low percent that will last to the reset is `healthy`; trust `status` over the raw percent when judging urgency.
- The feed refreshes before it answers, so a reply can take up to 20 s.
