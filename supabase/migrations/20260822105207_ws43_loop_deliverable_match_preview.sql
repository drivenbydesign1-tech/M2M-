-- Read-only preview. Classifies every loop_executions row as MATCHED / AMBIGUOUS /
-- UNMATCHED against the live deliverable catalogue under explicitly declared
-- deterministic rules. Writes nothing by construction (LANGUAGE sql, STABLE).
create or replace function public.m2m_loop_deliverable_match_preview()
returns table(disposition text, rule_applied text, loop_count bigint, sample jsonb)
language sql
stable
set search_path to 'public'
as $$
  with del_scen as (
    select ad.deliverable_ref, btrim(s) as scen
    from m2m_active_deliverables ad,
         lateral unnest(string_to_array(coalesce(ad.make_scenario, ''), ',')) s
    where btrim(s) <> ''
  ),
  cand as (
    select l.id as loop_id,
           l.loop_name,
           -- Rule A: identity on Make scenario id, both sides populated
           coalesce((select array_agg(distinct d.deliverable_ref)
                     from del_scen d
                     where l.make_scenario_id is not null
                       and d.scen = l.make_scenario_id), '{}'::text[]) as a_refs,
           -- Rule B: identity on normalised title
           coalesce((select array_agg(distinct ad.deliverable_ref)
                     from m2m_active_deliverables ad
                     where lower(btrim(ad.title)) = lower(btrim(l.loop_name))), '{}'::text[]) as b_refs
    from loop_executions l
  ),
  scored as (
    select loop_id, loop_name,
           (select coalesce(array_agg(distinct r), '{}'::text[])
            from unnest(a_refs || b_refs) r) as refs,
           case when cardinality(a_refs) > 0 and cardinality(b_refs) > 0 then 'A+B'
                when cardinality(a_refs) > 0 then 'A:make_scenario_identity'
                when cardinality(b_refs) > 0 then 'B:normalised_title_identity'
                else 'no_rule_fired' end as rule_applied
    from cand
  )
  select case when cardinality(refs) = 1 then 'MATCHED'
              when cardinality(refs) > 1 then 'AMBIGUOUS'
              else 'UNMATCHED' end as disposition,
         rule_applied,
         count(*) as loop_count,
         jsonb_build_object(
           'distinct_loop_names', jsonb_agg(distinct loop_name),
           'candidate_refs', jsonb_agg(distinct to_jsonb(refs))
         ) as sample
  from scored
  group by 1, 2
  order by 1, 2;
$$;

comment on function public.m2m_loop_deliverable_match_preview() is
  'Preview only. Declares the deterministic rules by which a loop could be bound to a deliverable and reports the disposition of every row. Writes nothing. Populating a relationship this function reports as AMBIGUOUS or UNMATCHED would be inventing data.';

revoke execute on function public.m2m_loop_deliverable_match_preview() from anon;
