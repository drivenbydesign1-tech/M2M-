-- WS44-01. Gate verdict provenance.
--
-- Finding SEL-20260822-1BD26D3B: judge_verdicts holds zero rows, yet 119 loops
-- carry last_gate_verdict = 'TRUST' and not one has a verdict_id. The verdict is
-- asserted directly on the loop and the evidence table it should point to was
-- never written. Every individual row is accurate; the composite claim -- that
-- this work passed the judge -- cannot be substantiated.
--
-- A second signal in the same data: of 119 verdicts, 119 are TRUST. The enum also
-- offers MARGINAL and LIABILITY and neither has ever been recorded. A gate that
-- has only ever returned its pass value is the shape of a control that is not
-- controlling, so the distribution travels with the finding as evidence.
--
-- Resolution is a Founder decision and this detector deliberately takes no side.
-- Either update_loop_from_prometheus is wired to write judge_verdicts and set
-- verdict_id, or last_gate_verdict stops being written. A verdict with no record
-- behind it should not remain a third option. Until that is decided, this check
-- makes the gap permanent and visible instead of dormant.
--
-- The 119 existing rows are ACCEPTED, not judged: retro-writing judge_verdicts for
-- them would fabricate judgements nobody made. The verdict therefore rests only on
-- loops created after the 2026-08-22 watermark, so the check can reach CONFORM by
-- the platform behaving correctly from here rather than by anyone rewriting history.
create or replace function public.ws44_gate_verdict_provenance_check(p_run_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_watermark constant timestamptz := timestamptz '2026-08-22 12:00:00+00';
  v_universe int; v_accepted int; v_new_total int; v_new_unbacked int;
  v_judge_rows int; v_dist jsonb; v_sample jsonb;
BEGIN
  SELECT count(*) INTO v_universe FROM loop_executions WHERE last_gate_verdict IS NOT NULL;
  SELECT count(*) INTO v_judge_rows FROM judge_verdicts;

  SELECT coalesce(jsonb_object_agg(v, n), '{}'::jsonb) INTO v_dist
  FROM (SELECT last_gate_verdict::text AS v, count(*) AS n
          FROM loop_executions WHERE last_gate_verdict IS NOT NULL GROUP BY 1) d;

  -- Backed means either direction of the link resolves to a real judge row.
  SELECT
    count(*) FILTER (WHERE created_at <= v_watermark),
    count(*) FILTER (WHERE created_at >  v_watermark),
    count(*) FILTER (WHERE created_at >  v_watermark AND NOT backed)
    INTO v_accepted, v_new_total, v_new_unbacked
  FROM (
    SELECT l.created_at,
           (l.verdict_id IS NOT NULL
              AND EXISTS (SELECT 1 FROM judge_verdicts j WHERE j.id = l.verdict_id))
           OR EXISTS (SELECT 1 FROM judge_verdicts j2 WHERE j2.loop_id = l.id) AS backed
    FROM loop_executions l
    WHERE l.last_gate_verdict IS NOT NULL) x;

  SELECT coalesce(jsonb_agg(jsonb_build_object('loop', id, 'verdict', last_gate_verdict,
                                               'created', created_at)), '[]'::jsonb)
    INTO v_sample
  FROM (SELECT id, last_gate_verdict, created_at FROM loop_executions
         WHERE last_gate_verdict IS NOT NULL AND created_at > v_watermark
           AND verdict_id IS NULL
           AND NOT EXISTS (SELECT 1 FROM judge_verdicts j WHERE j.loop_id = loop_executions.id)
         ORDER BY created_at DESC LIMIT 20) s;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'governance','WS44-01',
    'Does every loop asserting a gate verdict have a judge_verdicts row behind it? (The 119 verdicts predating 2026-08-22 are accepted per decision that day and excluded from the verdict, because retro-writing judge rows would fabricate judgements nobody made.)',
    '0 loops created after 2026-08-22 asserting a gate verdict with no judge_verdicts row',
    v_new_unbacked||' of '||v_new_total||' post-watermark verdicts unbacked; '||
      v_accepted||' historical accepted; judge_verdicts holds '||v_judge_rows||' rows',
    CASE WHEN v_new_unbacked = 0 THEN 'CONFORM' ELSE 'DEVIATION' END,
    CASE WHEN v_new_unbacked > 0 THEN 'HIGH' ELSE 'INFO' END,
    jsonb_build_object(
      'post_watermark_unbacked', v_new_unbacked,
      'post_watermark_total', v_new_total,
      'historical_accepted', v_accepted,
      'judge_verdicts_rows', v_judge_rows,
      'verdict_distribution', v_dist,
      'unbacked_sample', v_sample,
      'why','A verdict asserted on the loop with no judge_verdicts row behind it cannot be substantiated. Every individual row is accurate and the composite claim -- this passed the judge -- is unsupported. Stage 7 of the nine-stage cycle reads last_gate_verdict as its exit test, so an unbacked verdict can advance work.',
      'second_signal','Of the verdicts recorded to date, all are TRUST. The enum also offers MARGINAL and LIABILITY and neither has ever been written. A gate that has only ever returned its pass value warrants inspection independently of the provenance gap.',
      'accepted_risk','The '||v_accepted||' verdicts predating the watermark are surfaced for disposition, never retro-backed. Writing judge_verdicts rows for them would manufacture evidence of judgements that were never made.',
      'accepted_on','2026-08-22',
      'resolution_is_a_founder_decision','Either wire update_loop_from_prometheus to write judge_verdicts and set verdict_id, or stop writing last_gate_verdict. This detector takes no side and only makes the gap permanent and visible.'),
    jsonb_build_object('universe','all loop_executions rows asserting a non-null last_gate_verdict',
      'universe_count', v_universe, 'examined_count', v_universe, 'method','FULL',
      'source','public.loop_executions x public.judge_verdicts (both link directions)',
      'excluded','none; the pre-watermark subset is examined and reported, and excluded from the verdict only'),
    (v_new_unbacked > 0));
END; $function$;

revoke execute on function public.ws44_gate_verdict_provenance_check(uuid) from anon, public;

-- Append as the fifteenth check in the existing daily battery.
select cron.alter_job(
  (select jobid from cron.job where jobname = 'ws10_conformance_daily'),
  command := $cmd$
do $b$ declare v uuid := gen_random_uuid();
begin
  perform public.bp004_run_conformance_battery(v);
  perform public.ws31_flii_guard_bypass_check(v);
  perform public.ws32_ledger_immutability_check(v);
  perform public.ws33_flii_single_writer_check(v);
  perform public.ws34_render_inventory_check(v);
  perform public.ws35_secret_transit_check(v);
  perform public.ws36_competitor_disposition_check(v);
  perform public.ws37_embedded_credential_check(v);
  perform public.ws38_deliverable_auth_backlog_check(v);
  perform public.ws39_supersession_integrity_check(v);
  perform public.ws40_citation_integrity_check(v);
  perform public.ws41_cycle_integrity_check(v);
  perform public.ws42_registry_reality_check(v);
  perform public.ws43_cycle_gate_reachability_check(v);
  perform public.ws44_gate_verdict_provenance_check(v);
end $b$;
$cmd$);
