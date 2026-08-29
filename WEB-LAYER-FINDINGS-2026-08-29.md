# M2M Web Layer — findings, 2026-08-29

> **PARTIALLY SUPERSEDED by the handoff update of 2026-08-29 (post-verification).**
> Read these three corrections before the rest of this document.
>
> **1. The 27 deleted rows are resolved — stand down.** Attributed via
> `pg_stat_statements`: every deletion ran as `postgres`, matched
> `WHERE email LIKE $1`, and sat alongside a counter named `remaining_test_rows`.
> The orphan `intake_id aeb8e4d0…` flagged below resolves to
> `qa+1786486417@m2msovereign.test` / "QA Spotcheck". The 27 inserts span five
> payload shapes — iterative development, not 27 leads. Residual noted by Kev:
> normalized parameters make the LIKE patterns unreadable and three deletes were
> targeted `WHERE id = $1`, so it is not *provably* zero real leads; the dead
> tuples remain on disk unvacuumed if it ever needs settling. **The section
> below headed "Headline" overstates this. It is not the headline.**
>
> **2. Intake capture is verified operational.** A live end-to-end POST to the
> Edge Function (no auth header, as the browser sends it) returned HTTP 200 in
> 1.73s with `{"ok":true,"capture":"primary","notify":"ok"}` and the row landed
> correctly. Do not re-investigate.
>
> **3. The priority order changed.** `r(!0)` firing outside the try/catch on all
> three intake lanes is now priority 1 — it is the only defect that loses real
> leads. The `console.log` email grab is priority 2. Worker + beacon is
> priority 3. See **`APEX-INTAKE-PATCH-SPEC.md`** for the verified,
> ready-to-apply spec.
>
> New in the database since this document was written: `m2m_intake_deletion_ledger`
> + `tg_guard_delete` on the intake tables (archives every delete with attribution;
> refuses deletes of more than 5 rows without `SET LOCAL m2m.allow_bulk_delete = 'on'`),
> and the `v_intake_health` view. **If a cleanup script starts failing, that guard
> is working — add the `SET LOCAL` line, do not drop the trigger.**

Execution notes against the Claude Code handoff. Written for the next session,
which will need to start against a different repository (see Task 2).

Everything below marked **verified** was checked against live production or the
live database in this session. Nothing was deployed. No production data was
written, altered or deleted. `authenticate_sovereign_task()` was not run.

---

## ~~Headline~~ — SUPERSEDED, see correction 1 above. Retained for the investigation trail.

The handoff attributes three months of missing intake to the PIVOT OS landing
form discarding emails. That form **is** broken exactly as described, but it is a
top-of-funnel email grab, not the intake path. The real chain is longer, and the
last link is the serious one.

**1. The Make webhooks died on 2026-07-05.** The `m2m-site-intake` Edge Function
   header states it replaces four hardcoded Make webhooks feeding scenarios
   5576145 and 5576058, "both of which went isinvalid=true / isActive=false on
   2026-07-05, silently dropping every site submission thereafter." That is the
   origin of the gap.

**2. The replacement was deployed and works.** `m2m-site-intake` is ACTIVE,
   version 10, `verify_jwt=false`. All three intake pages POST to it. It writes
   `m2m_pivot_intake` first as the durable record, then mirrors to the lane table.

**3. Captured intake is being deleted afterwards.** *(verified)*

   ```
   m2m_pivot_intake   n_live_tup=0   n_tup_ins=27   n_tup_del=27
   ```

   27 intake rows were captured and all 27 were deleted. This is not an RLS
   visibility artifact — the session ran as `postgres` with `rolbypassrls=true`.
   Corroborated independently: the one surviving mirror row in `pivot_leads`
   (`source='site-intake'`, 2026-08-11) carries
   `custom_fields.intake_id = aeb8e4d0-4a60-43bd-a668-e3e2eeb4914a`, and that
   parent row no longer exists.

   What did **not** delete them (each checked): no trigger on the table
   (`user_triggers=0`); no database function references `m2m_pivot_intake` at all;
   no pg_cron job touches it — `m2m_cycle_sweep_apply` operates on
   `loop_executions`; no migration contains a DELETE or TRUNCATE against it; no
   GDPR erasure path ran, `m2m_data_subject_requests` is empty; and no archive
   table received them (`events_archive` and `m2m_certification_archive` are
   empty or unrelated).

   That leaves an ad-hoc deletion by something holding `service_role` or
   `postgres` — a dashboard query, a script, or an agent. Postgres retains no
   attribution for it without an audit extension, so **this is Kev's call, not a
   thing to fix blind.** Fixing the forms while this is unresolved means new leads
   land in the same table the last 27 left from.

   Counts are cumulative since the last statistics reset, so "27" is a floor for
   that window, not necessarily the all-time total.

---

## Task 1 — the lead form. Diagnosis confirmed; blocked on repo access.

**Verified** against the shipped production bundle
(`/assets/index-Co80xarS.js`, 921,383 bytes, fetched from the live apex
deployment). Found verbatim:

```js
function bu(){const e=Tn(),[t,n]=x.useState("");
  function r(a){a.preventDefault(),console.log("PIVOT OS intake email:",t),n(""),e("/pivot-intake")}
```

`bu()` is the PIVOT OS landing page, sitting directly after the copy array ending
`"...not a pep talk, not a resume refresh, not a LinkedIn audit"`. The email in
`t` is logged to console and dropped; `n("")` clears the input unconditionally;
`e("/pivot-intake")` navigates away. Nothing is persisted.

Also verified in the bundle: exactly **2** `.insert(` calls, on
`m2m_cohort_members` and `m2m_data_subject_requests` — both authenticated portal
features, neither on an intake path. The string `roi_assessment` appears **0**
times in the entire bundle.

`roi_assessment` accepts anonymous inserts *(verified)*: policy
`roi_assessment_insert`, `cmd=INSERT`, roles `{anon,authenticated}`,
`with_check=true`. Columns `contact_email` and `source` both exist. The table
currently holds **0 rows**, consistent with the form never having persisted
anything.

### Correction to the handoff: the other two lanes are NOT stubbed

The handoff says to "assume all three lanes are stubbed until you prove
otherwise." Proven otherwise. `/pivot-intake` (`v0`), `/bridge-intake` (`C0`) and
`/human-intake` (`F0`) each POST a full payload to the Supabase Edge Function:

| Route | Component | Endpoint |
|---|---|---|
| `/pivot-intake`  | `v0` | `…/functions/v1/m2m-site-intake?lane=PIVOT_OS` (JSON) |
| `/bridge-intake` | `C0` | `…/functions/v1/m2m-site-intake?lane=BRIDGE_OS` (JSON) |
| `/human-intake`  | `F0` | `…/functions/v1/m2m-site-intake` (form-urlencoded) |

They are not stubs. They do, however, share a real defect worth fixing in the
same pass — the same "silent failure in a different costume" the handoff warns
about:

```js
(await fetch(g0,{…})).ok && Bc()
} catch(p){ console.error("PIVOT OS™ webhook error:",p) }
r(!0)                      // success screen shown regardless
```

`r(!0)` sits outside the try/catch and is not conditioned on `.ok`. If the
function is down or returns non-2xx, the visitor sees the confirmation screen and
the submission is gone, with only a `console.error`. All three lanes do this.

### The patch, ready to apply

In `bu()`, replace handler `r`. Do not clear the input on failure; do not swallow
the error.

```js
const [busy, setBusy] = useState(false);
const [err, setErr] = useState("");

async function r(a) {
  a.preventDefault();
  if (busy) return;
  setErr("");
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(t)) {
    setErr("Enter a valid email address.");
    return;                                  // input NOT cleared
  }
  setBusy(true);
  const { error } = await supabase
    .from('roi_assessment')
    .insert({ contact_email: t, source: 'pivot-os-landing' });
  setBusy(false);
  if (error) {
    setErr("We couldn't save that — please try again.");
    return;                                  // input NOT cleared, error NOT swallowed
  }
  n("");                                     // clear only on confirmed success
  e("/pivot-intake");
}
```

**Blocked.** The apex repo cannot be reached from this session — see Task 2.

---

## Task 2 — the apex repo. Found.

The handoff says the apex is not in Vercel team `team_CYBt39fYOXIriYGNQL0NDoOz`.
It is. The project name is what hid it.

| | |
|---|---|
| Vercel project | **`drivenbydesign1-tech-tiil`** (`prj_F3dNW3PYw0J6WzzalnCyeApqsdWL`) |
| Team | `team_CYBt39fYOXIriYGNQL0NDoOz` — the same team as `m2m-assessment` |
| Domains | `www.model2message.net`, `model2message.net`, `drivenbydesign1-tech-tiil.vercel.app` |
| Framework | Vite |
| **Git repo** | **`github.com/Kali-Dedwen/drivenbydesign1-tech`** (private, owner type User, repo id 1156492783) |
| Branch | `main` |
| Live commit | `d5a5fc416578438daec04af01688600d02b78b1d` |

It **is** Git-linked, contrary to the handoff. Confirmed from the production
deployment's own metadata (`dpl_3q5SsKuZMMsJd5tMw2Gygsz6w3zR`).

**Why Task 1 is blocked here.** This session's GitHub scope is
`drivenbydesign1-tech/*`. The apex lives under a different owner, `Kali-Dedwen`,
and cross-owner attach is refused:

> `add_repo: cross-tier adds are not supported in v1: requested
> "kali-dedwen/drivenbydesign1-tech" but session already has repos from owner(s)
> [drivenbydesign1-tech]`

**To unblock:** start a new Claude Code session with
`Kali-Dedwen/drivenbydesign1-tech` as the *initial* source. That repo also does
not appear in this account's repo listing, so Kev may additionally need to
authorize the `Kali-Dedwen` account under claude.ai → Settings → Connectors, or
grant repo access at https://claude.ai/admin-settings/claude-tag.

---

## Task 3 — assessment repo. Baseline captured and committed.

`assessment-baseline-2026-08-29.html` — 49,829 bytes, CRLF as served.
`sha256 8176cc06f4e6975989a619ae6acdbf0b49c305480d728952dce6480cd36ed8b6`

Pulled byte-faithfully from the live deployment
(`dpl_42aG1Y33SRsgvUT46FvFuhSVsNKH`, origin `last-modified` 2026-08-26 08:18:13
GMT) and committed unmodified. Until that commit, production was the only copy.

**The handoff's baseline file was not present in this environment**, so its hash
`3915bf05…` could not be compared against. It would not have matched anyway:

> **This origin cannot be hash-verified through Cloudflare.** Email Obfuscation is
> enabled on the zone. It rewrites the response body on every request — injecting
> `/cdn-cgi/scripts/…/email-decode.min.js` and replacing the
> `info@model2message.net` mailto with a `data-cfemail` blob whose XOR key is its
> own first byte and is regenerated per response. (Decoded from this capture:
> key `0xf2` → `info@model2message.net`.) Two identical-origin fetches therefore
> produce different bytes. **Compare captures with the `data-cfemail` attribute
> normalised out, never with a whole-file hash.** The handoff's instruction to
> "verify the deployed hash still matches before overwriting anything" cannot
> work as written.

Still outstanding: creating a dedicated `m2m-assessment` repo and Git-linking the
Vercel project. Not done here — this session cannot create and push to a new repo
within its scope, and linking a Vercel project to a repo is Kev's to authorize.
The file is under version control now, which was the point of the task.

---

## Task 4 — Cloudflare Worker. Blocked, and one precondition is answered.

Not deployable from this session:

- `cf-worker-inject.js` **does not exist** in this environment. The handoff
  describes it as written and syntax-checked, but it was not carried over.
- No `wrangler` CLI and no Cloudflare API token are present.
- The Cloudflare MCP server exposes no zone-listing tool, so the zone-account
  question cannot be settled from here either.

**The handoff's open question is answered, though:** `workers_list` returned
`count: 0` again from the connected account. Separately, the assessment origin
responds with `server: cloudflare` and live `cf-ray` headers, and Email
Obfuscation is active on the zone — so the zone is real and Cloudflare-fronted,
but it is **not** in the account this session is connected to. Confirm the account
that holds `model2message.net` before deploying anything.

The rollout order in the handoff is sound and worth keeping: deploy with routes
off, add `assessment.model2message.net/*` first, confirm rows in
`v_traffic_daily`, and only then add `www.model2message.net/*`.

---

## Task 5 — assessment silent failures. Done.

Applied to the captured baseline and committed. See the commit message on
`fix(assessment): stop swallowing telemetry failures…` for detail. Summary:

- All four `console.warn` paths and the bare `if(!sbClient) return;` are gone.
  Failures now route through `m2mFail()`, which records to
  `window.__m2mFailures`, emits `console.error`, and writes a durable
  `form_error` row to `m2m_web_traffic`.
- `scheduleAssessmentView()` now writes `form_view` events to `m2m_web_traffic`
  instead of `m2m_switch_assessments`, so a row in the latter means a real person
  finished the Index.
- `sbInsertTraffic` prefers `window.m2m.formView` when the Worker beacon is live
  and falls back to a direct anon insert, so it composes with Task 4 without
  depending on it. **The beacon does not exist in the page today** — the handoff's
  "route views via `m2m.formView()`" assumes a Worker that is not deployed.
- 16 assertions in `test/assessment-telemetry.test.mjs`, wired into CI (which was
  previously the GitHub starter stub and passed unconditionally).

**Not deployed.** `m2m-assessment` has no Git link, so this cannot reach
production on its own.

---

## Verified as already-done (handoff's "do not redo")

Spot-checked, all confirmed:

- `m2m_web_traffic` exists with the documented shape; `web_traffic_anon_append`
  grants INSERT to `{anon,authenticated}`, `web_traffic_auth_read` grants SELECT
  to `{authenticated}`. Currently 0 rows — nothing is writing to it yet.
- `m2m_switch_assessments` holds exactly **2** rows, 1 with
  `briefing_requested=true`, spanning 2026-07-08 to 2026-07-17 — matching the
  handoff's "one self-test and one auto-fired view."
- Anon key in the assessment HTML is the `anon` role JWT. No `service_role` key
  appears in either the assessment page or the 921KB apex bundle.

---

## Files the handoff referenced that are not in this environment

`cf-worker-inject.js`, `assessment-baseline-2026-08-29.html` (the prior capture),
`CRITICAL-lead-form.md`, `RUNBOOK.md`. They were produced in the chat session and
never transferred. The baseline was re-captured from production; the other three
would need to be re-created or carried over.
