# Gate verdict provenance — WS44-01

**Date** 2026-08-22
**Ledger** `SEL-20260822-239D8900` (BUILD, Executed, Pending) — acts on `SEL-20260822-1BD26D3B` rec. 4
**Component** `WS44-01-VERDICT-PROVENANCE`
**Migration** `20260822115758_ws44_gate_verdict_provenance_check.sql`

---

## The gap

`judge_verdicts` holds **zero rows**. 119 loops carry `last_gate_verdict = 'TRUST'`.
**Not one** has a `verdict_id`.

Every individual row is accurate. The composite claim — *this work passed the judge*
— is unsupported. And it is not inert: **stage 7's exit test reads
`last_gate_verdict`**, so an unbacked verdict can advance work through the cycle.

## A second signal in the same data

| Verdict | Count |
|---|---|
| `TRUST` | **119** |
| `MARGINAL` | 0 |
| `LIABILITY` | 0 |

The enum offers all three. Only the pass value has ever been written. A gate that has
never once declined warrants inspection on its own, separately from the provenance
gap — so the distribution travels with the finding as evidence.

## What was built, and what was not

Shipped `ws44_gate_verdict_provenance_check(uuid)`, appended to
`ws10_conformance_daily` as the **fifteenth** check. It resolves the link in both
available directions — `loop_executions.verdict_id → judge_verdicts.id`, and
`judge_verdicts.loop_id → loop`.

**Not done, deliberately:** no verdict backfilled, no `judge_verdicts` row written,
no `last_gate_verdict` altered, `update_loop_from_prometheus` untouched. The detector
takes no side on how the gap closes.

## Why it is CONFORM on day one

A check that is red from birth and can never reach clean gets ignored, and an ignored
check occupies the space where a real one would go.

So the 119 existing verdicts are recorded as **accepted** and excluded from the
verdict. They are reported in every run — never hidden — but the pass/fail rests only
on loops created after `2026-08-22 12:00 UTC`. The check turns red the moment a **new**
loop asserts a verdict with no judge row behind it.

It can therefore reach a clean state by the platform behaving correctly from here,
rather than by anyone rewriting history. Retro-writing judge rows for the 119 would
fabricate judgements nobody made.

## Verified

```
WS44-01  CONFORM  INFO   method FULL   examined 119 / universe 119
0 of 0 post-watermark verdicts unbacked; 119 historical accepted;
judge_verdicts holds 0 rows
```

`ws10_conformance_daily` confirmed active, now carrying 15 checks.

The check passed the BP-004 scan-provenance gate on first insert — which required
declaring the **full** 119-row universe rather than only the post-watermark subset.

## Still open — Founder decision

Either:

- **wire it** — have `update_loop_from_prometheus` write `judge_verdicts` and set
  `verdict_id`; or
- **stop asserting it** — stop writing `last_gate_verdict`.

A verdict with no record behind it should not remain a third option.

## Rollback

```sql
-- restore the 14-check cron body (omit the ws44 line), then:
drop function public.ws44_gate_verdict_provenance_check(uuid);
-- optionally:
delete from m2m_conformance_audit where check_code = 'WS44-01';
```

Safe unconditionally: the detector only reads, and writes to `m2m_conformance_audit`.
Nothing depends on it.
