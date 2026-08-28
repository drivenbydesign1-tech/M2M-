# CHANGE · 2026-08-28 · Close anon EXECUTE on the SECURITY DEFINER surface

**Migrations:** `20260828103722` (WS49) · `20260828103841` (WS49-01a)
**Detector:** `WS49-01`
**Status:** **APPLIED**. Ledger rows `Pending`.
**Closes:** WS24-03, open at BLOCKING since 2026-08-19.

---

## Corrections to my own earlier report, first

I told the Founder that **four** anon-reachable functions write `m2m_conformance_audit`
as owner. That was wrong twice, and both errors are the same error:

**1 · `fn_canonical_last_write` cannot write anything.** It is `STABLE`, and its entire
body is a `greatest(max(...), max(...), max(...))` over three tables — a liveness
heartbeat that *reads* the audit table. My detection was `prosrc ILIKE
'%m2m_conformance_audit%'`, which cannot tell a reader from a writer.

**2 · `fn_flii_machine_redirect` was never reachable.** It is a trigger function
(`prorettype = trigger`), bound to `trg_aa_flii_redirect` on `loop_executions` and
`judge_verdicts`. PostgREST does not expose trigger-returning functions over `/rpc`, and
trigger firing does not consult `EXECUTE` grants at all.

That is the third and fourth instance in two days of one underlying mistake: asserting a
function's behaviour from a substring in its source instead of testing the behaviour. The
first was `ws31_flii_guard_bypass_check` scoring itself gated; the second was WS48-01
counting itself. **WS49-01 tests `provolatile` and `prorettype` instead.**

**The true injection set was three, not four:** `ws31`, `ws32`, `ws33` — all `VOLATILE`,
all `INSERT`ing into `m2m_conformance_audit` as owner, all anon-executable.

## The root cause was not a grant anyone made

Eight of the nine carried `=X/postgres` in `proacl` — **the `PUBLIC` grant**, which Supabase
resolves to `anon` and `authenticated`. Nobody granted `anon` anything. The grant was
inherited at `CREATE FUNCTION` time, is invisible in the function source, and shows up only
in `proacl`. Only `assert_founder_session` carried an explicit `anon` grant.

So the fix is `REVOKE … FROM PUBLIC`, then re-grant deliberately — which also means the
remaining grants are now intentional rather than accidental.

## Dispositions

| Function | Before | After | Why |
|---|---|---|---|
| `ws31_flii_guard_bypass_check` | PUBLIC | `service_role` | **Injection vector.** VOLATILE, writes findings as owner |
| `ws32_ledger_immutability_check` | PUBLIC | `service_role` | same |
| `ws33_flii_single_writer_check` | PUBLIC | `service_role` | same |
| `fn_flii_machine_redirect` | PUBLIC | `service_role` | Trigger fn; never RPC-reachable. Hygiene only |
| `assert_founder_session` | explicit anon | `authenticated`, `service_role` | Only ever raises; SECDEF callers run as owner |
| `fn_canonical_last_write` | PUBLIC | `anon`, `authenticated`, `service_role` | STABLE heartbeat. Access preserved, grant now deliberate |
| `roi_result_by_token` | PUBLIC | `anon`, `authenticated`, `service_role` | **Accepted** — token-gated result read |
| `whistleblower_report_status` | PUBLIC | `anon`, `authenticated`, `service_role` | **Accepted** — reporter must check status |
| `submit_whistleblower_report` | PUBLIC | `anon`, `authenticated`, `service_role` | **Accepted** — reporter must be able to file |

Removing `anon` from the last two would break the confidential reporting channel. The
acceptance is **encoded in WS49-01's allowlist and printed on every run**, so it stays
visible as evidence rather than disappearing from the report.

## WS49-01a — my inconsistency, caught by my own detector

WS49 deliberately kept `anon` on `fn_canonical_last_write` (STABLE, one timestamp, consumer
unidentified, breaking it judged the worse risk). Then I shipped WS49-01 with an allowlist
that omitted it — so on its **first run** the check flagged a grant I had just chosen to
keep: `DEVIATION / HIGH` on my own decision.

Fixed by encoding the acceptance rather than loosening the rule. The fourth entry is marked
**provisional**, with its weakness printed every run: anon reachability was *inherited, not
designed*, and no consumer has been identified. Severity is also split — an unexpected
anon-reachable **VOLATILE** function is `BLOCKING`; an unexpected read-only one is `HIGH` —
so the check cannot go quiet on the part that matters.

To lock the heartbeat down instead, one line reverses it:
```sql
revoke execute on function public.fn_canonical_last_write() from anon;
```
and drop it from `c_accepted`. That is a Founder call, not mine, on a surface whose consumer
I could not establish.

## Evidence

**WS49-01 — `CONFORM` / `INFO`**
```
4 SECURITY DEFINER function(s) anon-EXECUTE-able;
4 accepted by design (fn_canonical_last_write, roi_result_by_token,
                      submit_whistleblower_report, whistleblower_report_status);
0 unexpected; 0 of the unexpected are VOLATILE and so able to write
```

**Anon-reachable SECURITY DEFINER functions: 9 → 4**, and all four are on the declared
allowlist.

**The accepted surfaces still work** — read-only probes:
```
fn_canonical_last_write()                        -> 2026-08-28 10:38:47.096471+00
whistleblower_report_status('WB-DOES-NOT-EXIST') -> {"found": false}
anon EXECUTE on submit_whistleblower_report      -> true
```

I did **not** call `submit_whistleblower_report`. Filing a fake report would pollute a
confidential channel with test data; reachability is proven by the grant plus the status
path. Same reasoning as not calling `eco_authenticate` to prove the WS48 bypass.

**The daily battery is unaffected.** `cron.job.ws10_conformance_daily` runs as `postgres`,
which owns these functions. Verified by running `ws31_flii_guard_bypass_check` directly
after the revoke: it executed and emitted its row. Its `DEVIATION / BLOCKING` verdict
("9 unguarded writers") is its **pre-existing** state, held from PR #1 and untouched here.

## Held, not done

- **WS24-01's scan scope.** It reports 1 anon-reachable `SECURITY DEFINER` function where
  three independent counts found 9. WS49-01 now provides the true coverage. WS24-01 is
  **reported, not rewritten** — rewriting another detector on the way past is how scope
  creep enters a security change.
- **WS31-01's 9 unguarded writers on `loop_executions`.** Pre-existing, held from PR #1.
- No G6, no migration 369, no FL/II cutover, no root-key activation, no authority transfer,
  no authentication, no merge.

## Rollback

DCL and function bodies only — no schema or data change in either direction.

```sql
GRANT EXECUTE ON FUNCTION public.ws31_flii_guard_bypass_check(uuid)   TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.ws32_ledger_immutability_check(uuid) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.ws33_flii_single_writer_check(uuid)  TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_flii_machine_redirect()           TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.fn_canonical_last_write()            TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.roi_result_by_token(text)            TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.whistleblower_report_status(text)    TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.submit_whistleblower_report(text,text,text,text,text,text,date) TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_founder_session()             TO anon;
DROP FUNCTION public.ws49_anon_definer_surface_check(uuid);
-- then re-run cron.schedule('ws10_conformance_daily','0 13 * * *', ...) without the WS49 line
```

## Authentication

Both ledger rows are `Pending`. From a Founder session:

```sql
select public.muon_founder_authenticate(
  array(select id from public.sovereign_execution_log
        where human_review_status = 'Pending'),
  'AUTHENTICATED', 'Reviewed: WS49 anon SECDEF closure, evidence verified.');
```
