# Design — Destination resolve (DNS+SNI) + upload/download UI

**Date:** 2026-11-14 · **Version target:** 0.2.0

## Goals

1. Resolve remote IPs to domain/service names (DNS first; TLS SNI / HTTP Host only when still unresolved).
2. Distinguish upload vs download in sessions, device cards, and topology edges.
3. **Out of scope:** per-process / per-app attribution on the LAN device (deferred).

## Data flow

```
nf_conntrack → up/down deltas → SQLite
dnsmasq log  → IP→name (memory + persist ip_names)
unresolved IP → optional SNI/Host probe (tcpdump soft-dep) → ip_names
ubus → LuCI (↑↓ on nodes/edges/cards)
```

Priority: DNS > SNI > HTTP Host > raw IP (`未解析`).

## Schema v2

- `targets.source` (`dns`|`sni`|`http_host`|`ip`), `targets.resolved_at`
- `ip_names(ip PRIMARY KEY, name, source, updated_at)`

## Probe

- UCI `sni_enable` default 1; unresolved-only; per-IP cooldown
- Soft-dep `tcpdump`; missing → warning `sni_unavailable`

## UI

- Nodes/cards show `↑`/`↓`; edge tooltips `↑x · ↓y`; SNI/Host source tags
