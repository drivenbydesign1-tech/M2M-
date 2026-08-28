-- Give the nine-stage cycle a driver, in preview only.
--
-- Finding SEL-20260822-1BD26D3B: m2m_cycle_sweep and m2m_cycle_advance appear in
-- zero cron jobs. The cycle advances only when a human calls it by hand.
--
-- This migration schedules the sweep in PREVIEW and captures its output so a week
-- of it can actually be read. Two deliberate design choices:
--
--   1. The scheduled entry point is a wrapper that hard-codes p_apply := false.
--      Enabling apply is therefore a separate, reviewable migration -- not a flag
--      someone edits inside a cron command string. Preview mode is enforced by the
--      instrument, not by the operator remembering.
--
--   2. The wrapper counts rows written to loop_audit_trail across the sweep and
--      records the delta. In preview that number must be 0 every run. A non-zero
--      value is visible evidence that something applied when it should not have.

create table if not exists public.m2m_cycle_sweep_log (
  id                 bigint generated always as identity primary key,
  run_id             uuid        not null,
  ran_at             timestamptz not null default now(),
  mode               text        not null check (mode in ('PREVIEW','APPLY')),
  limit_used         integer     not null,
  candidates         integer     not null,
  eligible_now       integer     not null,
  unclassified_now   integer     not null,
  verdict_counts     jsonb       not null default '{}'::jsonb,
  results            jsonb       not null default '[]'::jsonb,
  audit_rows_written integer     not null default 0
);

comment on table public.m2m_cycle_sweep_log is
  'One row per scheduled cycle-sweep run. In PREVIEW mode audit_rows_written must be 0; any other value means the sweep wrote when it should not have. eligible_now counts loops the sweep can see (cycle_stage not null and < 9); unclassified_now counts loops it cannot see because cycle_stage is NULL.';

create index if not exists idx_cycle_sweep_log_ran_at on public.m2m_cycle_sweep_log(ran_at desc);

alter table public.m2m_cycle_sweep_log enable row level security;

do $$ begin
  if not exists (select 1 from pg_policy where polrelid='public.m2m_cycle_sweep_log'::regclass
                   and polname='m2m_cycle_sweep_log_read') then
    create policy m2m_cycle_sweep_log_read on public.m2m_cycle_sweep_log
      for select to authenticated using (true);
  end if;
end $$;

-- Preview-only entry point. There is no parameter that makes this apply.
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
BEGIN
  SELECT count(*) INTO v_audit_before FROM loop_audit_trail;

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

  SELECT count(*) INTO v_audit_after FROM loop_audit_trail;

  INSERT INTO m2m_cycle_sweep_log(
    run_id, mode, limit_used, candidates, eligible_now, unclassified_now,
    verdict_counts, results, audit_rows_written)
  VALUES (
    v_run, 'PREVIEW', p_limit, v_n, v_eligible, v_unclassified,
    (SELECT coalesce(jsonb_object_agg(v, c), '{}'::jsonb)
       FROM (SELECT r->>'verdict' AS v, count(*) AS c
               FROM jsonb_array_elements(v_rows) r GROUP BY 1) q),
    v_rows,
    (v_audit_after - v_audit_before)::int);

  RETURN v_run;
END; $function$;

comment on function public.m2m_cycle_sweep_preview(integer) is
  'Scheduled entry point for the nine-stage cycle sweep. Runs m2m_cycle_sweep with p_apply hard-coded false and records the outcome to m2m_cycle_sweep_log. Cannot apply. Enabling apply requires a separate migration and a Founder decision.';

revoke execute on function public.m2m_cycle_sweep_preview(integer) from anon, public;

-- 14:00 UTC: after ws10_conformance_daily at 13:00, and clear of the existing
-- collisions at 11:00 and on the hour.
select cron.schedule(
  'm2m_cycle_sweep_preview_daily',
  '0 14 * * *',
  $cmd$select public.m2m_cycle_sweep_preview(100);$cmd$);
