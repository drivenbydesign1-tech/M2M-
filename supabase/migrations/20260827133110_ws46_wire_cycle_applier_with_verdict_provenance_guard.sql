-- Wiring the applier. The applier itself was NOT built here: public.m2m_cycle_advance
-- (uuid, boolean) and public.m2m_cycle_sweep(boolean, integer) already existed, already
-- previewed by default, and already refused to cross stage 8 -> 9 without Founder
-- authentication. loop_audit_trail held 0 CYCLE_STAGE_ADVANCE events, so apply mode had
-- never once been invoked. What was missing was a governed path to call it.
--
-- Grounding before wiring, because apply mode acts on whatever the exit test blesses:
--   stage 1 -> 2 : MET for 11 loops (loop_name and trigger_source both present). Correct.
--   stage 7 -> 8 : MET for 1 loop -- 6e798ad1, CEO Dashboard Briefing of 2026-08-14.
--                  Its last_gate_verdict is TRUST, its verdict_id is NULL, and
--                  judge_verdicts holds no row for it. It is one of the 119 historical
--                  unbacked verdicts WS44-01 surfaces and explicitly does not endorse.
--
-- Turning apply on unmodified would have advanced that loop toward Founder review on the
-- strength of a judgement nobody made. WS44-01 exists to keep that gap visible; the
-- applier must not consume the gap as though it were evidence. So the stage 7 exit test
-- is tightened FIRST, in the same spirit as the stage 8 Founder guard and the stage 4/5
-- doc_ref guard already present.
--
-- HELD, NOT REMEDIATED: this buys exactly one stage of movement. Stages 2, 3 and 6 return
-- NO_INSTRUMENTATION, so every advanced loop re-parks at stage 2. The pile-up moved; it
-- was not dissolved. See SEL-20260827-5DB7DD89.

-- 1. Tighten stage 7. This can only ever prevent an advance, never cause one, so it is
--    safe to land ahead of enabling apply.
create or replace function public.m2m_cycle_exit_test(p_loop_id uuid)
 returns table(stage_no smallint, stage_key text, verdict text, evidence jsonb)
 language plpgsql
 stable
 set search_path to 'public'
as $function$
DECLARE l record; s record; v_claims int; v_bad int; v_backed boolean;
BEGIN
  SELECT * INTO l FROM loop_executions WHERE id = p_loop_id;
  IF NOT FOUND THEN
    stage_no := NULL; stage_key := NULL; verdict := 'LOOP_NOT_FOUND';
    evidence := jsonb_build_object('loop_id', p_loop_id); RETURN NEXT; RETURN;
  END IF;

  IF l.cycle_stage IS NULL THEN
    stage_no := NULL; stage_key := NULL; verdict := 'UNCLASSIFIED';
    evidence := jsonb_build_object('status', l.status,
      'note','status maps to stages 2-6 ambiguously; classify before advancing');
    RETURN NEXT; RETURN;
  END IF;

  SELECT * INTO s FROM m2m_cycle_stage WHERE m2m_cycle_stage.stage_no = l.cycle_stage;
  stage_no := s.stage_no; stage_key := s.stage_key;

  CASE s.stage_no
    WHEN 1 THEN
      IF l.loop_name IS NOT NULL AND l.trigger_source IS NOT NULL THEN
        verdict := 'MET';
        evidence := jsonb_build_object('objective', l.loop_name, 'trigger', l.trigger_source);
      ELSE
        verdict := 'NOT_MET';
        evidence := jsonb_build_object('missing',
          concat_ws(', ', CASE WHEN l.loop_name IS NULL THEN 'objective' END,
                          CASE WHEN l.trigger_source IS NULL THEN 'trigger_source' END));
      END IF;

    WHEN 2, 3, 6 THEN
      verdict := 'NO_INSTRUMENTATION';
      evidence := jsonb_build_object('exit_test', s.exit_test,
        'note','Nothing in the schema records this condition. The stage cannot be advanced automatically until a signal exists; asserting a pass here would manufacture a control.');

    WHEN 4, 5 THEN
      IF l.doc_ref IS NULL THEN
        verdict := 'BLOCKED_NO_DELIVERABLE_LINK';
        evidence := jsonb_build_object('exit_test', s.exit_test,
          'note','loop_executions.doc_ref is NULL, so claims in m2m_claim_register cannot be attributed to this loop.',
          'measured','2026-08-22: NULL on all 203 rows. m2m_loop_deliverable_match_preview() reports 0 MATCHED, 0 AMBIGUOUS, 203 UNMATCHED.',
          'prior_defect','This branch previously compared m2m_claim_register.doc_id (text) to loop_executions.deliverable_id (uuid) and raised SQLSTATE 42883. It was unreachable only because deliverable_id was NULL on every row.',
          'population_authority','Binding a loop to a document is a Founder decision. No deterministic rule in the live data supports it.');
      ELSE
        SELECT count(*) FILTER (WHERE material),
               count(*) FILTER (WHERE material AND (
                 evidence_id IS NULL
                 OR NOT EXISTS (SELECT 1 FROM muon_evidence e WHERE e.evidence_id = c.evidence_id)
                 OR EXISTS (SELECT 1 FROM muon_evidence e WHERE e.evidence_id = c.evidence_id AND e.verification_status='SUPERSEDED')
                 OR (s.stage_no = 4 AND (population_scope IS NULL OR jurisdiction IS NULL OR timeframe IS NULL))))
          INTO v_claims, v_bad
        FROM m2m_claim_register c WHERE c.doc_id = l.doc_ref;

        IF v_claims = 0 THEN
          verdict := 'NOT_MET';
          evidence := jsonb_build_object('doc_ref', l.doc_ref,
            'note','no material claims registered for the linked document');
        ELSIF v_bad = 0 THEN
          verdict := 'MET';
          evidence := jsonb_build_object('doc_ref', l.doc_ref, 'material_claims', v_claims, 'unresolved', 0);
        ELSE
          verdict := 'NOT_MET';
          evidence := jsonb_build_object('doc_ref', l.doc_ref, 'material_claims', v_claims, 'unresolved', v_bad);
        END IF;
      END IF;

    WHEN 7 THEN
      -- A verdict with no judge_verdicts row behind it is not evidence of a test.
      v_backed := (l.verdict_id IS NOT NULL
                     AND EXISTS (SELECT 1 FROM judge_verdicts j WHERE j.id = l.verdict_id))
                  OR EXISTS (SELECT 1 FROM judge_verdicts j2 WHERE j2.loop_id = l.id);

      IF coalesce(l.gate_checkpoint_count,0) > 0 AND l.last_gate_verdict = 'TRUST' AND v_backed THEN
        verdict := 'MET';
        evidence := jsonb_build_object('gate_verdict', l.last_gate_verdict,
                                       'checkpoints', l.gate_checkpoint_count,
                                       'verdict_backed', true);
      ELSIF coalesce(l.gate_checkpoint_count,0) > 0 AND l.last_gate_verdict = 'TRUST' AND NOT v_backed THEN
        verdict := 'BLOCKED_UNBACKED_VERDICT';
        evidence := jsonb_build_object('gate_verdict', l.last_gate_verdict,
          'checkpoints', l.gate_checkpoint_count,
          'verdict_id', l.verdict_id,
          'judge_verdicts_row', false,
          'note','This loop asserts TRUST with no judge_verdicts row behind it. WS44-01 accepts the 119 pre-2026-08-22 verdicts as historical and explicitly does not endorse them. Advancing on one would convert an acknowledged evidence gap into a stage transition, and the record would then say a test was passed that nobody ran.',
          'resolution','Either wire the evaluator to write judge_verdicts and set verdict_id, or have the Founder dispose of this verdict directly. The applier takes no side.');
      ELSE
        verdict := 'NOT_MET';
        evidence := jsonb_build_object('gate_verdict', l.last_gate_verdict,
          'checkpoints', coalesce(l.gate_checkpoint_count,0),
          'required','at least one gate checkpoint with verdict TRUST, backed by a judge_verdicts row');
      END IF;

    WHEN 8 THEN
      IF coalesce(l.fl_ii_authenticated,false) THEN
        verdict := 'MET';
        evidence := jsonb_build_object('authenticated_by', l.fl_ii_authenticated_by,
                                       'authenticated_at', l.fl_ii_authenticated_at);
      ELSE
        verdict := 'REQUIRES_FOUNDER';
        evidence := jsonb_build_object('exit_test', s.exit_test,
          'note','Only Kevin A. Smith can satisfy this, through a verified session. No agent path exists and none should be built.');
      END IF;

    WHEN 9 THEN
      verdict := 'TERMINAL';
      evidence := jsonb_build_object('exit_test', s.exit_test,
        'note','Stage 9 closes this cycle and seeds the next. Advancement past it is a new loop, not a transition.');
  END CASE;

  RETURN NEXT;
END; $function$;

-- 2. The governed apply path. Mirrors m2m_cycle_sweep_preview but hardcodes p_apply := true
--    and records mode APPLY, so preview and apply runs are separable in the log forever.
create or replace function public.m2m_cycle_sweep_apply(p_limit integer default 100)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_rows jsonb; v_n int; v_applied int;
  v_eligible int; v_unclassified int;
  v_audit_before bigint; v_audit_after bigint;
BEGIN
  SELECT count(*) INTO v_audit_before FROM loop_audit_trail;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'loop_id', s.loop_id, 'from_stage', s.from_stage,
           'verdict', s.verdict, 'applied', s.applied)), '[]'::jsonb),
         count(*), count(*) FILTER (WHERE s.applied)
    INTO v_rows, v_n, v_applied
  FROM public.m2m_cycle_sweep(true, p_limit) s;   -- true is not a parameter of this function

  SELECT count(*) FILTER (WHERE cycle_stage IS NOT NULL AND cycle_stage < 9),
         count(*) FILTER (WHERE cycle_stage IS NULL)
    INTO v_eligible, v_unclassified
  FROM loop_executions;

  SELECT count(*) INTO v_audit_after FROM loop_audit_trail;

  INSERT INTO m2m_cycle_sweep_log(
    run_id, mode, limit_used, candidates, eligible_now, unclassified_now,
    verdict_counts, results, audit_rows_written)
  VALUES (
    v_run, 'APPLY', p_limit, v_n, v_eligible, v_unclassified,
    (SELECT coalesce(jsonb_object_agg(v, c), '{}'::jsonb)
       FROM (SELECT r->>'verdict' AS v, count(*) AS c
               FROM jsonb_array_elements(v_rows) r GROUP BY 1) q)
      || jsonb_build_object('_advanced', v_applied),
    v_rows,
    (v_audit_after - v_audit_before)::int);

  RETURN v_run;
END; $function$;

-- 3. WS45-01 asserted audit_rows_written = 0 across every sweep log row. That invariant
--    was about the PREVIEW harness, which is still preview-only by construction. Now that
--    APPLY rows land in the same table, scope the zero-write rule to the rows it was
--    always about, and assert the mode vocabulary so a third mode cannot slip in
--    unexamined. The guarantee is unchanged; it is now stated precisely.
create or replace function public.ws45_sweep_harness_liveness_check(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_active boolean; v_sched text;
  v_log_rows int; v_preview_rows int; v_last timestamptz; v_age_hours numeric;
  v_preview_audit bigint; v_bad_modes int;
  v_failed int := null; v_last_fail jsonb := '[]'::jsonb;
  v_cron_readable boolean := true;
  v_stale boolean; v_verdict text; v_severity text; v_observed text;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE mode = 'PREVIEW'),
         max(ran_at) FILTER (WHERE mode = 'PREVIEW'),
         coalesce(sum(audit_rows_written) FILTER (WHERE mode = 'PREVIEW'),0),
         count(*) FILTER (WHERE mode NOT IN ('PREVIEW','APPLY'))
    INTO v_log_rows, v_preview_rows, v_last, v_preview_audit, v_bad_modes
  FROM m2m_cycle_sweep_log;

  v_age_hours := round((extract(epoch FROM (now() - v_last)) / 3600.0)::numeric, 2);

  BEGIN
    SELECT j.active, j.schedule INTO v_active, v_sched
      FROM cron.job j WHERE j.jobname = 'm2m_cycle_sweep_preview_daily';

    SELECT count(*) INTO v_failed
      FROM cron.job_run_details d
      JOIN cron.job j ON j.jobid = d.jobid
     WHERE j.jobname = 'm2m_cycle_sweep_preview_daily'
       AND d.status <> 'succeeded'
       AND d.start_time > now() - interval '48 hours';

    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'start', d.start_time, 'status', d.status,
             'message', left(d.return_message, 400))), '[]'::jsonb)
      INTO v_last_fail
      FROM cron.job_run_details d
      JOIN cron.job j ON j.jobid = d.jobid
     WHERE j.jobname = 'm2m_cycle_sweep_preview_daily'
       AND d.status <> 'succeeded'
       AND d.start_time > now() - interval '48 hours';
  EXCEPTION WHEN others THEN
    v_cron_readable := false;
  END;

  -- 26 hours, not 24: a daily job plus clock drift must not read as stale.
  v_stale := (v_last IS NULL OR v_age_hours > 26);

  v_observed :=
    v_preview_rows||' preview rows of '||v_log_rows||' total; newest preview '||
    coalesce(v_last::text,'never')||' ('||coalesce(v_age_hours::text,'n/a')||'h old); '||
    'preview audit_rows_written total '||v_preview_audit||
    CASE WHEN v_bad_modes > 0 THEN '; '||v_bad_modes||' rows with an unrecognised mode' ELSE '' END||
    CASE WHEN v_cron_readable
         THEN '; cron job active='||coalesce(v_active::text,'absent')||
              ', failed runs in 48h='||coalesce(v_failed::text,'0')
         ELSE '; cron.job_run_details not readable from this role' END;

  v_verdict := CASE
    WHEN NOT v_cron_readable AND v_stale THEN 'UNVERIFIABLE'
    WHEN v_preview_audit <> 0              THEN 'DEVIATION'
    WHEN v_bad_modes > 0                   THEN 'DEVIATION'
    WHEN coalesce(v_failed,0) > 0          THEN 'DEVIATION'
    WHEN v_stale                           THEN 'DEVIATION'
    WHEN coalesce(v_active,false) = false  THEN 'DEVIATION'
    ELSE 'CONFORM' END;

  v_severity := CASE
    WHEN v_preview_audit <> 0 OR v_bad_modes > 0 THEN 'BLOCKING'
    WHEN v_verdict = 'CONFORM' THEN 'INFO'
    WHEN v_verdict = 'UNVERIFIABLE' THEN 'MEDIUM'
    ELSE 'HIGH' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'platform','WS45-01',
    'Is the cycle sweep PREVIEW harness still running, still writing its own receipt, and still writing nothing else?',
    'a preview row newer than 26 hours, zero failed cron runs in 48 hours, job active, audit_rows_written 0 across every PREVIEW row, and no mode outside PREVIEW/APPLY',
    v_observed,
    v_verdict, v_severity,
    jsonb_build_object(
      'sweep_log_rows_total', v_log_rows,
      'preview_rows', v_preview_rows,
      'newest_preview', v_last,
      'age_hours', v_age_hours,
      'stale', v_stale,
      'cron_active', v_active,
      'cron_schedule', v_sched,
      'cron_readable', v_cron_readable,
      'failed_runs_48h', v_failed,
      'failed_run_detail', v_last_fail,
      'preview_audit_rows_written_total', v_preview_audit,
      'unrecognised_mode_rows', v_bad_modes,
      'why','On 2026-08-23 at 14:00 the sweep aborted on a unique-constraint collision in its metrics INSERT. Because that INSERT runs ahead of the sweep log INSERT in the same transaction, the failure erased its own receipt: the log simply stopped gaining rows and nothing raised. Absence of a row is not a signal anyone watches. This check makes it one.',
      'scope_note','This check governs the PREVIEW path only. On 2026-08-27 an APPLY path was wired into the same log table; its writes are legitimate and are judged by WS46-01, not here. The preview zero-write guarantee is unchanged -- it is now scoped to the rows it was always about, rather than to every row in the table.',
      'read_from','public.m2m_cycle_sweep_log and cron.job / cron.job_run_details'),
    jsonb_build_object('universe','every m2m_cycle_sweep_log row, plus every cron run of m2m_cycle_sweep_preview_daily in the last 48 hours',
      'universe_count', v_log_rows, 'examined_count', v_log_rows, 'method','FULL',
      'source','public.m2m_cycle_sweep_log x cron.job x cron.job_run_details',
      'excluded','none; APPLY rows are examined and counted, and excluded from the zero-write rule only'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- 4. WS46-01 governs the applier. It judges only transitions the machine actually made --
--    CYCLE_STAGE_ADVANCE events in loop_audit_trail -- so the 190 legacy stage 9 rows,
--    which predate the applier and were never advanced by it, are outside its scope.
create or replace function public.ws46_cycle_applier_integrity_check(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_advances int; v_universe int;
  v_unbacked int; v_unauth int; v_skipped int;
  v_failed int := null; v_cron_readable boolean := true; v_active boolean;
  v_detail jsonb; v_verdict text; v_severity text;
BEGIN
  SELECT count(*) INTO v_advances
    FROM loop_audit_trail WHERE event_type = 'CYCLE_STAGE_ADVANCE';
  v_universe := v_advances;

  -- Advanced INTO stage 8 while the loop's TRUST verdict had no judge_verdicts row.
  SELECT count(*) INTO v_unbacked
    FROM loop_audit_trail a
    JOIN loop_executions l ON l.id = a.loop_id
   WHERE a.event_type = 'CYCLE_STAGE_ADVANCE'
     AND (a.detail->>'to_stage')::int >= 8
     AND l.last_gate_verdict = 'TRUST'
     AND l.verdict_id IS NULL
     AND NOT EXISTS (SELECT 1 FROM judge_verdicts j WHERE j.loop_id = l.id);

  -- Advanced INTO stage 9 without Founder authentication. m2m_cycle_advance refuses this
  -- outright; the check exists so the refusal is proven rather than asserted.
  SELECT count(*) INTO v_unauth
    FROM loop_audit_trail a
    JOIN loop_executions l ON l.id = a.loop_id
   WHERE a.event_type = 'CYCLE_STAGE_ADVANCE'
     AND (a.detail->>'to_stage')::int = 9
     AND NOT coalesce(l.fl_ii_authenticated, false);

  -- Loops the applier declined, and why. Not a fault: this is the record of what the
  -- guards actually stopped, and it is the evidence that they run.
  SELECT count(*) INTO v_skipped
    FROM loop_executions l
   WHERE l.cycle_stage IS NOT NULL AND l.cycle_stage < 9
     AND (SELECT t.verdict FROM public.m2m_cycle_exit_test(l.id) t) <> 'MET';

  BEGIN
    SELECT j.active INTO v_active FROM cron.job j WHERE j.jobname = 'm2m_cycle_sweep_apply_daily';
    SELECT count(*) INTO v_failed
      FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
     WHERE j.jobname = 'm2m_cycle_sweep_apply_daily'
       AND d.status <> 'succeeded' AND d.start_time > now() - interval '48 hours';
  EXCEPTION WHEN others THEN
    v_cron_readable := false;
  END;

  SELECT coalesce(jsonb_object_agg(v, n), '{}'::jsonb) INTO v_detail
  FROM (SELECT (SELECT t.verdict FROM public.m2m_cycle_exit_test(l.id) t) AS v, count(*) AS n
          FROM loop_executions l
         WHERE l.cycle_stage IS NOT NULL AND l.cycle_stage < 9
         GROUP BY 1) d;

  v_verdict := CASE
    WHEN v_unauth > 0 OR v_unbacked > 0 THEN 'DEVIATION'
    WHEN coalesce(v_failed,0) > 0       THEN 'DEVIATION'
    ELSE 'CONFORM' END;

  v_severity := CASE
    WHEN v_unauth > 0 THEN 'BLOCKING'
    WHEN v_unbacked > 0 THEN 'BLOCKING'
    WHEN v_verdict = 'CONFORM' THEN 'INFO'
    ELSE 'HIGH' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'governance','WS46-01',
    'Has the cycle applier ever advanced a loop on evidence that does not exist, or across the Founder boundary?',
    '0 advances into stage 8 or beyond on an unbacked TRUST verdict, 0 advances into stage 9 without Founder authentication, and 0 failed apply runs in 48 hours',
    v_advances||' machine advances recorded; '||v_unbacked||' on an unbacked verdict; '||
      v_unauth||' across the Founder boundary; '||v_skipped||' eligible loops currently declined by the exit test'||
      CASE WHEN v_cron_readable
           THEN '; apply job active='||coalesce(v_active::text,'absent')||', failed runs in 48h='||coalesce(v_failed::text,'0')
           ELSE '; cron.job_run_details not readable from this role' END,
    v_verdict, v_severity,
    jsonb_build_object(
      'machine_advances', v_advances,
      'unbacked_verdict_advances', v_unbacked,
      'founder_boundary_crossings', v_unauth,
      'declined_now', v_skipped,
      'declined_by_verdict', v_detail,
      'apply_cron_active', v_active,
      'apply_failed_runs_48h', v_failed,
      'why','Apply mode existed in m2m_cycle_advance from the start and had never been invoked: loop_audit_trail held 0 CYCLE_STAGE_ADVANCE events before 2026-08-27. Enabling it unmodified would have advanced loop 6e798ad1 from stage 7 to 8 on a TRUST verdict with no judge_verdicts row behind it. The stage 7 exit test was tightened to BLOCKED_UNBACKED_VERDICT before apply was wired.',
      'boundary','m2m_cycle_advance refuses stage 8 to 9 without fl_ii_authenticated under any argument. That refusal is the FL/II line and this check proves it holds rather than asserting it.',
      'declined_is_not_a_fault','Loops sitting at NO_INSTRUMENTATION or BLOCKED_ are the guards working. Stages 2, 3 and 6 have no recorded exit signal at all, so the applier cannot move a loop past stage 2 today. That is a design gap in the cycle, not a defect in the applier.'),
    jsonb_build_object('universe','every CYCLE_STAGE_ADVANCE event in loop_audit_trail, plus every loop currently below stage 9',
      'universe_count', v_universe, 'examined_count', v_universe, 'method','FULL',
      'source','public.loop_audit_trail x public.loop_executions x public.judge_verdicts x cron',
      'excluded','loops that reached stage 9 before the applier was wired; they carry no advance event and were not the machine''s doing'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- 5. Schedule. 14:30, after the 14:00 preview, so each day's log carries the preview
--    measurement and then the apply that acted on it.
--    Applied live as: select cron.schedule('m2m_cycle_sweep_apply_daily', '30 14 * * *',
--                       $$select public.m2m_cycle_sweep_apply(100);$$);
--    and WS46-01 appended to the ws10_conformance_daily command via cron.alter_job.
do $wire$
declare v_id bigint; v_cmd text;
begin
  if not exists (select 1 from cron.job where jobname = 'm2m_cycle_sweep_apply_daily') then
    perform cron.schedule('m2m_cycle_sweep_apply_daily', '30 14 * * *',
                          $$select public.m2m_cycle_sweep_apply(100);$$);
  end if;

  select jobid, command into v_id, v_cmd from cron.job where jobname = 'ws10_conformance_daily';
  if v_id is null then raise notice 'ws10_conformance_daily not found; skipping wire'; return; end if;
  if v_cmd ilike '%ws46_cycle_applier_integrity_check%' then raise notice 'ws46 already wired'; return; end if;
  perform cron.alter_job(v_id, command => replace(v_cmd,
    'perform public.ws45_sweep_harness_liveness_check(v);',
    'perform public.ws45_sweep_harness_liveness_check(v);'||chr(10)||
    '  perform public.ws46_cycle_applier_integrity_check(v);'));
end $wire$;
