-- STEP 1 (additive, inert). Nullable, no default, no constraint. Cannot break a read.
-- doc_ref is text because the surface it must join to -- m2m_claim_register.doc_id --
-- is text ('R2T-BRIEF-V1', 'AXIOM-BRIEF-V2'). deliverable_id (uuid) is left untouched.
alter table public.loop_executions add column if not exists doc_ref text;

comment on column public.loop_executions.doc_ref is
  'Text document reference binding a loop to m2m_claim_register.doc_id. Nullable by design. Population requires Founder decision: no deterministic rule matches any of the 203 rows (see m2m_loop_deliverable_match_preview). Do not backfill by inference.';

create index if not exists idx_loop_executions_doc_ref
  on public.loop_executions(doc_ref) where doc_ref is not null;

-- STEP 2. Repair the stage 4/5 branch of the cycle exit test.
-- Defect: the branch compared m2m_claim_register.doc_id (text) with
-- loop_executions.deliverable_id (uuid), which raises SQLSTATE 42883
-- "operator does not exist: text = uuid". It was unreachable only because
-- deliverable_id is NULL on all 203 rows, so the BLOCKED branch short-circuited
-- ahead of it. The first row ever populated would have broken stages 4 and 5.
-- Behaviour today is unchanged: doc_ref is NULL everywhere, so every loop still
-- returns BLOCKED_NO_DELIVERABLE_LINK, exactly as before this migration.
create or replace function public.m2m_cycle_exit_test(p_loop_id uuid)
returns table(stage_no smallint, stage_key text, verdict text, evidence jsonb)
language plpgsql
stable
set search_path to 'public'
as $function$
DECLARE l record; s record; v_claims int; v_bad int;
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
      IF coalesce(l.gate_checkpoint_count,0) > 0 AND l.last_gate_verdict = 'TRUST' THEN
        verdict := 'MET';
        evidence := jsonb_build_object('gate_verdict', l.last_gate_verdict, 'checkpoints', l.gate_checkpoint_count);
      ELSE
        verdict := 'NOT_MET';
        evidence := jsonb_build_object('gate_verdict', l.last_gate_verdict,
          'checkpoints', coalesce(l.gate_checkpoint_count,0),
          'required','at least one gate checkpoint with verdict TRUST');
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
