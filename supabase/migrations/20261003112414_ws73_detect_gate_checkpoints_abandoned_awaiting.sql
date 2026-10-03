-- WS73. A new evaluator, claude-autonomous-gate, began writing gate_checkpoints on
-- 2026-10-02. Three rows so far, and all three are unfinished: gate_verdict NULL,
-- evidence_state 'AWAITING', every notes_NN empty, no judge_verdicts row.
--
--   50b48440  2026-10-02 13:22:18  loop 1f54737b  M2M Sovereign Diagnostic (GATE_CHECK)
--   02f59e96  2026-10-02 20:14:56  loop 8181d521  Friday Weekly Brief       (RUNNING)
--   df8bab8d  2026-10-03 11:14:50  loop 524e21fe  CEO Dashboard Briefing    (RUNNING)
--
-- Nothing watches this. WS44-01 asks whether an ASSERTED verdict has a judge row behind
-- it; a NULL verdict asserts nothing, so WS44-01 correctly reads CONFORM and reports
-- "4 post-watermark verdicts" without counting these at all. Verified by running it
-- against the live table on 2026-10-03. WS66 covers exercise status, WS63 covers gate-log
-- autonomy, WS41-01 covers unauthenticated stage-8+. None of them sees a checkpoint that
-- was opened and never closed.
--
-- This is the WS72-01 shape again: an artifact is created, the record says work began,
-- and the thing that was supposed to finish never does. The CEO Dashboard loop now
-- reaches the gate -- one stage further than it got all last week -- and stalls there
-- instead, still writing no brief.
--
-- WHAT THIS CHECK DOES NOT CLAIM. The evaluator is 22 hours old at the time of writing.
-- AWAITING may be a deliberate first phase with a second pass that has not been wired or
-- scheduled yet, in which case these rows are mid-rollout rather than broken. The check
-- therefore reports the count, the age and the evaluator, and does not assert that the
-- design is wrong. It exists so that an evaluation which stops halfway is a visible
-- condition rather than a silent one -- the same reason WS45-01 exists.
--
-- Threshold: 6 hours. The 2026-10-03 checkpoint was written at 11:14:50.237, inside the
-- same second the LOOP-WATCHER run ended at 11:14:50.292, so this gate writes inline and
-- a completed evaluation should resolve in seconds. Six hours is four orders of magnitude
-- past that and matches the stuck-loop window WS72-01 already uses.
--
-- Rollback: drop function public.ws73_gate_checkpoint_completion_check(uuid);
--           then restore the ws72_brief_delivery_daily cron command to the two WS72 calls.
-- Nothing else is altered.

create or replace function public.ws73_gate_checkpoint_completion_check(p_run_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
DECLARE
  v_stale_h constant numeric := 6;
  v_open int; v_open_stale int; v_total int;
  v_oldest timestamptz; v_oldest_h numeric;
  v_detail jsonb; v_evaluators jsonb;
  v_verdict text; v_severity text; v_observed text;
BEGIN
  SELECT count(*),
         count(*) FILTER (WHERE gate_verdict IS NULL),
         count(*) FILTER (WHERE gate_verdict IS NULL
                            AND created_at < now() - make_interval(hours => v_stale_h::int)),
         min(created_at) FILTER (WHERE gate_verdict IS NULL)
    INTO v_total, v_open, v_open_stale, v_oldest
  FROM gate_checkpoints;

  v_oldest_h := round((extract(epoch FROM (now() - v_oldest)) / 3600.0)::numeric, 2);

  -- Name the loop each stalled checkpoint belongs to; a gate that stalls on the Founder's
  -- brief is not the same event as one that stalls on an internal diagnostic.
  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'checkpoint_id', g.id, 'created_at', g.created_at,
           'age_hours', round((extract(epoch FROM (now() - g.created_at))/3600.0)::numeric, 2),
           'evaluated_by', g.evaluated_by, 'evidence_state', g.evidence_state,
           'loop_id', g.loop_id, 'loop_name', l.loop_name, 'loop_status', l.status::text)
         ORDER BY g.created_at), '[]'::jsonb)
    INTO v_detail
  FROM gate_checkpoints g
  LEFT JOIN loop_executions l ON l.id = g.loop_id
  WHERE g.gate_verdict IS NULL
    AND g.created_at < now() - make_interval(hours => v_stale_h::int);

  SELECT coalesce(jsonb_object_agg(e, n), '{}'::jsonb) INTO v_evaluators
  FROM (SELECT coalesce(evaluated_by,'(null)') e, count(*) n
          FROM gate_checkpoints WHERE gate_verdict IS NULL GROUP BY 1) s;

  v_observed :=
    v_open||' of '||v_total||' gate checkpoints carry no verdict; '||
    v_open_stale||' of those are older than '||v_stale_h||'h'||
    CASE WHEN v_oldest IS NOT NULL
         THEN ', oldest '||v_oldest::text||' ('||v_oldest_h||'h)'
         ELSE '' END||
    '; evaluators with open checkpoints: '||v_evaluators::text;

  v_verdict  := CASE WHEN v_open_stale > 0 THEN 'DEVIATION' ELSE 'CONFORM' END;
  v_severity := CASE WHEN v_open_stale = 0 THEN 'INFO'
                     WHEN v_open_stale > 5 THEN 'HIGH'
                     ELSE 'MEDIUM' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'platform','WS73-01',
    'Did every gate evaluation that opened a checkpoint actually finish it, or are there evaluations that started and stopped?',
    'no gate_checkpoints row older than 6 hours with gate_verdict still NULL',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'open_checkpoints', v_open, 'open_past_threshold', v_open_stale,
      'total_checkpoints', v_total, 'oldest_open', v_oldest, 'oldest_open_age_hours', v_oldest_h,
      'threshold_hours', v_stale_h, 'stalled_detail', v_detail,
      'evaluators_with_open_checkpoints', v_evaluators,
      'why','claude-autonomous-gate began writing checkpoints on 2026-10-02 and left all three with gate_verdict NULL and evidence_state AWAITING. WS44-01 reads CONFORM on the same data because it asks whether an ASSERTED verdict has a judge row behind it, and a NULL verdict asserts nothing. Nothing else covers a checkpoint that was opened and never closed.',
      'not_a_defect_claim','The evaluator was 22 hours old when this check was written. AWAITING may be a deliberate first phase whose second pass is not yet wired. This check reports the condition and does not assert the design is wrong; it blocks nothing.',
      'threshold_derivation','The 2026-10-03 checkpoint was written at 11:14:50.237, within the same second the LOOP-WATCHER run ended at 11:14:50.292 -- this gate writes inline and should resolve in seconds. 6h matches the stuck-loop window WS72-01 already uses.',
      'read_from','public.gate_checkpoints joined to public.loop_executions'),
    jsonb_build_object('universe','every row in gate_checkpoints',
      'universe_count', v_total, 'examined_count', v_total, 'method','FULL',
      'source','public.gate_checkpoints x public.loop_executions',
      'excluded','none; checkpoints younger than the threshold are counted and printed, and excluded from the verdict only'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- Same WS47 lesson: close the inherited PUBLIC grant on a SECURITY DEFINER function.
revoke execute on function public.ws73_gate_checkpoint_completion_check(uuid) from public;
revoke execute on function public.ws73_gate_checkpoint_completion_check(uuid) from anon;
revoke execute on function public.ws73_gate_checkpoint_completion_check(uuid) from authenticated;

DO $verify$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(p.proname||' -> '||g.grantee, ', ') INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (VALUES ('public'),('anon'),('authenticated')) AS g(grantee)
  WHERE n.nspname = 'public'
    AND p.proname = 'ws73_gate_checkpoint_completion_check'
    AND has_function_privilege(g.grantee, p.oid, 'EXECUTE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'WS73 grant check failed, EXECUTE survives for: %', v_bad;
  END IF;
END $verify$;

-- bp004_run_conformance_battery discovers check functions from pg_proc, so WS73 should
-- join the 13:00 battery on its own. Should is not a schedule. Add it to the job this
-- change already owns so it runs daily whether or not discovery picks it up.
SELECT cron.unschedule('ws72_brief_delivery_daily')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ws72_brief_delivery_daily');

SELECT cron.schedule('ws72_brief_delivery_daily', '45 12 * * *', $cron$
  WITH r AS (SELECT gen_random_uuid() AS id)
  SELECT public.ws72_brief_delivery_liveness_check(r.id),
         public.ws72_brief_generation_burst_check(r.id),
         public.ws73_gate_checkpoint_completion_check(r.id)
    FROM r;
$cron$);
