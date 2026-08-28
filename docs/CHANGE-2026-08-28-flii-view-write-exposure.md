# CHANGE · 2026-08-28 · Anon DML on an FL/II provenance view; WS31-01 scope

**Migration:** `20260828112312` · **Detector:** `WS50-01` · **Status:** APPLIED, ledger `Pending`
**Closes:** WS24-01 (BLOCKING) and WS31-01 (BLOCKING since 2026-08-19)

---

## Correction first — a claim of mine that the Founder has already authenticated

I reported, repeatedly, that **"WS24-01 reports 1 anon-reachable `SECURITY DEFINER` function
where three independent counts found 9; its scan scope is too narrow."** That is **wrong**.

WS24-01 is not about functions. Its universe is *"public views that are owner-executing"* — 7
views, 1 anon-reachable. The check covering anon-executable `SECURITY DEFINER` **functions** is
**WS24-03**, which carries its own allowlist. I conflated them. **WS24-01's scan scope was never
defective**, and its "1 anon-reachable" was a true finding about a view.

That error is baked into `SEL-20260828-A2018879`, which is already **Approved**; into WS49-01's
`coverage_note`, stamped into every row it emitted; into PR #2; and into the WS49 change record.
The detector's evidence field is corrected in this migration. The approved ledger row cannot be
amended — this record is the correction of record.

**Second consequence: WS49 did not close WS24-03, as it claimed.** WS24-03's allowlist is
`roi_result_by_token, submit_whistleblower_report, whistleblower_report_status,
assert_founder_session`. After WS49 the anon-reachable set is those three plus
`fn_canonical_last_write`. WS49 took it from five unexpected to **one** — it did not close it.
Verified after this migration: **WS24-03 = DEVIATION / BLOCKING, one entry,
`fn_canonical_last_write`** — the provisional acceptance I created.

## What WS24-01 was actually pointing at, and it is severe

`public.v_flii_provenance_review`:

```sql
SELECT id, fl_ii_authenticated_by AS claimed_actor,
       fl_ii_authenticated_at AS claimed_at, ...
FROM loop_executions
WHERE fl_ii_authenticated IS TRUE AND machine_verified IS NULL
```

- **owner-executing** — `security_invoker` not set
- **auto-updatable** — `is_updatable = YES`, `is_insertable_into = YES`
- granted **`arwdDxtm`** — full DML — to **both `anon` and `authenticated`**

Because an owner-executing view runs base-table permission *and RLS* checks as the **view owner**,
the single `service_role`-only RLS policy on `loop_executions` — the control containing anon's
direct table grants — **did not apply to writes routed through this view.**

So an anon key holder could `UPDATE … SET claimed_actor = …`, rewriting **who is recorded as
having authenticated a sovereign task**, or `DELETE` the provenance rows under review. That is the
WS48 defect class — false authorship of an authentication — reachable **anonymously** rather than
by `service_role`.

**Not demonstrated by execution.** Writing through the view to prove it would have forged exactly
the record this protects. Established statically from `reloptions`, `information_schema.views`, and
`relacl`.

The Founder decision of 2026-08-14 accepted **authenticated read** on these views. It said nothing
about write, and DML on FL/II provenance is not within it. `SELECT` preserved for `authenticated`;
everything else revoked from both roles.

## WS31-01 was reporting 8 false positives

Its universe matched any function whose definition **mentioned** `fl_ii_authenticated`. Of the 9 it
flagged, eight only read or name the column:

| Function | What it actually does |
|---|---|
| `trgfn_ws7_outcome_required_loop` / `_ins` | `case when fl_ii_authenticated then 1 else 0 end::smallint` — a metric |
| `ws7_platform_integrity_sentinel` | reads it in a `WHERE` predicate |
| `ws41_cycle_integrity_check` | names it inside detector SQL strings |
| `m2m_cycle_advance`, `m2m_cycle_exit_test`, `process_loop_watcher_signal`, `ws46_cycle_applier_integrity_check` | reference only |

**Exactly one function assigns the columns:** `fn_fl_ii_close_loop` — an **AFTER** trigger on
`loop_executions` that *reacts* to a `false → true` transition (stamps `fl_ii_authenticated_at`,
sets `status = 'CLOSED'`, writes `loop_audit_trail`). It does not cause the transition, and
`fn_flii_machine_redirect` is a **BEFORE** trigger on the same table — `trg_aa_flii_redirect`, named
to sort first — which redirects machine writes to `machine_verified` before any AFTER trigger sees
them.

So the honest answer is **zero unguarded writers**, reached by correcting the detector from
"mentions the column" to "assigns the column, and is not already covered by the redirect."

**This is a scope correction, not a weakening.** A function that assigns the columns while ungated
and unredirected still fails, at `BLOCKING`. WS31-01 had sat at BLOCKING since 2026-08-19 on eight
false positives — and a check that reports a violation forever is one people stop reading.

## Evidence

| Check | Before | After |
|---|---|---|
| **WS24-01** | `DEVIATION / BLOCKING` — 1 anon-reachable | **`CONFORM`** — 0 anon-reachable, 4 authenticated-reachable, 7 total |
| **WS31-01** | `DEVIATION / BLOCKING` — "9 unguarded writers" | **`CONFORM`** — 0 unguarded; 2 assign the columns; 14 merely mention them |
| **WS50-01** | *(new)* | **`CONFORM`** — 7 owner-executing views, 0 writable by anon, 0 by authenticated |
| **WS49-01** | `CONFORM` | `CONFORM`, `coverage_note` corrected |
| **WS24-03** | `DEVIATION / BLOCKING` | **still `DEVIATION / BLOCKING`** — one entry, `fn_canonical_last_write` |

Final ACL: `postgres=arwdDxtm | service_role=arwdDxtm | authenticated=r` — anon holds nothing.

## Open, not authorized

- **`fn_canonical_last_write`** — the last WS24-03 entry, and my own provisional acceptance.
  `revoke execute on function public.fn_canonical_last_write() from anon;` plus dropping it from
  WS49-01's allowlist closes WS24-03. Held because its consumer is unidentified and breaking one
  was judged the worse risk. **Founder call.**
- **WS24-02** — 4 of 211 functions carry a mutable `search_path` (MEDIUM).
- **WS24-04** — 63 of 185 RLS-enabled tables lack a policy, against a baseline of 57 (MEDIUM). The
  count has drifted *above* its own baseline.
- **WS24-05** — 4 of 11 `policy_applied` contracts lack backfill (HIGH):
  `human_required_queue`, `approval_queue`, `m2m_wargames`, `muon_drive_folder_allowlist`. A live
  policy over an unpopulated tenant column silently matches nothing.

## Rollback

```sql
GRANT ALL ON public.v_flii_provenance_review TO anon, authenticated;
DROP FUNCTION public.ws50_view_write_exposure_check(uuid);
-- restore prior ws31_flii_guard_bypass_check (ilike-based universe) and prior
-- ws49_anon_definer_surface_check, both preserved in migration 20260828103722
-- and in this repo's history; then re-run cron.schedule without the WS50 line.
```
DCL and function bodies only — no schema or data change in either direction.
