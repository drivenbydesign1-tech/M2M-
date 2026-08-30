# Module progress + completion contract — independent adversarial validation

> **REMEDIATION STATUS, 2026-08-30 — V1 and V2 are both fixed and verified.**
> The findings below are preserved as written at the time of testing; this banner
> records what has since changed and how it was proven.
>
> **V1 — FIXED.** Migration `20260829235709 restore_anon_execute_on_pre_request_hook`
> grants EXECUTE on `public.set_workspace_tier_from_jwt()` to `anon`. Re-probed over
> live HTTP: the hook message is gone from all five endpoints, each request now
> reaches its real authorization layer, and valid anon inserts to `m2m_web_traffic`
> and `roi_assessment` return **HTTP 201**. Rollback: `REVOKE EXECUTE … FROM anon`,
> which re-breaks all anonymous REST.
>
> Fixing V1 exposed two defects of mine that the 401 had masked, both corrected in
> commit `b3fba8b`: `ck_event_kind` rejects `form_submit` and `form_error` (now
> `form_submit_ok` / `form_submit_error`), and `roi_assessment_source_check` rejects
> `pivot-os-landing` (now `self_serve`). Tests now pin the allowed `event_kind` set.
>
> **V2 — FIXED.** Migration `20260830000521 ck_completed_requires_evidence_on_module_progress`
> adds `CHECK (coalesce(completed,false) = false OR completion_evidence_ref IS NOT NULL)`.
> A constraint rather than a trigger edit, because it holds regardless of which path
> writes the row. Verified by re-running the attack:
>
> | Re-test | Result |
> |---|---|
> | admin flips `status='completed'`, no evidence | **REFUSED** `23514`, residual `completed=false status=in_progress evidence=NULL` |
> | `service_role` same flip | **REFUSED** `23514`, residual clean |
> | `fn_complete_module()` valid path | **works** — `completed=true`, evidence linked |
> | status flip on a row that already carries evidence | **allowed**, evidence intact |
>
> Both refusals leave nothing partial, and neither the valid completion path nor a
> legitimate admin re-flip was broken. Rollback: `ALTER TABLE public.m2m_module_progress
> DROP CONSTRAINT ck_completed_requires_evidence;`
>
> **Still open:** V3–V6 (NULL lane, learner-writable `email` into facilitator views,
> lane casing, invented module ids), V7 (completion structurally unreachable on a
> learner's behalf), V8 (revocation does not cascade). Concurrency and authenticated
> transport remain **NOT EXECUTED**.
>
> One residual worth a decision: with the constraint in place, the trigger's
> `completed := TRUE` assignment is now dead weight on the invalid path — it turns
> what could be a clear refusal into a raw `23514`. Removing that assignment from
> `update_m2m_module_progress_updated_at()` is a separate, optional cleanup.

**Validator:** CC (this session). **Date:** 2026-08-29, 23:44–23:55 UTC.
**Target:** Supabase `jnmywpfdykuybrxkdcmc` — `fn_complete_module`,
`fn_upsert_module_progress`, `m2m_module_progress`, `m2m_checkpoints`.
**Production changes:** none. Every probe ran inside a transaction that was rolled
back; every transport probe was refused before it could write. Final state
verified unchanged.

---

## Two corrections before the findings

**1. I am not the session that ran the nine prior cases.** My earlier work today
was INTAKE-001 — the intake tables, dead-letter and deletion ledger. I had never
touched `fn_complete_module`, `m2m_module_progress` or `m2m_checkpoints` before
this brief. So "do not reuse Claude's probe SQL" was satisfied trivially: I had
none, and no assumptions to inherit. The independence is real but it comes from a
different fact than the brief assumes.

**2. I published a wrong intermediate result and caught it.** In my second probe
a learner `UPDATE ... SET completed=true` appeared to return **ALLOWED** with the
value unchanged — which would have been a false-success finding. Isolated
properly with `GET DIAGNOSTICS`, it **errors**:
`new row violates row-level security policy for table "m2m_module_progress"`,
stored value `false`, and a control update on the same row in the same role
succeeds with `rows_affected=1`. The first reading was an artifact of exception
state in my own harness, not system behavior. The learner wall holds.

---

## V1 — BLOCKING: every anonymous REST request in production returns 401

**Observed runtime behavior**, over real HTTP to the live PostgREST endpoint
(driven from the database with `pg_net`, using the public anon key exactly as a
browser does):

| Request | Result |
|---|---|
| `POST /rest/v1/rpc/fn_complete_module` | **401** `{"code":"42501","message":"permission denied for function set_workspace_tier_from_jwt"}` |
| `POST /rest/v1/rpc/fn_upsert_module_progress` | **401**, identical body |
| `POST /rest/v1/m2m_web_traffic` | **401**, identical body |
| `POST /rest/v1/m2m_switch_assessments` | **401**, identical body |
| `GET /rest/v1/m2m_web_traffic?select=id&limit=1` | **401**, identical body |

Reads and writes alike. The refusal happens at PostgREST's **pre-request hook**,
before RLS, before the target function, before the table.

**Cause, confirmed at the config level:** `pgrst.db_pre_request =
public.set_workspace_tier_from_jwt` is set on the `authenticator` role, and
`has_function_privilege('anon', …, 'EXECUTE')` is **false**. `authenticated` and
`service_role` retain EXECUTE; `anon` does not.

**This has happened before and was documented at the time.** Migration history:

| Version | Name | Effect on anon |
|---|---|---|
| `20260625234913` | `workspace_tier_pre_request_hook` | installs the hook |
| `20260705022741` | `security_hardening_revoke_rpc_exposure` | **revokes** — first outage |
| `20260706190711` | `grant_execute_pre_request_hook_to_api_roles` | **grants back** |
| `20260731230108` | `m2m_zone_boundary_hardening_v1` | **revokes from anon** — current outage begins |
| `20260810222933` | `lock_rpc_surface_to_service_role` | revokes again, re-grants only `authenticated, service_role` |

The 2026-07-06 fix carries this comment in its own migration body:

> *"Fix: PostgREST pre-request hook must be executable by API roles or every
> anon/authenticated request 42501s before RLS is evaluated."*

The lesson was learned, written down, and then undone twice — on 07-31 and again
on 08-10, whose comment asserts it "keeps the 3 genuine public intake endpoints
open." It does not. With the hook unexecutable by anon, **no** anon endpoint is
reachable.

**Blast radius — every browser-side anon write is dead:**

- **S.W.I.T.C.H. Index submission** (`m2m_switch_assessments`). Last row is
  `2026-07-17`; anon was revoked `2026-07-31`. Submissions have been impossible
  since that date. I cannot prove nobody tried between those two dates, so the
  revocation explains the silence from 07-31 onward, not the fortnight before it.
- **`m2m_web_traffic` telemetry — including my own work today.** This one is
  mine to own. The failure-visibility layer I shipped this morning writes its
  `form_error` row through the same anon REST path. It will 401. **The record of
  the failure cannot itself be written.** My claim that "failures are never
  silent again" is false in production until V1 is fixed — the mechanism is
  correct, the transport underneath it is not.
- **PR #27's landing-page capture** to `roi_assessment`, which writes as anon.
  The D1 error branch will at least show the visitor a failure now; the lead is
  still lost.

**Not affected:** the `m2m-site-intake` Edge Function. It is Deno holding
`service_role` internally, not PostgREST-as-anon, which is exactly why INTAKE-001
passed its end-to-end cases this afternoon while every browser path was dead.
That distinction is the whole finding: **the intake path that was tested works,
and the paths that were not tested over real transport do not.**

**Fix shape** (not applied — production change, and it is a live auth control):
`grant execute on function public.set_workspace_tier_from_jwt() to anon;`
Then re-run the five transport probes above and require non-401 before shipping.
Worth pairing with a conformance check that fails if `anon` ever loses EXECUTE on
whatever `pgrst.db_pre_request` names — this is the third occurrence.

---

## V2 — HIGH: `completed=true` has a second writer, and it checks nothing

The contract states `fn_complete_module` is "the only path that can" write
`completed=true`. **That is false.**

`update_m2m_module_progress_updated_at()` — `BEFORE UPDATE`, SECURITY INVOKER:

```sql
IF NEW.status = 'completed' AND OLD.status != 'completed' THEN
  NEW.completed_at = NOW();
  NEW.completed = TRUE;      -- no checkpoint, no verdict, no Founder auth, no evidence
END IF;
```

**Observed.** With **zero rows in `m2m_checkpoints`**, an authenticated admin
(`m2m_is_admin()` true) updating a single text column:

```
seeded:  completed=false  status=in_progress  evidence=NULL
UPDATE m2m_module_progress SET status='completed' WHERE …
result:  completed=true   evidence=NULL  completion_verified_at=NULL
         completed_at=2026-08-29 23:46:38.904439+00
```

`service_role` reaches it identically: `ALLOWED | completed=true evidence=NULL`.

This breaks two contract lines directly — *Database write ≠ completion* and
*Verified APPROVE + authenticated checkpoint evidence = completion eligibility*.
A single-column update **is** a completion, and `completed=true` no longer implies
evidence exists.

**The learner is walled off** — `learner_update_own` WITH CHECK rejects
`status='completed'`, and the INSERT path too, both leaving zero residue. So this
is a broken invariant reachable by admin and by any server-side code path, not a
learner privilege escalation.

**Nothing at the schema level catches it.** The only CHECK constraints are
`score BETWEEN 0 AND 100` and the `status` enum. No constraint ties `completed`
to `completion_evidence_ref`.

The `status` enum also permits `'graduated'`, which is neither learner-settable
nor handled by the trigger — worth a decision.

**Fix shape:** either drop the `completed` assignment from the trigger and let
`fn_complete_module` own it exclusively, or add
`CHECK (completed = false OR completion_evidence_ref IS NOT NULL)`. The
constraint is the stronger of the two because it holds regardless of which path
writes.

---

## V3 — MEDIUM: `os_lane = NULL` defeats the uniqueness contract entirely

**Observed.** Three identical calls, one learner:

```
fn_upsert_module_progress(NULL,'MOD-N2','in_progress')  ×3   →  3 rows
fn_upsert_module_progress('PIVOT_OS','MOD-N1',…)        ×2   →  1 row   (control)
```

`uq_mmp_user_lane_module` is partial on `os_lane IS NOT NULL`, and NULLs are
distinct in a btree unique index, so the `ON CONFLICT` target never matches. The
function accepts `p_os_lane` without a NULL check and `os_lane` is nullable.
Unbounded row growth per learner per module, no privilege required beyond a
session. Reject NULL `p_os_lane` in the function, or make the column NOT NULL.

---

## V4 — MEDIUM: a learner can write any `email`, and the facilitator view keys on it

**Observed.** Direct INSERT as a learner — **ALLOWED**, 1 row:

```sql
INSERT INTO m2m_module_progress
  (user_id, os_lane, module_id, status, email, module_title, checkpoints_passed, score)
VALUES (<self>, 'PIVOT_OS','MOD-N5','in_progress',
        'victim@example.test','Fabricated Title', 99, 100);
```

`learner_insert_own` WITH CHECK constrains only `user_id`, `completed`, `status`
and `completion_evidence_ref`. Everything else is free text, including `email`,
`module_title`, `checkpoints_passed` and `score`.

`Facilitator read member progress` grants SELECT where
`lower(m2m_module_progress.email) = lower(cm.email)`. So a learner can inject
rows that appear in **another cohort member's facilitator dashboard**, with
attacker-chosen title and counters. The learner still cannot *read* anything but
their own rows — this is write-side poisoning of someone else's view, not a read
leak.

---

## V5 / V6 — MEDIUM: no normalization, no module validation

**Observed.** `PIVOT_OS` / `pivot_os` / `Pivot_Os` → **3 distinct rows** for one
learner and one module. 25 invented module ids (`NOT-A-REAL-MODULE-1…25`) → **25
rows**. Neither field is validated, folded, or foreign-keyed. Combined with V4 this
is the practical shape of dashboard pollution.

---

## V7 — Structural: completion is unreachable on a learner's behalf by anyone

Not a bypass — the reverse. Established by inspection **and** observation:

- **Learner:** `m2m_checkpoints` carries only `m2m_checkpoints_admin_all`
  (`m2m_is_admin()`) and a `service_role` policy. No learner SELECT. I confirmed
  there is also **no view and no other SECURITY DEFINER function** over
  `m2m_checkpoints` that a learner may execute. The required checkpoint UUID is
  therefore unobtainable. EXECUTE on `fn_complete_module` *is* granted to
  `authenticated`, so the function is callable and its third argument is not.
- **service_role:** observed — `COMPLETION REFUSED: no user session.`
  `auth.uid()` is NULL for a service-role JWT.
- **Admin:** can read checkpoints, but the function derives `user_id` from
  `auth.uid()`, so an admin can only ever complete **their own** modules.

**The happy path does work, for self-completion.** Observed, with a valid
checkpoint (reviewed + `APPROVE` + `kev_authenticated` + `kev_auth_at`):

```
returned {"evidence":"c57ae90f-…","completed":true}
row:     completed=true  evidence=c57ae90f-…
```

So the function is sound and simply has no caller who can use it for a learner.
Either a learner-scoped SELECT policy on `m2m_checkpoints` is missing, or the
intended caller is a server actor that mints a user-scoped JWT. That is a design
decision, not something I should guess at.

---

## V8 — Revocation does not cascade (confirmed, with a nuance in its favour)

**Observed.** After a valid completion, setting `kev_authenticated=false`:

```
checkpoint:  kev_authenticated=false   kev_auth_at=2026-08-29 23:49:23.966197+00  (NOT cleared)
progress:    completed=true            evidence → the now-withdrawn checkpoint
re-run:      COMPLETION REFUSED: checkpoint … is not Founder-authenticated.
```

The gate holds **forward** — a withdrawn checkpoint cannot produce a new
completion. What persists is history: an existing completion continues to assert
evidence that has since been retracted, and `kev_auth_at` still reads as though
authentication stands. Whether that is the intended governance semantics is
Kev's call; if it is not, the cascade needs to revisit `m2m_module_progress` rows
whose `completion_evidence_ref` points at a de-authenticated checkpoint.

---

## Tested and refuted — report these as non-findings

- **`client_id` squatting.** My hypothesis was that a learner could occupy a
  `(client_id, module_id)` pair and block the client-scoped write path. **Wrong** —
  `m2m_module_progress_client_id_fkey` rejects any `client_id` not present in the
  parent table, for learner and service_role alike.
- **RPC return fidelity.** `fn_upsert_module_progress` returned
  `{"status":"checkpoint_pending",…}` and the stored status was
  `checkpoint_pending`. No divergence between what it reports and what it wrote.
- **Learner write to `completed` / `completion_evidence_ref`.** Both error; stored
  values unchanged; a control update in the same role and row succeeds.
- **RST-001 authority ceiling.** `m2m_is_admin()` is
  `exists(select 1 from m2m_admins where user_id = auth.uid())` — a pure identity
  lookup. **Code inspection:** no progress, participation or score value appears in
  it or in any policy predicate on these tables. Volume of completions cannot
  influence it.
- **SECURITY DEFINER surface of `fn_complete_module`.** **Code inspection:**
  `search_path` pinned to `public, pg_catalog`; all SQL static and parameterized;
  the only write target is `m2m_module_progress`; `user_id` is taken from
  `auth.uid()` and is not an argument, so no argument shaping reaches another
  user's row.

---

## NOT EXECUTED — and why

**Concurrency (brief item 2) — not executed.** `dblink` is not installed, so I
cannot open a second backend session from inside SQL. `pg_net` can drive real
concurrent HTTP, but reaching these functions requires a JWT signed as
`authenticated`, and minting one means extracting and using the project's JWT
secret. I did not do that — it is credential material, and forging session claims
is the precise bypass class the FL/II gate was hardened against today. Doing it
even to test would put a working forgery recipe in the transcript.

To close it properly: two concurrent `psql` sessions, or a small harness holding a
legitimately issued user JWT, running `fn_complete_module` ×2 and
`fn_upsert_module_progress` racing `fn_complete_module` on one key.

**Authenticated transport (brief item 1) — not closed.** My role impersonation
carries exactly the same limitation the brief identifies in the prior run: it
reproduces `auth.uid()` but is not PostgREST. The one transport layer I could
genuinely exercise was **anon** — which is where V1 came from, and V1 suggests the
authenticated path deserves the same treatment with a real session before launch.

---

## State after testing

`m2m_module_progress` 0 rows · `m2m_checkpoints` 0 rows · `m2m_web_traffic` 0 rows ·
`m2m_switch_assessments` 2 rows (unchanged, last `2026-07-17`) ·
`m2m_intake_deletion_ledger` 5 rows (unchanged). No production configuration
altered. Nothing deployed.

## Ranked

1. **V1** — anon REST has been dead for ~29 days; every browser-side write path,
   including the failure-logging I added today, is refused before it reaches the
   database. This is the one that costs leads during launch week.
2. **V2** — `completed=true` is reachable without evidence via the update trigger.
3. **V4 / V3 / V5 / V6** — learner-writable `email` into facilitator views, plus
   NULL-lane, case-variant and invented-module row multiplication.
4. **V7 / V8** — structural reachability and revocation semantics; decisions, not
   defects.
