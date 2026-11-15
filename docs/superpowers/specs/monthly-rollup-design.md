# monthly-rollup — Design

**task-brief:** `monthly-rollup`  
**Status:** Approved in chat (2026-11-16); user said start / no more questions.  
**Version target:** 0.6.0

## 1. Functional requirements

1. **Detail retention = current calendar month only** (router local TZ): keep `traffic_samples` and `sessions` whose timestamps fall in the current `YYYY-MM`.
2. **Roll every complete calendar month still present as detail** (not only “previous month”), then purge **only** months that were successfully rolled (or that had no detail to roll):
   - Discover month keys `< current` that still have `traffic_samples` / `sessions` in that month window.
   - For each such month, oldest-first: aggregate by `(device, target)` summing `bytes_up` / `bytes_down`; per device Top **100** + `__other__`/`其他`; INSERT into `monthly_traffic` (idempotent if month already present).
   - After a successful roll (or empty month), DELETE that month’s samples/sessions.
   - **Never** DELETE detail for a month that was not rolled when it had data (upgrade / stalled collector with M-2+ must not lose history).
3. **Device detail calendar** only offers days in the **current** month (with data). UI month clamp must use **router** local time (from `status` / API `now`), not the browser TZ alone.
4. **Past months UI**: on device detail page, a 「往月汇总」 control to pick a past month and list that device’s Top 100 + 「其他」 (no timed session drill-down).
5. Overview ranges that need data older than current month may use monthly rollups later; **this release** focuses on rollup + detail purge + device-detail UI. Overview may keep working on current-month detail only (allowed_ranges naturally shrink).
6. **Detail retention = current calendar month only.** UCI `retention_value`/`retention_unit` no longer drive sample/session purge; settings/estimate/`allowed_ranges`/confirm copy must match that (no fake “shorten retention” confirm against rolling days).

## 2. Technical decisions (frozen)

| Decision | Choice |
|----------|--------|
| Top N | **100 per device** (not global) |
| Aggregate grain | `device + target` sums of ↑ and ↓ |
| Other bucket | `target = '__other__'`, `display = '其他'` |
| TZ | Router local (`os.date` / existing timeutil) |
| When rollup runs | Collector retention pass: roll **all** complete months with leftover detail, then purge only those months |
| Idempotency | If `monthly_traffic` already has rows for that `month`, skip insert; still purge that month’s detail after roll success / empty |
| Source for rollup | Prefer `traffic_samples` for the month window; if samples empty but sessions exist, fall back to sessions sums for that month |
| Replace rolling retention | Detail retention = **calendar current month**; UCI retention fields do not purge detail; monthly summaries kept indefinitely by default |
| Purge authority | One path owns sample/session deletes for past months (rollup). `retention_sql` must not delete unrolled months’ detail |
| Rollup vs GC | Rollup failure must not skip unrelated GC; surface distinct `rollup_failed` (never purge unrolled data on failure) |
| Device list | `devices`/`overview` must not drop last_seen-only devices (no drive-by narrowing vs 0.5.4) |
| LuCI views | Single editable source per view; versioned copies stay byte-identical or are generated — no divergent forks |
| Schema | New table + migration v5 |
| UI placement | Device detail: calendar = current month; 「往月汇总」 for past months |

## 3. Interfaces

### Schema `monthly_traffic`

```sql
CREATE TABLE IF NOT EXISTS monthly_traffic (
  month TEXT NOT NULL,          -- 'YYYY-MM'
  device TEXT NOT NULL,
  target TEXT NOT NULL,         -- target key or '__other__'
  display TEXT NOT NULL,
  bytes_up INTEGER NOT NULL DEFAULT 0,
  bytes_down INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (month, device, target)
);
CREATE INDEX IF NOT EXISTS idx_monthly_device_month ON monthly_traffic(device, month);
```

### Collector

- `rollup_previous_month(db, now)` called from retention path.
- Month bounds via `timeutil` helpers: `month_start(ts)`, `next_month_start(ts)`, `month_key(ts)`.

### ubus / API

- `device_detail`: `days` chips limited to current month; reject `day` outside current month with `bad_day` or empty.
- New: `device_months` → `{ mac, months: ['2026-10', ...] }` from `monthly_traffic`.
- New: `device_month_summary` → `{ mac, month, rows: [{display,target,bytes_up,bytes_down,bytes_total}, ...] }` sorted by total desc (其他 last or tagged).

### LuCI

- Device detail: calendar only current month; button/section 「往月汇总」 loads months + table.

## 4. Out of scope

- Hourly pre-aggregation for overview
- Changing sample interval
- Editing/deleting monthly rows from UI
- Migrating already-purged history (only rolls months still present as detail)

## 5. Acceptance criteria

- **A1**: After rollup for month `M`, `monthly_traffic` has ≤101 rows per device for `M` (≤100 named + optional 其他).
- **A2**: Per-device Top 100 are the highest `(up+down)` targets after summing all detail rows for that device+target in `M`; 其他 equals sum of the rest (up/down separate).
- **A3**: After successful rollup of month `M`, no `traffic_samples` / `sessions` remain with timestamps in `M` (`M` ≠ current). Detail for any complete month that still has data is rolled before delete.
- **A3b**: If detail exists for months M-2, M-1, … (upgrade / stall), one retention pass produces `monthly_traffic` for each and leaves no unrolled past-month detail; it must **not** delete past-month detail without a corresponding roll.
- **A4**: Device detail calendar does not list days outside the router’s current calendar month (UI uses router clock).
- **A5**: Device detail can list past months from `monthly_traffic` and show Top100+其他 for a selected month.
- **A6**: Re-running rollup for an already-rolled month does not duplicate rows; detail for that month stays empty.
- **A7**: Settings/estimate/`allowed_ranges`/README match calendar-month detail retention (UCI day/week retention no longer claims to purge detail).
- **A8**: `devices`/`overview` still include devices visible via `last_seen` in-range even with no samples in-range (parity with pre-rollup overview behavior).
