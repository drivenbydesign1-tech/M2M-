-- WS72. The Founder's daily brief has not landed since 2026-09-24 11:11. Five mornings
-- missing. Nothing in the platform noticed, and that is the defect this migration fixes.
--
-- Why nothing noticed. WS70_CRON_HEALTH reads CONFORM: m2m-ceo-dashboard-loop succeeds
-- every day at 11:00, INSERT 0 1. The cron's job is to CREATE the loop row, and it does.
-- What follows -- the watcher claiming the loop, the generator running, the brief landing
-- in m2m_daily_intel -- is unwatched. A green cron over a dead pipeline is exactly the
-- shape of failure the ledger keeps rediscovering by hand.
--
-- What the record shows (2026-09-29):
--   09-25 loop ceb21c57  HUMAN_REQUIRED (set by an hourly breaker sweep, not by delivery)
--   09-26 loop fdf21131  RUNNING   -- claimed, never terminal, 3 days later
--   09-27 loop fc8650c0  RUNNING   -- claimed, never terminal, 2 days later
--   09-28 loop fbf6fe02  INITIATED -- never claimed
--   09-29 loop 7cf68542  INITIATED -- never claimed
-- Two stuck claims, then the watcher stopped claiming at all. No brief since 09-24.
--
-- The second defect: bursts. m2m_daily_intel gained 987 DIAGNOSTIC rows on 2026-09-27
-- between 19:06 and 19:53 -- four concurrent manual runs of Make scenario 5527222
-- (M2M-SOVEREIGN-DIAGNOSTIC), each capped at the 45-minute execution ceiling, ~2,154
-- operations and ~15,900 centicredits, roughly 987 model calls. That is not the first.
-- Eight hours since June have exceeded 25 briefs: 06-22 (60), 06-29 (60), 07-06 (60),
-- 07-15 (64), 07-20 (199), 09-21 (27 then 888), 09-27 (987). I previously reported the
-- 09-21 event as unrepeated. It was the sixth occurrence, not the first.
--
-- Neither check touches the Make scenarios or the watcher -- those are not mine to change.
-- These are detectors. Both are read-only apart from their own audit row, and both are
-- scheduled, because the lesson of this outage is that a detector only an agent can run is
-- a detector that runs when someone remembers.
--
-- Thresholds are read off the record, not invented:
--   26h staleness matches the convention WS45-01 already uses for a daily job.
--   6h stuck-loop window: the watcher polls every 15 minutes and the brief historically
--   landed ~11 minutes after loop creation, so six hours is 24 missed polls.
--   25 briefs/hour: the 95th percentile of the last 120 days is 11/hour. 25 clears normal
--   cadence and catches all eight burst hours on record with no other hour in between.
--
-- Rollback: drop function public.ws72_brief_delivery_liveness_check(uuid);
--           drop function public.ws72_brief_generation_burst_check(uuid);
--           select cron.unschedule('ws72_brief_delivery_daily');
-- Nothing else is altered, so the rollback is complete.

-- 1. Brief delivery liveness.
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
      'excluded','brief types other than MORNING; those have their own cadences and are covered by WS72-02'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- 2. Generation burst.
create or replace function public.ws72_brief_generation_burst_check(p_run_id uuid)
 returns void language plpgsql security definer set search_path to 'public'
as $function$
DECLARE
  v_cap    constant int := 25;
  v_window constant interval := interval '7 days';
  v_bursts int; v_worst int; v_worst_hr timestamptz; v_rows_in_bursts bigint;
  v_detail jsonb; v_p95 int; v_hours int;
  v_hist_bursts int;
  v_verdict text; v_severity text; v_observed text;
BEGIN
  WITH h AS (
    SELECT date_trunc('hour', created_at) hr, brief_type, count(*) n
      FROM m2m_daily_intel WHERE created_at > now() - v_window
     GROUP BY 1,2)
  SELECT count(*) FILTER (WHERE n > v_cap),
         coalesce(max(n) FILTER (WHERE n > v_cap), 0),
         (SELECT hr FROM h WHERE n > v_cap ORDER BY n DESC LIMIT 1),
         coalesce(sum(n) FILTER (WHERE n > v_cap), 0),
         coalesce(jsonb_agg(jsonb_build_object('hour', hr, 'brief_type', brief_type, 'rows', n)
                  ORDER BY n DESC) FILTER (WHERE n > v_cap), '[]'::jsonb)
    INTO v_bursts, v_worst, v_worst_hr, v_rows_in_bursts, v_detail
  FROM h;

  -- Print the long-run shape so the threshold can be judged, not just trusted.
  WITH h AS (
    SELECT date_trunc('hour', created_at) hr, count(*) n
      FROM m2m_daily_intel WHERE created_at > now() - interval '120 days' GROUP BY 1)
  SELECT count(*), coalesce(percentile_disc(0.95) WITHIN GROUP (ORDER BY n), 0),
         count(*) FILTER (WHERE n > v_cap)
    INTO v_hours, v_p95, v_hist_bursts
  FROM h;

  v_observed :=
    v_bursts||' hour(s) in the last 7 days wrote more than '||v_cap||' briefs'||
    CASE WHEN v_bursts > 0
         THEN '; worst '||v_worst||' rows at '||v_worst_hr::text||', '||v_rows_in_bursts||' rows across burst hours'
         ELSE '' END||
    '; 120-day baseline: '||v_hours||' hours with writes, 95th percentile '||v_p95||
    '/hour, '||v_hist_bursts||' hour(s) ever over '||v_cap;

  v_verdict  := CASE WHEN v_bursts > 0 THEN 'DEVIATION' ELSE 'CONFORM' END;
  v_severity := CASE WHEN v_bursts = 0 THEN 'INFO'
                     WHEN v_worst > 200 THEN 'HIGH'
                     ELSE 'MEDIUM' END;

  INSERT INTO m2m_conformance_audit
    (run_id, audit_scope, check_code, check_question, expected, observed,
     verdict, severity, evidence, scan_scope, requires_authentication)
  VALUES (p_run_id,'platform','WS72-02',
    'Has any hour written more briefs than a human-cadence generator can explain?',
    'no hour in the last 7 days above 25 briefs',
    v_observed, v_verdict, v_severity,
    jsonb_build_object(
      'cap_per_hour', v_cap, 'window', v_window::text,
      'burst_hours_7d', v_bursts, 'worst_hour_rows', v_worst, 'worst_hour', v_worst_hr,
      'rows_in_burst_hours', v_rows_in_bursts, 'burst_detail', v_detail,
      'baseline_hours_120d', v_hours, 'baseline_p95_per_hour', v_p95,
      'burst_hours_ever_120d', v_hist_bursts,
      'why','Eight hours since June have exceeded this cap: 2026-06-22 (60), 06-29 (60), 07-06 (60), 07-15 (64), 07-20 (199), 09-21 (27 then 888), 09-27 (987 DIAGNOSTIC). Each is roughly one model call per row. The 09-27 event was four concurrent manual runs of Make scenario 5527222, each held to the 45-minute execution ceiling, about 15,900 centicredits. I reported the 09-21 event as unrepeated; it was the sixth occurrence.',
      'threshold_derivation','95th percentile of the last 120 days is 11 briefs/hour. A cap of 25 clears normal cadence and catches all eight burst hours on record, with no hour in between.',
      'not_a_throttle','This counts after the fact. It cannot stop a Make scenario, and nothing here changes one.',
      'read_from','public.m2m_daily_intel'),
    jsonb_build_object('universe','every hour in the last 7 days that wrote to m2m_daily_intel, against a 120-day baseline',
      'universe_count', v_hours, 'examined_count', v_hours, 'method','FULL',
      'source','public.m2m_daily_intel',
      'excluded','none'),
    (v_verdict <> 'CONFORM'));
END; $function$;

-- 3. Close the default PUBLIC grant. This is the WS47 lesson: a SECURITY DEFINER function
-- in public inherits EXECUTE to PUBLIC unless revoked, and the anon key reaches it over
-- PostgREST. These two only read and write their own audit row, so the exposure is small,
-- but the convention is not conditional on the blast radius.
revoke execute on function public.ws72_brief_delivery_liveness_check(uuid) from public;
revoke execute on function public.ws72_brief_delivery_liveness_check(uuid) from anon;
revoke execute on function public.ws72_brief_delivery_liveness_check(uuid) from authenticated;
revoke execute on function public.ws72_brief_generation_burst_check(uuid) from public;
revoke execute on function public.ws72_brief_generation_burst_check(uuid) from anon;
revoke execute on function public.ws72_brief_generation_burst_check(uuid) from authenticated;

DO $verify$
DECLARE v_bad text;
BEGIN
  SELECT string_agg(p.proname||' -> '||g.grantee, ', ')
    INTO v_bad
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  CROSS JOIN LATERAL (VALUES ('public'),('anon'),('authenticated')) AS g(grantee)
  WHERE n.nspname = 'public'
    AND p.proname IN ('ws72_brief_delivery_liveness_check','ws72_brief_generation_burst_check')
    AND has_function_privilege(g.grantee, p.oid, 'EXECUTE');
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'WS72 grant check failed, EXECUTE survives for: %', v_bad;
  END IF;
END $verify$;

-- 4. Schedule it. 12:45 UTC leaves the 11:00 loop and its ~11:11 generation 94 minutes to
-- land, and lands before the 13:00 ws10 battery.
SELECT cron.unschedule('ws72_brief_delivery_daily')
 WHERE EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'ws72_brief_delivery_daily');

SELECT cron.schedule('ws72_brief_delivery_daily', '45 12 * * *', $cron$
  WITH r AS (SELECT gen_random_uuid() AS id)
  SELECT public.ws72_brief_delivery_liveness_check(r.id),
         public.ws72_brief_generation_burst_check(r.id)
    FROM r;
$cron$);
