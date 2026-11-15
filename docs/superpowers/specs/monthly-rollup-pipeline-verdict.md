# monthly-rollup — Pipeline verdict

**Date:** 2026-11-16  
**Version target:** 0.6.0

## Gates

| Stage | Result |
|-------|--------|
| Design / ADR / plan / testplan | READY (user: start, no questions) |
| Code (initial) | PIPELINE_DONE → REVIEW_FAIL (F1 Blocker) |
| FIX-R1 | PIPELINE_DONE; W1–W23 PASS |
| Review R2 | REVIEW_PASS; Blocker/Should-Fix open = 0 |
| Test | TEST_PASS (host white-box); B1–B5 **未做** |

## Host evidence

- Independent test: lua 63/0, js 9/0, blind W16–W19, mutations kill assertions
- Open nits only: F14–F16 (copy/naming/locals)

## Device gap (real-machine)

- `root@192.168.100.1`: ping OK, SSH `Permission denied` (BatchMode)
- `root@192.168.1.1`: unreachable
- `dist/` had no 0.6.0 `.ipk` at test time

**TEST_PASS ≠ on-router deliverable** until package + SSH deploy + B1–B5.

## Release

- **Built + published:** https://github.com/neohob/luci-app-netmonitor/releases/tag/v0.6.0  
  (`netmonitor_0.6.0-1_all.ipk`, `luci-app-netmonitor_0.6.0-1_all.ipk` / `.run`, SHA256SUMS)
- **Deploy smoke:** still **未做** (SSH BatchMode denied to `root@192.168.100.1`)

## Residual (needs human / key)

1. Router SSH key so `deploy-goop.sh` + B1–B5 can run  
2. Git commit of source to match `v0.6.0` → ORDER-NM-ROLLUP-COMMIT

## Pipeline status

Implementation + review + host test + package/release: **complete**.  
On-device acceptance: **blocked on SSH**.
