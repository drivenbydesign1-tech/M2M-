# Closing the machine paths that assert Founder authentication

**Date** 2026-08-22
**Ledger** `SEL-20260822-81BE2344` (REMEDIATION, Executed, Pending)
**Component** `MUON-FLII-CLOSE-001`
**Migration** `20260822131456_close_flii_machine_assertion_paths.sql`

---

## The guard works — proven today for the first time

Before changing anything, `fn_flii_machine_redirect` was tested with a rolled-back
probe. An agent setting the flag:

```
after agent set fl_ii_authenticated=true ->
  fl_ii_authenticated = f
  machine_verified    = true
  machine_verified_by = postgres / mgmt-api
```

It redirects correctly. `machine_verified` had been 0 across the whole table, so this
control had never fired in its life. It has now.

**Why close the paths anyway:** the guard passes the write through when
`auth.uid() IS NOT NULL`. Any of these paths invoked while a human happened to be
signed in would have authenticated *in that human's name*. And a function should not
carry an assertion it has no standing to make.

## Three closed, one deliberately left

| Function | Was | Now |
|---|---|---|
| `process_loop_watcher_signal` (CLOSE_APPROVED) | `APPROVED` + `fl_ii_authenticated` + `TRUST` | `ARCHITECT_REVIEW` + `machine_verified` |
| `fn_gate_checkpoint_router` (LOOP-WATCHER branch) | same, plus duplicate intel write | `ARCHITECT_REVIEW` + `machine_verified`, verdict still recorded, duplicate write removed |
| `close_loop_approved` (RPC, `service_role`) | same | `ARCHITECT_REVIEW` + `machine_verified` |
| `fn_fl_ii_close_loop` | — | **untouched** |

`fn_fl_ii_close_loop` only *reacts* to a genuine authentication — it reads the flag in
its `IF` condition to close the loop. It asserts nothing. Leaving it is the point.

`fn_gate_checkpoint_router` still records `last_gate_verdict` from the checkpoint.
That is legitimate: the verdict belongs to the checkpoint. The fabrication was
upstream in Make and is already removed.

The duplicate `m2m_daily_intel` insert in that router is what produced **9 intel rows
on 2026-08-12** against a normal 2. Removed.

## Verified

Rolled-back probe inserting a real `CLOSE_APPROVED` signal:

```
status=ARCHITECT_REVIEW | fl_ii_authenticated=f | machine_verified=true
| last_gate_verdict=null | output_captured=t
```

Static check: the only function body still matching `fl_ii_authenticated = true` is
`fn_fl_ii_close_loop`, and that is its `IF` condition.

`WS31-01`: **10 unguarded writers (5 trigger-attached) → 8 (4)**.
`close_loop_approved` and `fn_gate_checkpoint_router` dropped off the list.

## WS31 is still BLOCKING — stated plainly

This change did not resolve WS31 and was not expected to. The detector counts
functions that write `loop_executions` without invoking the guard explicitly, and the
guard is a *trigger* that applies whether or not a function calls it. The remaining 8
are: five that only read the column (`m2m_cycle_advance`, `m2m_cycle_exit_test`,
`ws41_cycle_integrity_check`, both `trgfn_ws7_outcome_required_loop*`), the legitimate
`fn_fl_ii_close_loop`, the rewritten `process_loop_watcher_signal` (writes the table,
not the flag), and `ws7_platform_integrity_sentinel`.

As written, WS31 cannot reach CONFORM while any function writes `loop_executions` at
all. Whether it should count table-writers or flag-writers is a detector-definition
question for you.

## Left alone on purpose

**The 158 historical rows.** Last written `2026-08-14T11:11:59` by this now-closed
path, attributed to "Dr. Kevin A. Smith" on 130 of them. Correcting them would mean
asserting what did or did not happen on your behalf — the same error in the opposite
direction.

**`ws7_platform_integrity_sentinel`** is the last daily machine path touching the
flag, already named in standing finding `SEL-20260814-1FD0EB01`.

## Rollback — prior definitions

Restoring any of these reinstates a machine authentication path.

`process_loop_watcher_signal`, CLOSE_APPROVED branch:
```sql
UPDATE loop_executions
SET status = 'APPROVED', fl_ii_authenticated = true, fl_ii_authenticated_at = now(),
    gate_checkpoint_count = 1, last_gate_verdict = 'TRUST',
    current_output = NEW.brief_content, final_output = NEW.brief_content,
    cycle_count = 1, updated_at = now()
WHERE id = NEW.loop_id;
INSERT INTO loop_audit_trail (loop_id, event_type, from_status, to_status, cycle_number, actor)
VALUES (NEW.loop_id, 'LOOP_WATCHER_COMPLETED', 'RUNNING', 'APPROVED', 1, NEW.scenario_id);
```

`fn_gate_checkpoint_router`, LOOP-WATCHER branch:
```sql
UPDATE public.loop_executions
SET status = 'APPROVED', fl_ii_authenticated = true, fl_ii_authenticated_at = now(),
    last_gate_verdict = 'TRUST', last_gate_at = now(),
    gate_checkpoint_count = gate_checkpoint_count + 1,
    current_output = COALESCE(NEW.content_snapshot, current_output),
    final_output = COALESCE(NEW.content_snapshot, final_output),
    cycle_count = 1, updated_at = now()
WHERE id = NEW.loop_id;
-- plus: INSERT INTO public.m2m_daily_intel (brief_type, content, kev_reviewed,
--       bridge_actions, human_actions, pivot_actions)
--       VALUES ('MORNING', NEW.content_snapshot, false, 0, 0, 0);
```

`close_loop_approved`:
```sql
UPDATE loop_executions
SET status = 'APPROVED', fl_ii_authenticated = true, fl_ii_authenticated_at = now(),
    gate_checkpoint_count = 1, last_gate_verdict = 'TRUST',
    current_output = p_brief_content, final_output = p_brief_content,
    cycle_count = 1, updated_at = now()
WHERE id = p_loop_id;
```

Revoked grant: `grant execute on function public.close_loop_approved(uuid,text,text) to anon;`
