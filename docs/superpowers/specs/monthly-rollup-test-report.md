STATUS: ROUND_DONE

# monthly-rollup — Test pane report (ORDER-NM-ROLLUP-TEST)

**Role:** nm-test independent white-box re-run + black-box.  
**Date:** 2026-11-16.  
**Review ledger:** 0 open Blocker / Should-Fix (only Nits F14–F16).

## Coverage matrix A1–A8 × W/B

| AC | White-box (repo) | Blind (test pane) | Black-box | Verdict |
|----|------------------|-------------------|-----------|---------|
| A1 | W3,W4,W12 PASS | — | B2 未做 | W OK |
| A2 | W4,W5,W8 PASS | — | B2 未做 | W OK |
| A3 | W1,W6,W9 PASS | — | B2 未做 | W OK |
| A3b | W16,W17 PASS | BLIND-W16/W17 PASS | B2 未做 | W OK |
| A4 | W1,W10,W21 PASS | — | B1 未做 | W OK |
| A5 | W11–W14 PASS | — | B3,B5 未做 | W OK |
| A6 | W7 PASS | — | B2 未做 | W OK |
| A7 | W14,W15,W18 PASS | BLIND-W18 PASS | B4 未做 | W OK |
| A8 | W19 PASS | BLIND-W19 PASS | B1 未做 | W OK |

## A. White-box

### A.1 Blind first (before reading `tests/lua/test_rollup.lua`)

Independent assertions from acceptance + testplan only (`/tmp/nm_blind_w16_w19.lua`):

```
blind fixture now=2026-11-15 12:00 cur=2026-11 m1=2026-10 m2=2026-09
BLIND-W16 PASS — A3b multi-month: one retention_pass rolls M-2 and M-1
BLIND-W17 PASS — rollup insert failure keeps unrolled detail; rollup_failed
BLIND-W18 PASS — calendar retention: UCI 7d early month does not drive cutoff/estimate
BLIND-W19 PASS — devices/overview include last_seen-in-range with zero samples
blind: 4 passed, 0 failed
```

### A.2 Full suite re-run

```
$ lua tests/lua/run_all.lua
… (W1–W24 / S* / ASN* / SVC* / monthly W1–W23 as below) …
W16 PASS — multi-month leftover: one retention_pass rolls M-2 and M-1
W17 PASS — rollup insert failure leaves unrolled detail; distinct rollup_failed
W18 PASS — calendar-month: early month UCI=7d does not drive cutoff/estimate/confirm
W19 PASS — devices/overview list last_seen-in-range with zero samples
…
lua: 63 passed, 0 failed
EXIT:0
```

```
$ node tests/js/test_topo.js
PASS W17a portCenter x
…
W17 PASS — port center / edgePath dock ±1px + F14 keys
js: 9 passed, 0 failed
JS_EXIT:0
```

Raw full lua output (verbatim):

```
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
EXIT:0
```

### A.3 Reconciliation — 我验了 / 仓库验了 / 差异 / 谁对

| 用例 | 我验了 (blind) | 仓库验了 | 差异 | 谁对 |
|------|----------------|----------|------|------|
| W16 / A3b | PASS: M-2+M-1 → monthly; detail purged; current intact | PASS (`test_rollup` W16) | Blind 用 samples only；仓库另插 sessions。断言同义 | 一致，双方对 |
| W17 / F7 | PASS: inject INSERT fail → `rollup_failed`; M-2/M-1 detail 保留 | PASS (`test_rollup` W17) | 仓库只 fail 第 1 次 INSERT；blind fail 全部 INSERT。结果同：detail 不丢 | 一致，双方对 |
| W18 / A7 | PASS: cutoff=month_start; 7d/30d 拒; estimate calendar_month | PASS (`test_monthly_api` W18) | 仓库另断言 `set_config` 无 `need_confirm`；blind 覆盖 resolve_range | 一致，仓库略宽，双方对 |
| W19 / A8 | PASS: devices+overview 含 last_seen-only | PASS (`test_monthly_api` W19) | 同构 | 一致，双方对 |

无假绿信号：盲测与仓库在 A3b/F7/A7/A8 上同向 PASS。

### A.4 Mutation (once)

```
===== MUTATION TOP_N=50 FILTER=W4 =====
W4 FAIL — 105 targets → Top100 + __other__ with exact remainder
    ./tests/lua/test_rollup.lua:74: exactly 100 + other: expected 101, got 51
FILTER="W4" ran=1
lua: 0 passed, 1 failed
MUT1_EXIT:1
===== MUTATION month_start+1d FILTER=W1 =====
W1 FAIL — month_key / month_start / next_month_start mid-month
    ./tests/lua/test_timeutil.lua:9: month_start local 1st 00:00: expected 2026-11-01 00:00:00, got 2026-11-02 00:00:00
FILTER="W1" ran=1
lua: 0 passed, 1 failed
MUT2_W1_EXIT:1
===== MUTATION month_start+1d FILTER=W6 =====
W6 FAIL — after rollup prior-month samples/sessions gone; current untouched
    ./tests/lua/test_rollup.lua:135: current sample kept: expected 1, got 0
FILTER="W6" ran=1
lua: 0 passed, 1 failed
MUT2_W6_EXIT:1
===== FILTER=_NOPE =====
FILTER="_NOPE" ran=0
lua: 0 passed, 0 failed (no matching tests)
NOPE_EXIT:2
```

| Mutation | Expect | Result |
|----------|--------|--------|
| `/tmp` copy `TOP_N=50` → W4 | FAIL | FAIL (101→51) ✓ |
| `month_start` day+1 → W1 / W6 | FAIL | both FAIL ✓ |
| filter `_NOPE` | 0 tests, not silent pass | ran=0, exit 2 ✓ |

## B. Black-box (B1–B5)

| ID | Result | Evidence / 根因 |
|----|--------|-----------------|
| B1 | **未做** | 无法登录设备 |
| B2 | **未做** | 同上；且 `dist/` 无 0.6.0 `.ipk`（仅 ≤0.5.4） |
| B3 | **未做** | 同上 |
| B4 | **未做** | 同上 |
| B5 | **未做** | 同上 |

Probe (raw):

```
=== probe root@192.168.100.1 ===
ping: 1/1 OK (~2.9ms)
ssh BatchMode: Permission denied (publickey,password).  EXIT:255
(id_rsa offered; server rejected; agent empty; no password in BatchMode)

=== probe root@192.168.1.1 ===
ping: 100% loss
ssh: Operation timed out  EXIT:255

PKG_VERSION in Makefiles: 0.6.0
dist/*.ipk: no *0.6.0* artifacts
```

未发明 B* PASS。

## Notes

- Did **not** implement product fixes; did **not** trust code-pane self-proof alone (blind + mutation).
- Open review nits F14–F16 out of scope for this gate.

TEST_PASS: independent white-box (blind W16–W19 + lua 63/0 + js 9/0 + mutations detect FAIL) green for A1–A8; B1–B5 未做 (SSH auth denied / timeout; no 0.6.0 ipk to deploy)
