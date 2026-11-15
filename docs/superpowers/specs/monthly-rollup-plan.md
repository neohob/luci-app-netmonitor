# monthly-rollup — Implementation Plan

> **For agentic workers:** Implement task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Calendar-month detail retention + per-device Top100 monthly rollup + device-detail 「往月汇总」 UI. Ship as **0.6.0**.

**Spec:** `docs/superpowers/specs/monthly-rollup-design.md`  
**ADR:** `docs/superpowers/specs/monthly-rollup-adr.md`  
**Testplan:** `docs/superpowers/specs/monthly-rollup-testplan.md`

**Tech stack:** OpenWrt Lua (netmonitor), SQLite, LuCI JS, existing `tests/lua` harness.

## Global constraints

- Top **100 per device**, not global; remainder → `target='__other__'`, `display='其他'`.
- Detail = **current calendar month only** (router local TZ).
- Conductor owns design/ADR/glossary/plan/testplan — **do not edit those**; decisions go in progress 待决问题.
- Version bump **0.6.0** for both `netmonitor` and `luci-app-netmonitor`.
- Cache-bust device JS (new `device_06x.js` or bump menu path) so LuCI clients pick up UI.
- No drive-by refactors. Prefer small focused modules (`rollup.lua` OK).

## Review focus

- Month boundaries / TZ correctness (`timeutil`).
- Idempotent rollup (no duplicate monthly rows; purge still runs).
- Top100 ranking after SUM, 其他 = exact remainder of up/down.
- device_detail must not expose days outside current month.
- ACL + examples for new ubus methods.

---

### Task 1: timeutil month helpers

**Files:**
- Modify: `netmonitor/files/lib/netmonitor/timeutil.lua`
- Modify: `tests/lua/test_collector.lua` and/or new `tests/lua/test_timeutil.lua`

- [ ] `month_key(ts)` → `YYYY-MM`
- [ ] `month_start(ts)` → unix at local 00:00 of 1st
- [ ] `next_month_start(ts)` → first second of next month
- [ ] `prev_month_key(ts)` / bounds for previous calendar month
- [ ] White-box W1–W2

### Task 2: schema v5 `monthly_traffic`

**Files:**
- Modify: `netmonitor/files/lib/netmonitor/schema.lua`

- [ ] `M.VERSION = 5`
- [ ] Migration creates `monthly_traffic` + `idx_monthly_device_month`
- [ ] White-box W3 (apply on empty + existing v4 DB)

### Task 3: rollup + retention rewrite

**Files:**
- Create: `netmonitor/files/lib/netmonitor/rollup.lua` (or fold into collector if tiny)
- Modify: `netmonitor/files/lib/netmonitor/collector.lua`
- Modify: `netmonitor/Makefile` if new file install path needed
- Modify: `tests/lua/test_collector.lua` / `tests/lua/test_rollup.lua`

- [ ] Aggregate month window from `traffic_samples` (`GROUP BY device, target`); fallback sessions if no samples
- [ ] Per device: sort by `(up+down)` desc; keep Top 100; sum rest into `__other__`
- [ ] **F1:** Discover **all** complete months `< current` with leftover detail; roll oldest-first; purge **only** rolled/empty months — never wipe M-2+ without rollup
- [ ] INSERT OR IGNORE / skip insert if month already present; still purge that month’s detail after success
- [ ] **F6:** One purge authority for past-month samples/sessions (rollup). Do not also DELETE those rows via a blind `retention_sql(month_start)` that can race ahead of rollup
- [ ] **F7:** Rollup failure returns distinct error/warning; still allow safe GC that cannot delete unrolled months
- [ ] Call from `retention_pass` so collector periodic path runs it
- [ ] White-box W4–W9 + **W16** (multi-month leftover)

### Task 3b: Review Round-1 fixes (F2–F8, selected nits)

- [ ] **F2:** `retention_cutoff` / estimate / set_config confirm / `allowed_ranges` / settings copy / tests = calendar-month semantics
- [ ] **F3:** Restore devices visible via in-range `last_seen` without samples
- [ ] **F4:** Device UI month clamp uses router clock from status/API
- [ ] **F5:** Single editable `device.js` / `overview.js`; versioned menu copies byte-identical (W assert); drop dead `_054` if unused
- [ ] **F8:** `pair_rows` uses covering index or drop unused schema cost
- [ ] **F9/F11/F12:** shared OTHER sentinel; CSS `?v=` matches 0.6.0; reject invalid `YYYY-MM` in `parse_month`
- [ ] F10/F13 wontfix (document in progress)

### Task 4: API — calendar clamp + month summary

**Files:**
- Modify: `netmonitor/files/lib/netmonitor/api.lua`
- Modify: ACL `luci-app-netmonitor/root/usr/share/rpcd/acl.d/luci-app-netmonitor.json`
- Modify: `tests/lua/test_api.lua`

- [ ] `device_detail`: `days` only current month; reject/ignore `day` outside current month
- [ ] `device_months({mac})` → sorted month keys
- [ ] `device_month_summary({mac, month})` → rows Top100 + 其他, totals
- [ ] Wire examples / dispatcher registration
- [ ] ACL read methods include the two new ones
- [ ] White-box W10–W13

### Task 5: LuCI device 「往月汇总」 + settings copy

**Files:**
- Modify: `device.js` / new cache-busted `device_06x.js` + menu path
- Modify: `common.js` (rpc.declare for new methods)
- Modify: `settings.js` (retention help text: detail = current month; past = monthly Top100)
- Modify: `README.md` briefly
- Modify: both Makefiles → **0.6.0**

- [ ] Calendar chips: current month only (client + server)
- [ ] UI: month picker + table of destinations with ↑↓ totals (no session expand for past months)
- [ ] White-box W14–W15 (static/file asserts OK)

### Task 6: Self-prove

- [ ] Run full `tests/lua` suite; all new W* green
- [ ] Write `docs/superpowers/specs/monthly-rollup-progress.md` per contract
- [ ] Signal `✅ PIPELINE_DONE` or `⛔ PIPELINE_BLOCKED`
