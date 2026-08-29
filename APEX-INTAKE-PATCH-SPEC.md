# Apex intake patch spec — launch-week priorities 1 and 2

For the session that has write access to **`Kali-Dedwen/drivenbydesign1-tech`**
(Vercel project `drivenbydesign1-tech-tiil`, branch `main`).

This session cannot apply it. `add_repo` refuses cross-owner attach:

> `cross-tier adds are not supported in v1: requested
> "kali-dedwen/drivenbydesign1-tech" but session already has repos from owner(s)
> [drivenbydesign1-tech]`

Re-attempted after the handoff update; same refusal. It needs a session started
with that repo as its **initial** source.

Everything below was verified against the shipped production bundle
(`/assets/index-Co80xarS.js`, 921,383 bytes) so the patch lands first try.

---

## Read this first: the fix shape needs one thing that does not exist yet

**None of the three intake components has an error state.** Each has exactly two
`useState` calls — form data and a submitted flag — and no `setError`-shaped
setter anywhere:

```js
function v0(){ const [e,t]=useState(y0), [n,r]=useState(!1); … }   // pivot
function C0(){ const [e,t]=useState(T0), [n,r]=useState(!1); … }   // bridge
function F0(){ const [e,t]=useState(L0), [n,r]=useState(!1); … }   // human
```

So `setError('Something went wrong…')` in the handoff's fix shape is **not a
call to an existing setter**. Each lane needs, in addition to moving `r(!0)`:

1. a new `const [error, setError] = useState('')`
2. an error element rendered in the form branch of the JSX
3. `setError('')` at the top of the submit handler, so a retry clears the prior message

Budget for that. It is the part that will otherwise stall the patch.

## What is already true and needs no work

- **`r(!0)` is a hard view switch.** Each component is
  `return n ? <confirmation> : <form>`. Leaving `r(!0)` out of the catch branch
  therefore keeps the visitor on their filled-in form — exactly the desired
  behaviour, no extra wiring.
- **The phone number is on all three intake pages**, styled per lane
  (`text-pivot`, `text-bridge`, `text-gold`), as `tel:9804749377` →
  `980.474.9377`. The handoff's fallback copy is safe to use.
- **The `if (window.m2m)` guards are safe.** `window.m2m` appears **0 times** in
  the bundle — the beacon does not exist yet. The guards no-op cleanly until the
  Worker ships, so they can go in now.

---

## The three call sites

Grep source for the `console.error` label — it is the reliable key, since the
minified component names below will not appear in the TSX.

| Lane | Minified | Route | Endpoint | Body | Grep key |
|---|---|---|---|---|---|
| PIVOT | `v0` | `/pivot-intake` | `…/functions/v1/m2m-site-intake?lane=PIVOT_OS` | JSON | `PIVOT OS™ webhook error:` |
| BRIDGE | `C0` | `/bridge-intake` | `…/functions/v1/m2m-site-intake?lane=BRIDGE_OS` | JSON | `BRIDGE OS™ webhook error:` |
| HUMAN | `F0` | `/human-intake` | `…/functions/v1/m2m-site-intake` (no lane param) | `application/x-www-form-urlencoded` | `Human OS™ webhook error:` |

All three share the identical defect — `r(!0)` outside the try/catch and not
conditioned on `.ok`:

```js
async function c(m){
  m.preventDefault();
  try { (await fetch(g0,{...})).ok && Bc() }
  catch(p){ console.error("PIVOT OS™ webhook error:",p) }
  r(!0)                    // fires on throw, on 500, on anything
}
```

`Bc()` clears the stored entry-source key (`sessionStorage.removeItem`), so it
must stay inside the success branch — clearing attribution for a submission that
never landed would lose the lane attribution on the visitor's retry.

## Patch, per lane

```js
const [error, setError] = useState('');

async function c(m){
  m.preventDefault();
  setError('');                                    // clear any prior failure
  if (window.m2m) m2m.attempt('pivot_intake');
  try {
    const res = await fetch(g0, {/* unchanged */});
    if (!res.ok) throw new Error('intake HTTP ' + res.status);
    Bc();
    if (window.m2m) m2m.ok('pivot_intake');
    r(!0);                                         // success only on success
  } catch (p) {
    console.error("PIVOT OS™ webhook error:", p);
    if (window.m2m) m2m.fail('pivot_intake', p);
    setError("Something went wrong on our end — call 980.474.9377 or email us.");
    // do NOT call r(!0); do NOT clear the form
  }
}
```

Swap the endpoint constant, the `console.error` label and the `m2m` event name
per lane (`pivot_intake` / `bridge_intake` / `human_intake`). For HUMAN the body
stays form-urlencoded — only the control flow changes.

Render the error in the form branch, above or beside the submit button, and give
it `role="alert"` so it is announced. The lane accent classes above are the ones
already in use on each page.

## Priority 2 — the landing-page email grab

Separate component: `bu()`, the PIVOT OS landing page, immediately after the copy
array ending `"…not a pep talk, not a resume refresh, not a LinkedIn audit"`.

```js
function r(a){ a.preventDefault(), console.log("PIVOT OS intake email:", t), n(""), e("/pivot-intake") }
```

The email is logged and dropped; `n("")` clears the input unconditionally. Patch
in `WEB-LAYER-FINDINGS-2026-08-29.md` under "Task 1 — the patch, ready to apply".
`roi_assessment` accepts anonymous inserts (policy `roi_assessment_insert`,
roles `{anon,authenticated}`, `with_check=true`); `contact_email` and `source`
both exist.

---

## Beacon API — DECIDED: `attempt` / `ok` / `fail`

Settled by Kev, 2026-08-29. The Worker implements **one** API:

| Verb | Meaning |
|---|---|
| `m2m.attempt(name)` | submit started |
| `m2m.ok(name)` | submit landed |
| `m2m.fail(name, err)` | submit lost |

`attempt` paired with `ok` is what makes an abandonment rate computable — the
reason this won over `formView`, which cannot distinguish a started submit from a
completed one.

The assessment app has been migrated and merged: `window.m2m.formView` is gone,
replaced by a `beacon(verb, name, err)` helper under form name `switch_index`.
Two properties the Worker should preserve on the apex side as well:

- **The beacon owns the success event when live.** `beacon('ok', …)` returns
  whether the beacon actually took the event; only if it did not does the app
  write its own `form_submit` row. Without that the two double-count.
- **A throwing or half-implemented beacon must not swallow the event.** Every
  call is try/caught and returns `false` on throw, so the direct insert still
  runs. Verified by test.

Failures are deliberately recorded twice — `beacon('fail', …)` *and* the local
`m2mFail()` path that writes `form_error`. For a lost submission, redundancy is
the point.

Note for the apex lanes: `attempt`/`ok`/`fail` has no verb for a *view*. The
assessment app keeps view events as a direct `m2m_web_traffic` insert. If the
Worker wants view telemetry, that is a separate verb to design, not a reuse of
these three.

## Small gap in the new delete guard

Verified enabled (`tgenabled='O'`) on all four tables as described:
`m2m_pivot_intake`, `pivot_leads`, `roi_assessment`, `m2m_switch_assessments`.

`m2m_web_traffic` is **not** guarded. That is defensible — it is append-only,
PII-free telemetry — but as of the merged assessment patch it now also carries
the `form_error` rows that are the durable evidence a write failed. A bulk delete
there would erase the failure trail without touching the ledger. Worth adding to
the guard, or worth a deliberate decision not to. Flagging, not acting.

The merged assessment patch only ever inserts, so it is unaffected by the guard.
