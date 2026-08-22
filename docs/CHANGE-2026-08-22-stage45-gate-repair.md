# Stage 4/5 gate repair and reachability detector

**Date** 2026-08-22
**Project** Supabase `jnmywpfdykuybrxkdcmc` (canonical)
**Ledger** `SEL-20260822-EA79229E` (REMEDIATION, Executed) · `SEL-20260822-A124D543` (FINDING, Held)
**Review status** Both Pending. Neither has been authenticated.

---

## Lead finding

The sequence called for populating `loop_executions.deliverable_id` from the
deliverable catalogue. **Doing so would have broken the stage 4 and stage 5 gates
on the first row written.**

`m2m_cycle_exit_test` compared `m2m_claim_register.doc_id` (text) with
`loop_executions.deliverable_id` (uuid):

```
FROM m2m_claim_register c WHERE c.doc_id = l.deliverable_id
```

PostgreSQL has no `text = uuid` operator. The comparison raises:

```
ERROR: 42883: operator does not exist: text = uuid
```

It had never fired because `deliverable_id` is NULL on all 203 rows, so the
`BLOCKED_NO_DELIVERABLE_LINK` branch short-circuited ahead of it. A gate that
cannot execute is indistinguishable from a gate that passes.

Confirmed by probe inside an aborted transaction:

```
PROBE>>> STAGE4 GATE RAISED 42883 :: operator does not exist: text = uuid <<<ALL WRITES ROLLED BACK
```

## Why nothing was populated

Three deliverable identifier namespaces exist and none of them meet:

| Surface | Rows | Key shape |
|---|---|---|
| `deliverables` (FK target of `loop_executions.deliverable_id`) | **0** | uuid |
| `m2m_active_deliverables` | 24 | `DEL-001` … `DEL-026` |
| `m2m_claim_register.doc_id` | 4 distinct | `R2T-BRIEF-V1`, `AXIOM-BRIEF-V2` … |

The FK targets an empty table, so no legal non-null value exists to write. The
only join key populated on both sides — Make scenario id — has **zero overlap**
(loops hold one value, `LOOP-WATCHER-5403849`; deliverables hold five numeric ids).

`m2m_loop_deliverable_match_preview()` over the full 203-row universe:

```
disposition  rule_applied    loop_count
UNMATCHED    no_rule_fired          203
```

**0 MATCHED, 0 AMBIGUOUS, 203 UNMATCHED.** Populating any of them would have been
inventing the relationship, so none was populated.

## What changed

1. `loop_executions.doc_ref` — text, nullable, no default, partial index. Additive
   and inert. NULL on all 203 rows.
2. `m2m_cycle_exit_test` — stage 4/5 branch repointed to `doc_ref`, making the
   comparison type-correct. **Behaviour today is unchanged**: `doc_ref` is NULL
   everywhere, so every loop still returns `BLOCKED_NO_DELIVERABLE_LINK`.
3. `m2m_loop_deliverable_match_preview()` — read-only, writes nothing.
4. `ws43_cycle_gate_reachability_check(uuid)` — appended to `ws10_conformance_daily`
   as the 14th check.

**Not changed:** `deliverable_id` and its FK are untouched; no row of
`loop_executions` was written; `deliverables` was not seeded.

## Verification

Probe inside an aborted transaction, against live data:

| doc_ref | stage | verdict | detail |
|---|---|---|---|
| NULL | 4 | `BLOCKED_NO_DELIVERABLE_LINK` | unchanged from before |
| `AXIOM-EXECSUM-V1` | 4 | **MET** | 1 material claim, 0 unresolved |
| `R2T-BRIEF-V2` | 4 | **NOT_MET** | 3 claims, 1 unresolved (`CLM-20260821-0007` uncited) |
| `R2T-BRIEF-V1` | 5 | **NOT_MET** | 2 claims, 1 unresolved (`EVD-IMDA-MGF-AGENTIC-V10` SUPERSEDED) |

All writes rolled back and verified: `deliverables` 0 rows, `doc_ref` non-null 0
rows, stage distribution restored to 9:190 / 7:1 / null:12.

`WS43-01` → **CONFORM**, method FULL, 203 of 203 examined, 0 raised, link type
text vs claim type text.

Counterfactual: the same static test against `deliverable_id` reports uuid vs
text, `type_compatible: false`. WS43 would have caught the defect the day it shipped.

## Detector self-correction

The first WS43 version declared `method: FULL` while examining 191 of 203 rows.
The platform's own BP-004 scan-provenance gate refused the insert:

```
BP-004 scan-provenance gate [Rule 1]: verdict CONFORM is not permitted
below full coverage (examined 191 of 203). Use UNVERIFIABLE.
```

The gate was right. The scan was widened rather than the claim narrowed. Refusal
recorded in `muon_refusal_ledger`.

## Rollback path

```sql
-- 1. restore the 13-check cron body (omit the ws43 line)
select cron.alter_job((select jobid from cron.job where jobname='ws10_conformance_daily'),
                      command := '<13-check body>');
-- 2-3. drop the new functions
drop function public.ws43_cycle_gate_reachability_check(uuid);
drop function public.m2m_loop_deliverable_match_preview();
-- 4. restore m2m_cycle_exit_test to its prior definition (stage 4/5 branch reads
--    c.doc_id = l.deliverable_id). NOTE: this reinstates the 42883 defect and
--    should only be done together with steps 5-6.
-- 5-6. remove the column
drop index public.idx_loop_executions_doc_ref;
alter table public.loop_executions drop column doc_ref;
```

Steps 5–6 are safe unconditionally while `doc_ref` is NULL on every row. If any
row has been bound by then, capture `(id, doc_ref)` first — that binding is a
Founder decision and dropping the column would destroy it.

## Open decision — Founder

Binding a loop to a document determines which claims the stage 4/5 gate tests, so
it is authentication-grade and not inferable by an agent. Three options:

- **(a) recommended** — bind loops to claim-register `doc_id`s via
  `loop_executions.doc_ref`, restricted to loops that genuinely produced a
  registered document. The repaired gate supports this today.
- **(b) not recommended** — seed `public.deliverables` and use the existing uuid
  FK. This creates a fourth deliverable surface.
- **(c)** — accept that recurring cadence loops have no deliverable, and scope
  binding to one-off loops only.

## Authentication

`muon_founder_authenticate` was attempted from this session and refused:

```
FL/II REFUSED: no user session. Caller is service_role, MCP, an agent
connection, or the SQL editor. Founder authentication requires the
Founder session credential.
```

That is correct behaviour. Both SEL records remain Pending for Kevin A. Smith.
