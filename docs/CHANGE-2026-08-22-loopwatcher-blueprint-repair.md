# LOOP-WATCHER blueprint repair — both faults, one edit

**Date** 2026-08-22
**Ledger** `SEL-20260822-86BB870A` (REMEDIATION, Executed, Pending)
**Component** `MAKE-LOOPWATCHER-5403849`
**Target** Make scenario **5403849** (M2M-LOOP-WATCHER), 15-minute interval

---

## Why both at once

Fixing `max_tokens` alone would have restored brief generation **and restarted the
fabricated verdicts**. The break has been suppressing the fabrication since 14 August.
Repairing it in isolation would have reintroduced the worse fault.

## Fault 1 — max_tokens

All eight `anthropic-claude:simpleTextPrompt` modules passed `max_tokens` as a
**quoted string**. The API now rejects it:

```
[400] max_tokens: Input should be a valid integer
```

Changed to unquoted integers: `1000, 800, 800, 600, 1000, 800, 800, 900`.

## Fault 2 — the gate stamped literals

Modules 30/40/50/60/70 wrote `gate_checkpoints` rows with hard-coded constants —
`gate_verdict: "TRUST"`, `check_01_trust: "PASS"`, `check_03_liability: "PASS"`,
`route_decision: "APPROVED"`, `ocean_total_score: "12"` — none computed from the
Claude output immediately preceding them.

**Those five modules were removed, not repaired.** Writing a verdict requires an
evaluator that does not exist, and inventing a scoring rubric is Founder doctrine,
not an agent decision.

The escalation path is why this mattered: `fn_gate_checkpoint_router` reads that
literal `TRUST` and sets `status = 'APPROVED'` plus an attempt at
`fl_ii_authenticated = true`.

## Verified live

Set the stuck 22 Aug CEO loop (`834bbecf`) back to `INITIATED` so the 12:41:42
scheduled run reprocessed it with its real `trigger_payload`.

| Check | Result |
|---|---|
| Brief generated | **`m2m_daily_intel` 690 → 691**, 3,762 chars at 12:41:58 — first since 14 Aug |
| Fabricated verdict | **none** — `gate_checkpoints` still 120, newest still 2026-08-14 |
| Authentication | `fl_ii_authenticated` **false**, `machine_verified` null, `last_gate_verdict` null |
| Loop spinning | `INITIATED` loops after run: **0** |
| No-op suppression | `loop_watcher_poll_tally` = 4 empty polls today |
| Scenario state | `isinvalid false`, `isActive true`, `dlqCount 0`, 22 modules |

Eight days of missed briefing recovered for today.

## Two corrections to what I told you

**1. On auto-authentication.** I said the literal auto-authenticates loops in your
name. More precisely: the router *attempts* it, and a guard
(`fn_flii_machine_redirect`) exists to redirect it to `machine_verified`. But
`machine_verified` is **0 across the entire table** — the guard has never fired —
while **158 loops carry `fl_ii_authenticated = true`**, the most recent at
`2026-08-14T11:11:59`, exactly the last successful watcher run, attributed to
"Dr. Kevin A. Smith" on 130 of them. So the historical false authentications are
real and attributable to this path; the guard is installed but **unproven**. The fix
removes the path rather than trusting the guard.

**2. On a bug I invented.** I added eight `makeAnApiCall` modules to set
`ARCHITECT_REVIEW`, believing removal of the gate write would strand loops at
`INITIATED` and re-claim them every 15 minutes. Wrong — the existing trigger
`process_loop_watcher_signal` already sets `RUNNING` on any CLAIM with a `loop_id`.
The modules were redundant, did not take effect, and were removed in a third edit.

## Still open

- **A second FL/II bypass.** `process_loop_watcher_signal`'s `CLOSE_APPROVED` branch
  sets `fl_ii_authenticated = true` directly. Dormant — the blueprint emits only
  `CLAIM` — but one signal away from firing.
- **Lifecycle change.** Loops now end at `RUNNING`, not `APPROVED`, and
  `final_output` stays null; the brief lives in `m2m_daily_intel`. Honest, since
  nothing judged or authenticated them, but different from pre-14-August.
- **A real gate**, if wanted: add an evaluator module scoring against the Seven
  Must-Haves or the five OCEAN dimensions already in `judge_verdicts`, and map its
  output to `gate_verdict` instead of a literal.

## Rollback

Make retains prior blueprint versions. Restoring the 2026-08-04 version reinstates
**both** the `max_tokens` defect and the hard-coded verdict writes. To keep briefs
without the fabrication, keep the current blueprint.
