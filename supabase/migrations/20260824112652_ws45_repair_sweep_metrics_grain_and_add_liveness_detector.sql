-- The 2026-08-23 14:00 sweep aborted with:
--   duplicate key value violates unique constraint
--   "m2m_loop_metrics_loop_name_run_index_metric_name_key"
--   Key (loop_name, run_index, metric_name)=(CEO Dashboard Briefing, 4, stage_dwell_days)
--
-- Cause: m2m_loop_metrics is keyed on loop_execution_id, but its unique key was
-- (loop_name, run_index, metric_name). Two distinct executions sharing a loop_name
-- -- which is the normal case for a daily cron loop -- collide inside one sweep's
-- multi-row INSERT. It passed on 2026-08-22 only because exactly one eligible loop
-- carried a non-null cycle_stage at that moment. The metrics INSERT sits ahead of
-- the m2m_cycle_sweep_log INSERT in the same function, so the abort also destroyed
-- the sweep's own receipt: the harness failed silently and left no row saying so.
--
-- Reversible order: add the correct key, verify, then drop the wrong one, then
-- constrain, then repair the writer, then ship the detector.

-- 1. Add the correct grain. One measurement per execution per metric per sweep.
create unique index if not exists m2m_loop_metrics_exec_run_metric_key
  on public.m2m_loop_metrics (loop_execution_id, run_index, metric_name);

-- 2. Verify satisfiable before loosening or tightening anything.
do $v$
declare v_null int; v_dupe int;
begin
  select count(*) into v_null from public.m2m_loop_metrics where loop_execution_id is null;
  select count(*) into v_dupe from (
    select 1 from public.m2m_loop_metrics
     group by loop_execution_id, run_index, metric_name having count(*) > 1) d;
  if v_null > 0 or v_dupe > 0 then
    raise exception 'refusing to re-key m2m_loop_metrics: % null loop_execution_id, % duplicate groups', v_null, v_dupe;
  end if;
end $v$;

-- 3. Drop the wrong key.
alter table public.m2m_loop_metrics
  drop constraint if exists m2m_loop_metrics_loop_name_run_index_metric_name_key;

-- 4. Make the new key binding. NULL loop_execution_id would make it vacuous.
alter table public.m2m_loop_metrics
  alter column loop_execution_id set not null;

-- 5. Repair the writer. Two changes:
--    a. ON CONFLICT DO NOTHING, so a measurement collision can never again abort
--       the sweep and destroy its own receipt.
--    b. the metrics block is wrapped so that ANY failure inside it is recorded in
--       the sweep log rather than replacing it. A measurement side effect must
--       never be able to take down the thing it measures.
create or replace function public.m2m_cycle_sweep_preview(p_limit integer default 100)
 returns uuid
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_run uuid := gen_random_uuid();
  v_rows jsonb; v_n int;
  v_eligible int; v_unclassified int;
  v_audit_before bigint; v_audit_after bigint;
  v_run_index int; v_metrics int := 0;
  v_metrics_error text := null;
BEGIN
  SELECT count(*) INTO v_audit_before FROM loop_audit_trail;
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

  -- Measurement: how long has each eligible loop sat where it is?
  BEGIN
    INSERT INTO m2m_loop_metrics (
      loop_name, run_index, loop_execution_id, metric_name, metric_value,
      ground_truth_window, sufficient_data, evaluator, evaluator_notes)
    SELECT l.loop_name,
           v_run_index,
           l.id,
           'stage_dwell_days',
           round((extract(epoch FROM (now() - l.updated_at)) / 86400.0)::numeric, 4),
           'instantaneous at sweep time',
           true,
           'm2m_cycle_sweep_preview',
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

  SELECT count(*) INTO v_audit_after FROM loop_audit_trail;

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

-- 6. The detector. WS45-01 exists because nothing noticed for 21 hours that the
--    harness had stopped. A scheduled job that fails leaves its evidence in
--    cron.job_run_details, not in the table it was supposed to write, so the
--    check has to look at both.
create or replace function public.ws45_sweep_harness_liveness_check(p_run_id uuid)
 returns void
 language plpgsql
 security definer
 set search_path to 'public'
as $function$
DECLARE
  v_active boolean; v_sched text;
  v_log_rows int; v_last timestamptz; v_age_hours numeric;
  v_audit_total bigint;
  v_failed int := null; v_last_fail jsonb := '[]'::jsonb;
  v_cron_readable boolean := true;
  v_stale boolean; v_verdict text; v_severity text; v_observed text;
BEGIN
  SELECT count(*), max(ran_at), coalesce(sum(audit_rows_written),0)
    INTO v_log_rows, v_last, v_audit_total
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
    v_log_rows||' sweep log rows; newest '||coalesce(v_last::text,'never')||
    ' ('||coalesce(v_age_hours::text,'n/a')||'h old); audit_rows_written total '||v_audit_total||
    CASE WHEN v_cron_readable
         THEN '; cron job active='||coalesce(v_active::text,'absent')||
              ', failed runs in 48h='||coalesce(v_failed::text,'0')
         ELSE '; cron.job_run_details not readable from this role' END;

  v_verdict := CASE
    WHEN NOT v_cron_readable AND v_stale THEN 'UNVERIFIABLE'
    WHEN v_audit_total <> 0                THEN 'DEVIATION'
    WHEN coalesce(v_failed,0) > 0          THEN 'DEVIATION'
    WHEN v_stale                           THEN 'DEVIATION'
    WHEN coalesce(v_active,false) = false  THEN 'DEVIATION'
    ELSE 'CONFORM' END;

  v_severity := CASE
    WHEN v_audit_total <> 0 THEN 'BLOCKING'
    WHEN v_verdict = 'CONFORM' THEN 'INFO'
    WHEN v_verdict = 'UNVERIFIABLE' THEN 'MEDIUM'
    ELSE 'HIGH' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'platform','WS45-01',
    'Is the cycle sweep harness still running, still writing its own receipt, and still honouring its read-only contract?',
    'a sweep log row newer than 26 hours, zero failed cron runs in 48 hours, job active, and audit_rows_written 0 across every run',
    v_observed,
    v_verdict, v_severity,
    jsonb_build_object(
      'sweep_log_rows', v_log_rows,
      'newest_run', v_last,
      'age_hours', v_age_hours,
      'stale', v_stale,
      'cron_active', v_active,
      'cron_schedule', v_sched,
      'cron_readable', v_cron_readable,
      'failed_runs_48h', v_failed,
      'failed_run_detail', v_last_fail,
      'audit_rows_written_total', v_audit_total,
      'why','On 2026-08-23 at 14:00 the sweep aborted on a unique-constraint collision in its metrics INSERT. Because that INSERT runs ahead of the sweep log INSERT in the same transaction, the failure erased its own receipt: the log simply stopped gaining rows and nothing raised. Absence of a row is not a signal anyone watches. This check makes it one.',
      'second_signal','audit_rows_written must stay 0 forever. The harness is preview-only by construction -- m2m_cycle_sweep(false, ...) is hardcoded -- so a non-zero total means something rewired it to apply, which is a governance breach and not merely a bug.',
      'read_from','public.m2m_cycle_sweep_log and cron.job / cron.job_run_details'),
    jsonb_build_object('universe','every m2m_cycle_sweep_log row, plus every cron run of m2m_cycle_sweep_preview_daily in the last 48 hours',
      'universe_count', v_log_rows, 'examined_count', v_log_rows, 'method','FULL',
      'source','public.m2m_cycle_sweep_log x cron.job x cron.job_run_details',
      'excluded','none'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- 7. Wire WS45-01 into the daily conformance battery (applied via cron.alter_job
--    on jobid for 'ws10_conformance_daily'; recorded here for provenance).
--    The battery runs 13:00, the sweep 14:00, so WS45-01 reads the prior day's
--    run at an age of ~23h -- inside the 26h window by design.
do $wire$
declare v_id bigint;
begin
  select jobid into v_id from cron.job where jobname = 'ws10_conformance_daily';
  if v_id is null then raise notice 'ws10_conformance_daily not found; skipping wire'; return; end if;
  if (select command from cron.job where jobid = v_id) ilike '%ws45_sweep_harness_liveness_check%' then
    raise notice 'ws45 already wired'; return;
  end if;
  perform cron.alter_job(v_id, command =>
    replace((select command from cron.job where jobid = v_id),
            'perform public.ws44_gate_verdict_provenance_check(v);',
            'perform public.ws44_gate_verdict_provenance_check(v);'||chr(10)||
            '  perform public.ws45_sweep_harness_liveness_check(v);'));
end $wire$;
