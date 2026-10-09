-- WS74. Correcting a false statement in my own check's evidence.
--
-- WS72-01's scan_scope said other brief types were "covered by WS72-02". They are not.
-- WS72-02 counts bursts; it has no staleness rule at all. So nothing in the platform
-- watches a non-MORNING generator going quiet, and my own audit row claimed otherwise.
-- This is the same class as the WS45-01 evidence overstatement I corrected on 2026-09-27:
-- a check that describes its own coverage wrongly is worse than a missing check, because
-- it tells the next reader to stop looking.
--
-- Found by noticing that GOVCON_SCAN, which I described as "still producing" on 2026-10-07,
-- had in fact written nothing since 2026-10-04 23:00 -- and realising no check would ever
-- have said so.
--
-- I am NOT adding a liveness detector for the other types, and the corrected note says why.
-- Measured on 2026-10-09 across all 43 GOVCON_SCAN rows since 2026-06-17: median gap
-- between rows 24.00h, mean 62.51h, maximum 1344.10h. A generator that has legitimately
-- been dormant for 56 days cannot carry a staleness threshold; any alarm tight enough to
-- catch the current 4.5-day silence would have fired repeatedly on normal behaviour. That
-- is the WS45-01 lesson applied before shipping rather than after: a threshold with no
-- basis in the recorded distribution produces false alarms, and a false alarm costs more
-- than the gap it was meant to close.
--
-- Nothing but that one string changes. Verified before applying: the live function still
-- matched the version in supabase/migrations/20260929113259_*.sql byte for byte in the
-- relevant line, so no other session's edit is being overwritten. Thresholds, verdict
-- logic, severity ladder, grants and the cron job are untouched.
--
-- Rollback: re-apply 20260929113259's definition of
--           public.ws72_brief_delivery_liveness_check(uuid), which restores the original
--           (incorrect) note. Nothing else is affected.

create or replace function public.ws72_brief_delivery_liveness_check(p_run_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
DECLARE
  v_stale_h  constant numeric := 26;
  v_stuck_h  constant numeric := 6;
  v_last      timestamptz;
  v_age       numeric;
  v_stuck     int;
  v_unclaimed int;
  v_oldest_stuck timestamptz;
  v_oldest_unclaimed timestamptz;
  v_detail    jsonb;
  v_loops     int;
  v_cron_ok   boolean := true;
  v_cron_active boolean;
  v_cron_last timestamptz;
  v_verdict text; v_severity text; v_observed text;
BEGIN
  SELECT max(created_at) INTO v_last
    FROM m2m_daily_intel WHERE brief_type = 'MORNING';
  v_age := round((extract(epoch FROM (now() - v_last)) / 3600.0)::numeric, 2);

  -- A loop the watcher claimed and never finished, and a loop it never claimed, are
  -- different failures. Count them apart so the evidence says which one is happening.
  SELECT count(*) FILTER (WHERE status::text = 'RUNNING'   AND created_at < now() - make_interval(hours => v_stuck_h::int)),
         count(*) FILTER (WHERE status::text = 'INITIATED' AND created_at < now() - make_interval(hours => v_stuck_h::int)),
         min(created_at) FILTER (WHERE status::text = 'RUNNING'   AND created_at < now() - make_interval(hours => v_stuck_h::int)),
         min(created_at) FILTER (WHERE status::text = 'INITIATED' AND created_at < now() - make_interval(hours => v_stuck_h::int)),
         count(*)
    INTO v_stuck, v_unclaimed, v_oldest_stuck, v_oldest_unclaimed, v_loops
  FROM loop_executions
  WHERE loop_name = 'CEO Dashboard Briefing';

  SELECT coalesce(jsonb_agg(jsonb_build_object(
           'loop_id', l.id, 'status', l.status::text, 'created_at', l.created_at,
           'age_hours', round((extract(epoch FROM (now() - l.created_at))/3600.0)::numeric, 2))
         ORDER BY l.created_at DESC), '[]'::jsonb)
    INTO v_detail
  FROM loop_executions l
  WHERE l.loop_name = 'CEO Dashboard Briefing'
    AND l.status::text IN ('RUNNING','INITIATED')
    AND l.created_at < now() - make_interval(hours => v_stuck_h::int);

  BEGIN
    SELECT j.active,
           (SELECT max(d.start_time) FROM cron.job_run_details d WHERE d.jobid = j.jobid)
      INTO v_cron_active, v_cron_last
      FROM cron.job j WHERE j.jobname = 'm2m-ceo-dashboard-loop';
  EXCEPTION WHEN others THEN
    v_cron_ok := false;
  END;

  v_observed :=
    'newest MORNING brief '||coalesce(v_last::text,'never')||
    ' ('||coalesce(v_age::text,'n/a')||'h old); '||
    v_stuck||' briefing loop(s) stuck RUNNING past '||v_stuck_h||'h'||
    coalesce(', oldest '||v_oldest_stuck::text, '')||'; '||
    v_unclaimed||' never claimed past '||v_stuck_h||'h'||
    coalesce(', oldest '||v_oldest_unclaimed::text, '')||
    CASE WHEN v_cron_ok
         THEN '; loop-creating cron active='||coalesce(v_cron_active::text,'absent')||
              ', last run '||coalesce(v_cron_last::text,'never')
         ELSE '; cron.job not readable from this role' END;

  v_verdict := CASE
    WHEN v_last IS NULL                       THEN 'DEVIATION'
    WHEN v_age > v_stale_h                    THEN 'DEVIATION'
    WHEN v_stuck > 0 OR v_unclaimed > 0       THEN 'DEVIATION'
    WHEN coalesce(v_cron_active,false) = false THEN 'DEVIATION'
    ELSE 'CONFORM' END;

  v_severity := CASE
    WHEN v_verdict = 'CONFORM'                THEN 'INFO'
    WHEN v_last IS NULL OR v_age > v_stale_h  THEN 'HIGH'
    ELSE 'MEDIUM' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'platform','WS72-01',
    'Did the Founder''s daily brief actually land, or did only the cron that creates its loop succeed?',
    'a MORNING brief newer than 26 hours, no CEO Dashboard Briefing loop left RUNNING or INITIATED past 6 hours, and the loop-creating cron job active',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'newest_morning_brief', v_last, 'age_hours', v_age, 'stale_threshold_hours', v_stale_h,
      'stuck_running', v_stuck, 'oldest_stuck', v_oldest_stuck,
      'never_claimed', v_unclaimed, 'oldest_unclaimed', v_oldest_unclaimed,
      'stuck_threshold_hours', v_stuck_h, 'stalled_loop_detail', v_detail,
      'briefing_loops_total', v_loops,
      'cron_active', v_cron_active, 'cron_last_run', v_cron_last, 'cron_readable', v_cron_ok,
      'why','Briefs stopped on 2026-09-24 and nobody noticed until 2026-09-29. WS70_CRON_HEALTH read CONFORM the whole time, correctly: the cron creates the loop row and that part never failed. Everything after loop creation was unwatched. This check watches the deliverable instead of the trigger.',
      'not_a_fix','This detects. It does not repair the watcher or the Make scenario, which are outside this migration and outside my authority to change.',
      'read_from','public.m2m_daily_intel, public.loop_executions, cron.job / cron.job_run_details'),
    jsonb_build_object('universe','every CEO Dashboard Briefing loop, plus every MORNING row in m2m_daily_intel',
      'universe_count', v_loops, 'examined_count', v_loops, 'method','FULL',
      'source','public.loop_executions x public.m2m_daily_intel',
      'excluded','brief types other than MORNING. My original note here said they were "covered by WS72-02". That was wrong: WS72-02 counts bursts, it does not watch for silence, so no check watches a non-MORNING generator going quiet. They are excluded because their cadence will not carry a staleness threshold -- GOVCON_SCAN, the most regular of them, has a median gap of 24h but a maximum gap of 1,344h across 43 rows since 2026-06-17, so a silence alarm on it would fire on normal dormancy. Measured 2026-10-09.'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- Re-assert the grant posture; create or replace does not reset it, but WS47 was a defect
-- found only in proacl, so this is checked rather than assumed.
revoke execute on function public.ws72_brief_delivery_liveness_check(uuid) from public;
revoke execute on function public.ws72_brief_delivery_liveness_check(uuid) from anon;
revoke execute on function public.ws72_brief_delivery_liveness_check(uuid) from authenticated;

DO $verify$
DECLARE v_bad text; v_note boolean;
BEGIN
  SELECT string_agg(p.proname||' -> '||g.grantee, ', ') INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (VALUES ('public'),('anon'),('authenticated')) AS g(grantee)
  WHERE n.nspname = 'public'
    AND p.proname = 'ws72_brief_delivery_liveness_check'
    AND has_function_privilege(g.grantee, p.oid, 'EXECUTE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'WS74 grant check failed, EXECUTE survives for: %', v_bad;
  END IF;

  SELECT pg_get_functiondef(p.oid) LIKE '%does not watch for silence%' INTO v_note
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public' AND p.proname = 'ws72_brief_delivery_liveness_check';
  IF NOT coalesce(v_note,false) THEN
    RAISE EXCEPTION 'WS74 failed: the corrected exclusion note is not present in the installed function';
  END IF;
END $verify$;
