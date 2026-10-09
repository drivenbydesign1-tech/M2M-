-- Wire m2m_loop_metrics, which has been empty since it was created.
--
-- Finding SEL-20260822-1BD26D3B: the table has columns for metric value, baseline,
-- ground-truth window, sufficiency and evaluator -- a considered measurement layer
-- that never received a row. Without it there is no way to answer whether a loop
-- improved after a change, and the learning-feedback item in the semantic packet
-- has nowhere to land.
--
-- The metric chosen is one that can be measured today rather than one that waits on
-- apply mode being enabled: stage_dwell_days, how long each eligible loop has sat at
-- its current cycle stage. It answers the question the review actually raised --
-- are loops stuck -- and it accrues a row per eligible loop per daily sweep, so a
-- baseline builds without anyone doing anything.
--
-- Emission is inside the preview wrapper rather than inside m2m_cycle_advance,
-- deliberately: advance is on the critical path of state change and should not also
-- own measurement. Nothing about the sweep's inert-ness changes -- writing a metric
-- row is not advancing a loop -- but the audit-trail delta guard still covers the
-- part that matters, and metric rows are counted separately.
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
  WHERE l.cycle_stage IS NOT NULL AND l.cycle_stage < 9;
  GET DIAGNOSTICS v_metrics = ROW_COUNT;

  SELECT count(*) INTO v_audit_after FROM loop_audit_trail;

  INSERT INTO m2m_cycle_sweep_log(
    run_id, mode, limit_used, candidates, eligible_now, unclassified_now,
    verdict_counts, results, audit_rows_written)
  VALUES (
    v_run, 'PREVIEW', p_limit, v_n, v_eligible, v_unclassified,
    (SELECT coalesce(jsonb_object_agg(v, c), '{}'::jsonb)
       FROM (SELECT r->>'verdict' AS v, count(*) AS c
               FROM jsonb_array_elements(v_rows) r GROUP BY 1) q)
      || jsonb_build_object('_metrics_emitted', v_metrics),
    v_rows,
    (v_audit_after - v_audit_before)::int);

  RETURN v_run;
END; $function$;

comment on function public.m2m_cycle_sweep_preview(integer) is
  'Scheduled entry point for the nine-stage cycle sweep. Runs m2m_cycle_sweep with p_apply hard-coded false, emits a stage_dwell_days metric per eligible loop into m2m_loop_metrics, and records the outcome to m2m_cycle_sweep_log. Cannot advance a loop. Enabling apply requires a separate migration and a Founder decision.';

revoke execute on function public.m2m_cycle_sweep_preview(integer) from anon, public;
