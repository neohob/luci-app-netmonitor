STATUS: READY

# monthly-rollup Progress Report

## Phase 进度
| Phase | 状态 | 说明 |
|-------|------|------|
| Task 1–6 (initial) | ✅ done | prior pass |
| Round-1 fix pass (ORDER-NM-ROLLUP-FIX-R1) | ✅ done | F1–F9/F11/F12 fixed; F10/F13 wontfix |
| W16–W23 + retention/API/UI re-run | ✅ done | 63 lua tests passed |

## 改动文件
- `netmonitor/files/lib/netmonitor/rollup.lua` — discover+roll all complete months oldest-first; purge only rolled/empty
- `netmonitor/files/lib/netmonitor/collector.lua` — retention_sql = devices/targets GC only (F6); rollup fail ≠ skip GC + `rollup_failed` warning (F7)
- `netmonitor/files/lib/netmonitor/timeutil.lua` — strict `parse_month` (F12)
- `netmonitor/files/lib/netmonitor/api.lua` — last_seen devices (F3); covering INDEXED BY (F8); shared OTHER (F9); calendar estimate/confirm (F2); status `today`/`current_month` (F4)
- `luci-app-netmonitor/.../device.js` + `device_06x.js` — router-clock clamp via status (F4); copies byte-identical (F5)
- `luci-app-netmonitor/.../common.js` — CSS `?v=0.6.0` (F11)
- `luci-app-netmonitor/.../settings.js` — calendar-month retention copy (F2)
- removed `device_054.js`, `overview_054.js` (F5)
- `tests/lua/test_rollup.lua` — W16/W17
- `tests/lua/test_monthly_api.lua` — W18/W19/W22
- `tests/lua/test_monthly_ui.lua` — W20/W21
- `tests/lua/test_timeutil.lua` — W23
- `tests/lua/test_api.lua` / `test_collector.lua` — calendar-month retention asserts

## 验证方式
- `lua tests/lua/run_all.lua` → 63 passed, 0 failed

## 白盒用例执行结果（★可整段抽取给 reviewer★）

```
$ lua tests/lua/run_all.lua
W18 PASS — luci-app-netmonitor package name + menu entry present
W1 PASS — set_config without path, collector start refused, status need_wizard
W2 PASS — free=50MiB on 2GiB volume pauses writes, status disk_pause
W3 PASS — free=200MiB allows sample write
    sample aa:bb:cc:00:00:01 -> 8.8.4.4 up=700 down=900 kind=ip
    sample aa:bb:cc:00:00:01 -> www.example.com up=1500 down=24000 kind=domain
    sample aa:bb:cc:00:00:02 -> youtube.com up=4000 down=52000 kind=domain
    sample aa:bb:cc:00:00:03 -> 198.51.100.7 up=30000 down=2000 kind=ip
W4 PASS — one poll on conntrack+dns fixture yields device->domain sample rows
W5 PASS — conntrack IP without DNS answer -> target is IP, unresolved
    now=1794715200 cutoff=1793462400 (2026-11-01 00:00)
W6 PASS — retention keeps current calendar month detail; purges older
    session start=+0 last=+10 dur=10 bytes=300/600 closed=1
    session start=+71 last=+76 dur=5 bytes=200/400 closed=0
W7 PASS — deltas, 61s gap, deltas -> two sessions with duration = last - first
W7b PASS — calendar midnight soft-rolls stats session; TCP untouched
W8b PASS — merge_by_display sums bytes and can strip children
    2026-11-13 start=00:00:00 dur=40s bytes=300/3000
    2026-11-12 start=23:59:30 dur=29s bytes=300/3000
W8 PASS — session crossing midnight splits into two calendar days
W22 PASS — retention_error keeps running (not db_error / not write-pause) (F21)
W23 PASS — dns log truncates in place without unlink (F20)
W9 PASS — conntrack without byte fields -> degraded, no fabricated bytes
W9b PASS — long-lived flow missing from one read is not recounted from zero
    devices=10 targets=10 paths=25 edges=50 total=3025000
W10 PASS — 10 devices / 10 targets, range=1h -> Top4 + 其他 on each side with collapse edges
W11 PASS — Top device -> non-Top destination edge ends at 其他去向
W12 PASS — 12 devices -> devices lists all 12 sorted by traffic
W12b PASS — overview returns topology+devices from one scan
    d:m1>t:a.com color=#22c55e legs=d:m1>t:a.com#in,d:m1>t:a.com#out
    d:m1>t:b.com color=#f59e0b legs=d:m1>t:b.com#in,d:m1>t:b.com#out
W13 PASS — one device, two targets -> two colors, each consistent on both legs
    aa:bb:cc:00:01:02 live=true rate_down=600 B/s; aa:bb:cc:00:01:01 live=false
W14 PASS — recent deltas -> live rate>0; idle device -> not live
W15 PASS — rpcd ACL: read/write split; check_path read-only (no FS mutate)
    allowed_ranges=15m,1h,6h,today,24h,7d
W16 PASS — calendar-month retention: 30d rejected; today allowed (UCI days ignored)
W19 PASS — device_detail API: day chips + sessions via ubus shape (F10)
W19b PASS — device_detail pages busy days by full destination aggregates
W20 PASS — set_config enabled=0 stops collector (F8)
W24 PASS — set_config ignores ubus_rpc_session
W21 PASS — json empty array vs object + round-trip
S1 PASS — parse_tls_sni extracts hostname
S2 PASS — parse_http_host extracts Host
S3 PASS — DNS wins over SNI; SNI fills unresolved
S4 PASS — parse_dns_message extracts A records
ASN1 PASS — normalize_org shortens legal names
ASN2 PASS — config accepts asn options
ASN3 PASS — config rejects bad asn url/hour
ASN4 PASS — dns.target_for prefers DNS then SNI then service then ASN
SVC1 PASS — cidr_to_range and ip_to_u32
SVC2 PASS — first-priority wins on overlap
SVC3 PASS — lookup hit/miss and enable gate
SVC4 PASS — dns.target_for prefers DNS then SNI then service then ASN
W1 PASS — month_key / month_start / next_month_start mid-month
W2 PASS — month bounds on last day 23:59 still same month_key; next crosses
W23 PASS — parse_month rejects 2026-13 / 2026-00 (no normalize)
W3 PASS — schema v5 creates monthly_traffic on empty and v4 DB
W4 PASS — 105 targets → Top100 + __other__ with exact remainder
W5 PASS — equal totals tie-break by target ASC after total DESC
W6 PASS — after rollup prior-month samples/sessions gone; current untouched
W7 PASS — re-run rollup: no duplicate rows; detail stays empty
W8 PASS — samples empty → fall back to sessions sums
W9 PASS — current-month only: no purge; no monthly insert for current
W16 PASS — multi-month leftover: one retention_pass rolls M-2 and M-1
W17 PASS — rollup insert failure leaves unrolled detail; distinct rollup_failed
W10 PASS — device_detail days only current month; day=prev → bad_day
W11 PASS — device_months returns sorted month keys desc
W12 PASS — device_month_summary totals + 其他 + sort by total desc
W13 PASS — ACL read includes device_months and device_month_summary
W18 PASS — calendar-month: early month UCI=7d does not drive cutoff/estimate/confirm
W19 PASS — devices/overview list last_seen-in-range with zero samples
W22 PASS — pair_rows uses covering index idx_samples_ts_device_target
W14 PASS — device_06x cache-bust + 往月汇总 UI + settings current-month copy
W15 PASS — both packages PKG_VERSION 0.6.0
W20 PASS — editable views identical to versioned menu copies (no divergent forks)
W21 PASS — calendar clamp helper uses injected router today/month (F4)
lua: 63 passed, 0 failed
```

### monthly-rollup W* 判定

| 用例 | 结果 | 备注 |
|------|------|------|
| W1 | PASS | timeutil mid-month |
| W2 | PASS | last day / year roll |
| W3 | PASS | empty + v4→v5 |
| W4 | PASS | 105→101；其他=leftovers |
| W5 | PASS | tie-break target ASC |
| W6 | PASS | prior purged; current kept |
| W7 | PASS | idempotent re-run |
| W8 | PASS | sessions fallback |
| W9 | PASS | no current-month insert |
| W10 | PASS | days clamp + bad_day |
| W11 | PASS | months desc |
| W12 | PASS | summary sort + 其他 |
| W13 | PASS | ACL |
| W14 | PASS | device_06x + 往月 + settings |
| W15 | PASS | PKG_VERSION 0.6.0 |
| W16 | PASS | M-2+M-1 both rolled; no leftover past detail |
| W17 | PASS | inject insert fail → unrolled kept; rollup_failed |
| W18 | PASS | UCI≠cutoff; estimate calendar_month; no false confirm |
| W19 | PASS | last_seen-only device in devices/overview |
| W20 | PASS | device.js≡device_06x; overview≡overview_055 |
| W21 | PASS | clampDayToRouterMonth + router today/month |
| W22 | PASS | INDEXED BY idx_samples_ts_device_target |
| W23 | PASS | parse_month 13/00 → nil |

## 遗留问题
- F10 (api.lua size / pair_cache)、F13 (schema v4/v5 bundling)：**wontfix** this release（per order）

## 待决问题（blocked 时才填）
- 无

---
✅ PIPELINE_DONE: Round-1 fixes F1–F9/F11/F12 done; W1–W23 PASS; 63 lua tests green; F10/F13 wontfix
