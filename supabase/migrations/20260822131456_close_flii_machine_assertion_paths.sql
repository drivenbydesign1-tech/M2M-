-- Close the machine paths that assert Founder authentication.
--
-- Founder instruction 2026-08-22. Three functions set fl_ii_authenticated = true
-- with no human session behind it. A fourth, fn_fl_ii_close_loop, only REACTS to a
-- genuine authentication (it reads the flag in its IF condition and closes the loop)
-- and is deliberately left untouched.
--
-- Context that shapes the fix: fn_flii_machine_redirect was tested for the first
-- time today and it works. An agent setting fl_ii_authenticated = true is redirected
-- to fl_ii_authenticated = false, machine_verified = true, machine_verified_by
-- 'postgres / mgmt-api'. So these three paths are already neutralised for a
-- sessionless caller. They are closed anyway for two reasons: the guard passes the
-- write through when auth.uid() IS NOT NULL, so a machine path invoked while a human
-- happens to be signed in would authenticate in that human's name; and a function
-- should not contain an assertion it has no standing to make.
--
-- What replaces the assertion in each case: record what actually happened. The work
-- was produced, so status becomes ARCHITECT_REVIEW rather than APPROVED, the output
-- is captured, and machine_verified records that a machine confirmed it. Nothing
-- claims a verdict or an authentication that nobody made.

-- 1. process_loop_watcher_signal — the CLOSE_APPROVED branch the Founder named.
create or replace function public.process_loop_watcher_signal()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
BEGIN
  -- Skip if no loop_id (happens when searchRows returns nothing)
  IF NEW.loop_id IS NULL THEN
    NEW.processed := true;
    RETURN NEW;
  END IF;

  IF NEW.signal_type = 'CLAIM' THEN
    UPDATE loop_executions
    SET status = 'RUNNING', make_scenario_id = NEW.scenario_id, updated_at = now()
    WHERE id = NEW.loop_id AND status = 'INITIATED';

  ELSIF NEW.signal_type = 'CLOSE_APPROVED' THEN
    -- Was: status APPROVED, fl_ii_authenticated true, last_gate_verdict TRUST.
    -- A watcher signal is a machine saying it finished. It is not a Founder
    -- authentication and it is not a judge verdict. Record the output and hand
    -- the loop to the Architect.
    UPDATE loop_executions
    SET status                = 'ARCHITECT_REVIEW',
        current_output        = NEW.brief_content,
        final_output          = NEW.brief_content,
        cycle_count           = 1,
        machine_verified      = true,
        machine_verified_at   = now(),
        machine_verified_by   = 'process_loop_watcher_signal / '||coalesce(NEW.scenario_id,'unknown'),
        updated_at            = now()
    WHERE id = NEW.loop_id;

    INSERT INTO loop_audit_trail (loop_id, event_type, from_status, to_status, cycle_number, actor, detail)
    VALUES (NEW.loop_id, 'LOOP_WATCHER_COMPLETED', 'RUNNING', 'ARCHITECT_REVIEW', 1, NEW.scenario_id,
            jsonb_build_object('note','Machine completion. No verdict and no Founder authentication asserted.',
                               'closed_by','process_loop_watcher_signal'));

  ELSIF NEW.signal_type = 'ESCALATE' THEN
    UPDATE loop_executions SET status = 'HUMAN_REQUIRED', updated_at = now()
    WHERE id = NEW.loop_id;
  END IF;

  NEW.processed := true;
  RETURN NEW;
END;
$function$;

-- 2. fn_gate_checkpoint_router — the LOOP-WATCHER auto-close branch.
--    A gate verdict is legitimately recorded here (it is the checkpoint's own
--    verdict), but a gate pass is not a Founder authentication, so the flag is gone.
--    The duplicate m2m_daily_intel insert is also removed: the Make modules already
--    write the brief, and this second write is what produced 9 intel rows on
--    2026-08-12 against a normal 2.
create or replace function public.fn_gate_checkpoint_router()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
DECLARE
  v_loop public.loop_executions%ROWTYPE;
BEGIN
  SELECT * INTO v_loop FROM public.loop_executions WHERE id = NEW.loop_id;

  -- LOOP-WATCHER completion: single checkpoint sufficient for briefing loops.
  IF NEW.gate_verdict = 'TRUST' AND NEW.evaluated_by ILIKE 'LOOP-WATCHER%' THEN
    UPDATE public.loop_executions
    SET status                = 'ARCHITECT_REVIEW',
        last_gate_verdict     = 'TRUST',
        last_gate_at          = now(),
        gate_checkpoint_count = gate_checkpoint_count + 1,
        current_output        = COALESCE(NEW.content_snapshot, current_output),
        final_output          = COALESCE(NEW.content_snapshot, final_output),
        cycle_count           = 1,
        machine_verified      = true,
        machine_verified_at   = now(),
        machine_verified_by   = 'fn_gate_checkpoint_router / '||coalesce(NEW.evaluated_by,'unknown'),
        updated_at            = now()
    WHERE id = NEW.loop_id;

    INSERT INTO public.loop_audit_trail
      (loop_id, event_type, from_status, to_status, cycle_number, actor, detail)
    VALUES (NEW.loop_id, 'LOOP_WATCHER_COMPLETED', 'RUNNING', 'ARCHITECT_REVIEW', 1, NEW.evaluated_by,
            jsonb_build_object('note','Gate verdict recorded. No Founder authentication asserted.',
                               'gate_verdict', NEW.gate_verdict));

    RETURN NEW;
  END IF;

  -- Case 1: TRUST at final checkpoint (3) -> ARCHITECT_REVIEW
  IF NEW.gate_verdict = 'TRUST' AND NEW.checkpoint_number = 3 THEN
    UPDATE public.loop_executions
    SET status = 'ARCHITECT_REVIEW',
        last_gate_verdict = NEW.gate_verdict,
        last_gate_at = now(),
        gate_checkpoint_count = gate_checkpoint_count + 1
    WHERE id = NEW.loop_id;

  -- Case 2: TRUST at checkpoint 1 or 2 -> keep running
  ELSIF NEW.gate_verdict = 'TRUST' THEN
    UPDATE public.loop_executions
    SET status = 'RUNNING',
        last_gate_verdict = NEW.gate_verdict,
        last_gate_at = now(),
        gate_checkpoint_count = gate_checkpoint_count + 1
    WHERE id = NEW.loop_id;

  -- Case 3: MARGINAL -> retry if under max_cycles
  ELSIF NEW.gate_verdict = 'MARGINAL' THEN
    IF v_loop.cycle_count < v_loop.max_cycles THEN
      UPDATE public.loop_executions
      SET status = 'AWAITING_RETRY',
          cycle_count = cycle_count + 1,
          last_gate_verdict = NEW.gate_verdict,
          last_gate_at = now(),
          gate_checkpoint_count = gate_checkpoint_count + 1
      WHERE id = NEW.loop_id;
    ELSE
      UPDATE public.loop_executions
      SET status = 'HUMAN_REQUIRED',
          circuit_breaker_fired = true,
          last_gate_verdict = NEW.gate_verdict,
          last_gate_at = now(),
          gate_checkpoint_count = gate_checkpoint_count + 1
      WHERE id = NEW.loop_id;

      INSERT INTO public.human_required_queue
        (loop_id, os_lane, priority, failure_reason, failure_gate, cycle_count, content_for_review, gate_notes)
      VALUES (
        NEW.loop_id, v_loop.os_lane,
        CASE v_loop.os_lane WHEN 'HUMAN_OS' THEN 'high' WHEN 'BRIDGE_OS' THEN 'high' ELSE 'normal' END,
        'Exceeded max_cycles with MARGINAL verdict',
        NEW.checkpoint_number, v_loop.cycle_count,
        COALESCE(v_loop.current_output, v_loop.draft_content, ''),
        NEW.verdict_rationale
      );
    END IF;

  -- Case 4: LIABILITY -> immediate HUMAN_REQUIRED
  ELSIF NEW.gate_verdict = 'LIABILITY' THEN
    UPDATE public.loop_executions
    SET status = 'HUMAN_REQUIRED',
        circuit_breaker_fired = true,
        last_gate_verdict = NEW.gate_verdict,
        last_gate_at = now()
    WHERE id = NEW.loop_id;

    INSERT INTO public.human_required_queue
      (loop_id, os_lane, priority, failure_reason, failure_gate, cycle_count, content_for_review, gate_notes)
    VALUES (
      NEW.loop_id, v_loop.os_lane, 'urgent',
      'LIABILITY verdict — immediate escalation',
      NEW.checkpoint_number, v_loop.cycle_count,
      COALESCE(v_loop.current_output, v_loop.draft_content, ''),
      NEW.verdict_rationale
    );
  END IF;

  RETURN NEW;
END;
$function$;

-- 3. close_loop_approved — a SECURITY DEFINER RPC granted to service_role that
--    stamped authentication for whichever caller invoked it. This is the
--    authenticate_sovereign_task anti-pattern: it manufactures evidence. The
--    behaviour is corrected rather than the function dropped, so any caller keeps
--    working; it simply no longer asserts what it has no standing to assert.
create or replace function public.close_loop_approved(
  p_loop_id uuid, p_brief_content text, p_scenario_id text)
returns void
language plpgsql
security definer
set search_path to 'public', 'extensions', 'pg_temp'
as $function$
BEGIN
  UPDATE loop_executions
  SET status              = 'ARCHITECT_REVIEW',
      current_output      = p_brief_content,
      final_output        = p_brief_content,
      cycle_count         = 1,
      machine_verified    = true,
      machine_verified_at = now(),
      machine_verified_by = 'close_loop_approved / '||coalesce(p_scenario_id,'unknown'),
      updated_at          = now()
  WHERE id = p_loop_id;
END;
$function$;

comment on function public.close_loop_approved(uuid, text, text) is
  'Records machine completion of a loop: captures output and moves it to ARCHITECT_REVIEW. Despite the historical name it does NOT approve or authenticate anything. It previously set fl_ii_authenticated = true and last_gate_verdict = TRUST for whichever caller invoked it; both were removed 2026-08-22 on Founder instruction. Founder authentication happens only through a verified session.';

revoke execute on function public.close_loop_approved(uuid, text, text) from anon, public;
