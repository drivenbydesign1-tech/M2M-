# INTAKE-001 — D4 retest + admin-read probe

**Validator:** CC (independent). **Date:** 2026-08-29 ~14:30 UTC.
**Method:** rollback-safe transaction against live production; every probe proves
**row visibility** under an impersonated role, never a predicate result.

## Verdicts

**D4 — REMEDIATED on `m2m_intake_dead_letter`.** Both halves verified by doing.

**D9 — NEW, BLOCKING.** The remediation moved the exposure rather than closing it.
Deleting a dead-letter row copies its full PII payload into a ledger that **any
authenticated user can read**.

---

## Probe results (single transaction, rolled back)

A synthetic dead-letter row was seeded carrying the marker `SYNTHETIC-PII-CANARY`,
then read as each role, then deleted so the guard would archive it, then re-read.

| # | Probe | Observed |
|---|---|---|
| 0 | setup | real admin uid `b4e6ede2-86bc-43b8-9f70-e62beab14caa` (from `m2m_admins`, 3 rows) |
| 1 | `anon` → dead_letter | **DENIED: permission denied for table m2m_intake_dead_letter** |
| 2 | `authenticated` NON-admin → dead_letter | **rows=0**, `is_m2m_admin=false` |
| 3 | `authenticated` **ADMIN** → dead_letter | **VISIBLE rows=1**, `is_m2m_admin=true` |
| 4 | guard on delete | ledger rows carrying the canary = **1** |
| 5 | `authenticated` NON-admin → ledger, canary | **VISIBLE rows=1** |
| 6 | `authenticated` NON-admin → entire ledger | **VISIBLE rows=6** |

Rollback verified afterwards: `m2m_intake_dead_letter` 0 rows, canary 0 rows,
ledger back to its prior 5 rows. Nothing persisted.

Probe 3 is the specific thing that was asked for. `is_m2m_admin()` returning true is
not evidence; **row 1 actually came back** under the admin identity, so the policy
genuinely exposes data rather than merely evaluating true. Probe 2 is its control —
a non-admin gets `rows=0` (silently filtered by RLS) rather than an error, which is
the correct RLS shape.

## D4 — what is now in place, and it works

- `tg_guard_dead_letter_delete` — `AFTER DELETE … REFERENCING OLD TABLE …
  FOR EACH STATEMENT EXECUTE f_guard_intake_delete()`, the same function guarding
  `m2m_pivot_intake`. Probe 4 confirms it archives.
- `m2m_intake_dead_letter_admin_read` — `SELECT`, roles `{authenticated}`,
  `USING is_m2m_admin()`. Probes 2 and 3 confirm it discriminates correctly.
- `anon` holds no grant at all on the table (probe 1).

That closes D4 as filed.

## D9 — the ledger is the hole now

```
policy intake_del_ledger_auth_read
  on m2m_intake_deletion_ledger
  SELECT | roles={authenticated} | USING = true          ← unconditional
grant: authenticated:SELECT
```

`f_guard_intake_delete()` archives `to_jsonb(d)` — the **entire deleted row**. For a
dead-letter row that includes `raw_intake`, the full captured payload. So:

> A record protected as admin-only in `m2m_intake_dead_letter` becomes readable by
> **every authenticated user** the moment it is deleted.

Deleting is the operation that *downgrades* its protection. Probe 5 proves it with the
canary; probe 6 shows the whole ledger is open, not just one row.

This is not limited to the dead-letter table. The same guard function is attached to
`m2m_pivot_intake`, `pivot_leads`, `roi_assessment` and `m2m_switch_assessments`, and
`row_payload` for those carries names, emails, phones and free-text messages. Three of
the five ledger rows today have `raw_intake` embedded (1,375–1,441 bytes each).

**Who `authenticated` is:** anyone holding a valid Supabase JWT — i.e. anyone who
signs in through the portal, not an internal-only role.

### Current blast radius: nil, and that is luck rather than design

All 5 ledger rows are synthetic QA (`@m2msovereign.test`) — 4 mine, 1 Atlas's
`mgmt-api` probe. **No real customer PII sits in the ledger right now.** The exposure
becomes real with the first deletion of a genuine lead, which is exactly what launch
week will produce.

### The fix

Match the ledger policy to the table it archives:

```sql
alter policy intake_del_ledger_auth_read
  on public.m2m_intake_deletion_ledger
  using (public.is_m2m_admin());
```

I did **not** apply this. It is a live security control on a system Kev is accountable
for, the current exposure contains no real data, and per the brief a discovered defect
is preserved and reported rather than silently corrected. Rollback if applied and
regretted: `using (true)`.

Worth deciding alongside it — whether the ledger needs the full `row_payload` at all.
Attribution (who deleted what, when) needs the row's identity and metadata; it does not
strictly need every PII field. A narrower payload would make the ledger safe to read
more widely, which is presumably why it was granted broadly in the first place.

## Standing items unchanged

D1 (frontend success gate on PR #27) remains the other blocking item and is still
unverified from here. D2, D3, D5, D6, D7, D8 stand as filed.

**Revised disposition: INTAKE-001 remains CONDITIONAL, now on two blockers — D1 and D9.**
