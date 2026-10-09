-- MY DEFECT. WS45-01 read DEVIATION/BLOCKING on 2026-09-27 claiming the preview-only
-- contract had broken: "preview audit_rows_written total 5". It had not.
--
-- Exactly one PREVIEW row is non-zero: 2026-09-24 14:00:00.324301, audit_rows_written 5.
-- The five rows in loop_audit_trail at that moment are all event_type STATUS_CHANGE,
-- actor 'system', sharing the identical timestamp 14:00:00.321871 -- one statement-level
-- trigger firing on five loops, 2.5 MILLISECONDS before the sweep took its "after" count.
--
-- Root cause is in my own code. m2m_cycle_sweep_preview computed audit_rows_written as a
-- naive before/after count over the WHOLE loop_audit_trail table. That measures "rows that
-- appeared while the sweep ran", not "rows this function wrote". Any concurrent writer
-- inside the run's few milliseconds is attributed to the sweep.
--
-- I also overstated the check in its own evidence text: "a non-zero total means something
-- rewired it to apply, which is a governance breach and not merely a bug." That was too
-- strong, and it is what turned a measurement artifact into a BLOCKING alarm. This is the
-- same class WS50 found in WS31-01 -- a check matching the wrong thing -- except I wrote
-- this one.
--
-- Fix: count only CYCLE_STAGE_ADVANCE events. public.m2m_cycle_advance is the sole writer
-- of that event_type (verified against pg_proc: only m2m_cycle_advance writes it;
-- ws46_cycle_applier_integrity_check merely reads it). A preview that somehow applied
-- would emit exactly those rows, so the guard keeps its teeth and loses the false positive.
--
-- The historical row is NOT rewritten. A recorded measurement that was wrong is part of the
-- record; WS45-01 instead carries a watermark and excludes pre-fix PREVIEW rows from the
-- verdict while still printing them -- the same treatment WS44-01 gives the 119 historical
-- verdicts.
-- Ledgered SEL-20260927-277FEC44.

-- 1. Scope the counter in the preview path.
create or replace function public.m2m_cycle_sweep_preview(p_limit integer default 100)
 returns uuid language plpgsql security definer set search_path to 'public'
as $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_rows jsonb; v_n int;
  v_eligible int; v_unclassified int;
  v_audit_before bigint; v_audit_after bigint;
  v_run_index int; v_metrics int := 0;
  v_metrics_error text := null;
BEGIN
  -- Count ONLY the event the applier writes. A whole-table count attributes any
  -- concurrent writer's rows to this run; that produced a false BLOCKING on 2026-09-24.
  SELECT count(*) INTO v_audit_before
    FROM loop_audit_trail WHERE event_type = 'CYCLE_STAGE_ADVANCE';
  SELECT count(*) + 1 INTO v_run_index FROM m2m_cycle_sweep_log;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'loop_id', s.loop_id, 'from_stage', s.from_stage,
           'verdict', s.verdict, 'applied', s.applied)), '[]'::jsonb),
         count(*)
    INTO v_rows, v_n
  FROM public.m2m_cycle_sweep(false, p_limit) s;   -- false is not a parameter of this function

  SELECT count(*) FILTER (WHERE cycle_stage IS NOT NULL AND cycle_stage < 9),
         count(*) FILTER (WHERE cycle_stage IS NULL)
    INTO v_eligible, v_unclassified
  FROM loop_executions;

  BEGIN
    INSERT INTO m2m_loop_metrics (
      loop_name, run_index, loop_execution_id, metric_name, metric_value,
      ground_truth_window, sufficient_data, evaluator, evaluator_notes)
    SELECT l.loop_name, v_run_index, l.id, 'stage_dwell_days',
           round((extract(epoch FROM (now() - l.updated_at)) / 86400.0)::numeric, 4),
           'instantaneous at sweep time', true, 'm2m_cycle_sweep_preview',
           'Stage '||l.cycle_stage||' ('||coalesce(cs.stage_key,'?')||'). Sweep run '||v_run::text||
           '. Rising dwell across runs means the loop is stuck at this stage.'
    FROM loop_executions l
    LEFT JOIN m2m_cycle_stage cs ON cs.stage_no = l.cycle_stage
    WHERE l.cycle_stage IS NOT NULL AND l.cycle_stage < 9
    ON CONFLICT (loop_execution_id, run_index, metric_name) DO NOTHING;
    GET DIAGNOSTICS v_metrics = ROW_COUNT;
  EXCEPTION WHEN others THEN
    v_metrics := 0;
    v_metrics_error := SQLSTATE||': '||SQLERRM;
  END;

  SELECT count(*) INTO v_audit_after
    FROM loop_audit_trail WHERE event_type = 'CYCLE_STAGE_ADVANCE';

  INSERT INTO m2m_cycle_sweep_log(
    run_id, mode, limit_used, candidates, eligible_now, unclassified_now,
    verdict_counts, results, audit_rows_written)
  VALUES (
    v_run, 'PREVIEW', p_limit, v_n, v_eligible, v_unclassified,
    (SELECT coalesce(jsonb_object_agg(v, c), '{}'::jsonb)
       FROM (SELECT r->>'verdict' AS v, count(*) AS c
               FROM jsonb_array_elements(v_rows) r GROUP BY 1) q)
      || jsonb_build_object('_metrics_emitted', v_metrics)
      || CASE WHEN v_metrics_error IS NULL THEN '{}'::jsonb
              ELSE jsonb_build_object('_metrics_error', v_metrics_error) END,
    v_rows,
    (v_audit_after - v_audit_before)::int);

  RETURN v_run;
END; $function$;

-- 2. Same scoping in the apply path, so both modes measure the same thing.
create or replace function public.m2m_cycle_sweep_apply(p_limit integer default 100)
 returns uuid language plpgsql security definer set search_path to 'public'
as $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_rows jsonb; v_n int; v_applied int;
  v_eligible int; v_unclassified int;
  v_audit_before bigint; v_audit_after bigint;
BEGIN
  SELECT count(*) INTO v_audit_before
    FROM loop_audit_trail WHERE event_type = 'CYCLE_STAGE_ADVANCE';

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

  SELECT count(*) INTO v_audit_after
    FROM loop_audit_trail WHERE event_type = 'CYCLE_STAGE_ADVANCE';

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

-- 3. WS45-01: judge the zero-write rule only on PREVIEW rows written after the counter was
--    corrected. Pre-watermark rows are still counted and printed, never hidden.
--    corrected. Pre-watermark rows are still counted and printed, never hidden.
create or replace function public.ws45_sweep_harness_liveness_check(p_run_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
DECLARE
  v_fix constant timestamptz := timestamptz '2026-09-27 12:00:00+00';
  v_active boolean; v_sched text;
  v_log_rows int; v_preview_rows int; v_last timestamptz; v_age_hours numeric;
  v_audit_post bigint; v_audit_pre bigint; v_bad_modes int;
  v_failed int := null; v_last_fail jsonb := '[]'::jsonb;
  v_cron_readable boolean := true;
  v_stale boolean; v_verdict text; v_severity text; v_observed text;
BEGIN
  SELECT count(*), count(*) FILTER (WHERE mode = 'PREVIEW'),
         max(ran_at) FILTER (WHERE mode = 'PREVIEW'),
         coalesce(sum(audit_rows_written) FILTER (WHERE mode = 'PREVIEW' AND ran_at >  v_fix),0),
         coalesce(sum(audit_rows_written) FILTER (WHERE mode = 'PREVIEW' AND ran_at <= v_fix),0),
         count(*) FILTER (WHERE mode NOT IN ('PREVIEW','APPLY'))
    INTO v_log_rows, v_preview_rows, v_last, v_audit_post, v_audit_pre, v_bad_modes
  FROM m2m_cycle_sweep_log;

  v_age_hours := round((extract(epoch FROM (now() - v_last)) / 3600.0)::numeric, 2);

  BEGIN
    SELECT j.active, j.schedule INTO v_active, v_sched
      FROM cron.job j WHERE j.jobname = 'm2m_cycle_sweep_preview_daily';
    SELECT count(*) INTO v_failed
      FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
     WHERE j.jobname = 'm2m_cycle_sweep_preview_daily'
       AND d.status <> 'succeeded' AND d.start_time > now() - interval '48 hours';
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'start', d.start_time, 'status', d.status, 'message', left(d.return_message, 400))), '[]'::jsonb)
      INTO v_last_fail
      FROM cron.job_run_details d JOIN cron.job j ON j.jobid = d.jobid
     WHERE j.jobname = 'm2m_cycle_sweep_preview_daily'
       AND d.status <> 'succeeded' AND d.start_time > now() - interval '48 hours';
  EXCEPTION WHEN others THEN
    v_cron_readable := false;
  END;

  v_stale := (v_last IS NULL OR v_age_hours > 26);

  v_observed :=
    v_preview_rows||' preview rows of '||v_log_rows||' total; newest preview '||
    coalesce(v_last::text,'never')||' ('||coalesce(v_age_hours::text,'n/a')||'h old); '||
    'preview advance-events written since the 2026-09-27 counter fix: '||v_audit_post||
    ' (pre-fix total '||v_audit_pre||', measured by the old whole-table counter and excluded from the verdict)'||
    CASE WHEN v_bad_modes > 0 THEN '; '||v_bad_modes||' rows with an unrecognised mode' ELSE '' END||
    CASE WHEN v_cron_readable
         THEN '; cron job active='||coalesce(v_active::text,'absent')||', failed runs in 48h='||coalesce(v_failed::text,'0')
         ELSE '; cron.job_run_details not readable from this role' END;

  v_verdict := CASE
    WHEN NOT v_cron_readable AND v_stale THEN 'UNVERIFIABLE'
    WHEN v_audit_post <> 0                 THEN 'DEVIATION'
    WHEN v_bad_modes > 0                   THEN 'DEVIATION'
    WHEN coalesce(v_failed,0) > 0          THEN 'DEVIATION'
    WHEN v_stale                           THEN 'DEVIATION'
    WHEN coalesce(v_active,false) = false  THEN 'DEVIATION'
    ELSE 'CONFORM' END;

  v_severity := CASE
    WHEN v_audit_post <> 0 OR v_bad_modes > 0 THEN 'BLOCKING'
    WHEN v_verdict = 'CONFORM' THEN 'INFO'
    WHEN v_verdict = 'UNVERIFIABLE' THEN 'MEDIUM'
    ELSE 'HIGH' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'platform','WS45-01',
    'Is the cycle sweep PREVIEW harness still running, still writing its own receipt, and still applying nothing?',
    'a preview row newer than 26 hours, zero failed cron runs in 48 hours, job active, zero CYCLE_STAGE_ADVANCE events from any post-fix PREVIEW run, and no mode outside PREVIEW/APPLY',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'sweep_log_rows_total', v_log_rows, 'preview_rows', v_preview_rows,
      'newest_preview', v_last, 'age_hours', v_age_hours, 'stale', v_stale,
      'cron_active', v_active, 'cron_schedule', v_sched, 'cron_readable', v_cron_readable,
      'failed_runs_48h', v_failed, 'failed_run_detail', v_last_fail,
      'preview_advance_events_post_fix', v_audit_post,
      'preview_rows_written_pre_fix_old_counter', v_audit_pre,
      'counter_fix_watermark', v_fix,
      'why','On 2026-08-23 the sweep aborted on a unique-constraint collision in its metrics INSERT, ahead of the sweep-log INSERT in the same transaction, so the failure erased its own receipt. Absence of a row is not a signal anyone watches. This check makes it one.',
      'correction','Until 2026-09-27 this check counted EVERY row appearing in loop_audit_trail during a run, not the rows the run wrote. On 2026-09-24 five STATUS_CHANGE rows from an unrelated statement-level trigger landed 2.5ms before the preview took its after-count, and this check reported BLOCKING -- a governance breach that had not occurred. The counter now counts only CYCLE_STAGE_ADVANCE, which public.m2m_cycle_advance alone writes. Pre-fix PREVIEW totals are printed above and excluded from the verdict rather than rewritten, because a recorded measurement that was wrong is part of the record.',
      'read_from','public.m2m_cycle_sweep_log and cron.job / cron.job_run_details'),
    jsonb_build_object('universe','every m2m_cycle_sweep_log row, plus every cron run of m2m_cycle_sweep_preview_daily in the last 48 hours',
      'universe_count', v_log_rows, 'examined_count', v_log_rows, 'method','FULL',
      'source','public.m2m_cycle_sweep_log x cron.job x cron.job_run_details',
      'excluded','none; APPLY rows and pre-fix PREVIEW rows are examined and printed, and excluded from the zero-write rule only'),
    (v_verdict <> 'CONFORM'));
END; $function$;
