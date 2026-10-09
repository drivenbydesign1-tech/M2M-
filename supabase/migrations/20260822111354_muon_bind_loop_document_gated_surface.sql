-- Gated population surface for loop_executions.doc_ref.
--
-- Founder decision 2026-08-22: loops bind to m2m_claim_register.doc_id via doc_ref.
-- That authorises the AXIS. It does not supply the MAPPING, which names which loop
-- produced which document — an assertion about what happened, so it stays the
-- Founder's act. This function is the lock: it will not write for an agent caller.
--
-- Preview by default (p_dry_run := true), per the preview-mode doctrine: the
-- instrument enforces it rather than relying on the operator to remember.
create or replace function public.muon_bind_loop_document(
  p_bindings jsonb,                      -- [{"loop_id":"<uuid>","doc_ref":"R2T-BRIEF-V2"}, ...]
  p_dry_run  boolean default true
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
DECLARE
  v_actor text; v_applied int := 0;
  v_ok jsonb := '[]'::jsonb; v_bad jsonb := '[]'::jsonb;
  b jsonb; v_loop uuid; v_doc text;
  v_loop_exists boolean; v_doc_claims int; v_current text;
BEGIN
  IF p_bindings IS NULL OR jsonb_typeof(p_bindings) <> 'array' THEN
    RAISE EXCEPTION 'p_bindings must be a JSON array of {loop_id, doc_ref} objects';
  END IF;

  -- Validate every binding before writing any of them. A partially applied batch
  -- is worse than a rejected one: it leaves the Founder unsure what he authorised.
  FOR b IN SELECT jsonb_array_elements(p_bindings) LOOP
    BEGIN
      v_loop := (b->>'loop_id')::uuid;
    EXCEPTION WHEN OTHERS THEN
      v_bad := v_bad || jsonb_build_array(jsonb_build_object(
        'binding', b, 'reason', 'loop_id is not a uuid'));
      CONTINUE;
    END;
    v_doc := b->>'doc_ref';

    SELECT EXISTS(SELECT 1 FROM loop_executions WHERE id = v_loop) INTO v_loop_exists;
    SELECT count(*) INTO v_doc_claims FROM m2m_claim_register WHERE doc_id = v_doc;
    SELECT doc_ref INTO v_current FROM loop_executions WHERE id = v_loop;

    IF NOT v_loop_exists THEN
      v_bad := v_bad || jsonb_build_array(jsonb_build_object(
        'binding', b, 'reason', 'no such loop in loop_executions'));
    ELSIF v_doc IS NULL OR btrim(v_doc) = '' THEN
      v_bad := v_bad || jsonb_build_array(jsonb_build_object(
        'binding', b, 'reason', 'doc_ref is null or empty'));
    ELSIF v_doc_claims = 0 THEN
      -- Reject rather than warn. A doc_ref with no claims binds the gate to nothing
      -- and returns NOT_MET forever, which reads as a failing document rather than
      -- a typo. Register the claims first, then bind.
      v_bad := v_bad || jsonb_build_array(jsonb_build_object(
        'binding', b, 'reason', 'doc_ref matches no rows in m2m_claim_register — register its claims before binding'));
    ELSIF v_current IS NOT NULL AND v_current <> v_doc THEN
      v_bad := v_bad || jsonb_build_array(jsonb_build_object(
        'binding', b, 'reason', 'loop is already bound to '||v_current||'; unbind explicitly before rebinding'));
    ELSE
      v_ok := v_ok || jsonb_build_array(jsonb_build_object(
        'loop_id', v_loop, 'doc_ref', v_doc, 'material_claims', v_doc_claims,
        'already_bound', (v_current = v_doc)));
    END IF;
  END LOOP;

  IF jsonb_array_length(v_bad) > 0 THEN
    RETURN jsonb_build_object('applied', false, 'dry_run', p_dry_run,
      'reason', 'batch rejected — every binding must be valid before any is written',
      'rejected', v_bad, 'would_bind', v_ok);
  END IF;

  IF p_dry_run THEN
    RETURN jsonb_build_object('applied', false, 'dry_run', true,
      'would_bind', v_ok, 'count', jsonb_array_length(v_ok),
      'note','Preview. Nothing was written. Re-run with p_dry_run := false from a Founder session to apply.');
  END IF;

  -- Gate. Nothing below this line runs for a non-human caller.
  PERFORM public.assert_founder_session();

  -- Actor derived from the verified session, never from a literal.
  SELECT coalesce(p.full_name, u.email, auth.uid()::text) INTO v_actor
  FROM auth.users u LEFT JOIN public.profiles p ON p.id = u.id
  WHERE u.id = auth.uid();

  FOR b IN SELECT jsonb_array_elements(v_ok) LOOP
    UPDATE loop_executions
       SET doc_ref = b->>'doc_ref', updated_at = now()
     WHERE id = (b->>'loop_id')::uuid;
    v_applied := v_applied + 1;

    INSERT INTO loop_audit_trail (loop_id, event_type, actor, detail)
    VALUES ((b->>'loop_id')::uuid, 'DOC_REF_BOUND', v_actor,
      jsonb_build_object('doc_ref', b->>'doc_ref',
        'material_claims', b->'material_claims',
        'authority','Founder session, FL/II. Binding asserts which document this loop produced.',
        'bound_at', now()));
  END LOOP;

  RETURN jsonb_build_object('applied', true, 'dry_run', false,
    'count', v_applied, 'by', v_actor, 'at', now(), 'bound', v_ok);
END; $function$;

comment on function public.muon_bind_loop_document(jsonb, boolean) is
  'Founder-gated population of loop_executions.doc_ref. Preview by default. Validates the whole batch before writing any of it, rejects doc_refs with no registered claims, and refuses to write for any caller without a Founder session.';

revoke execute on function public.muon_bind_loop_document(jsonb, boolean) from anon, public;
grant execute on function public.muon_bind_loop_document(jsonb, boolean) to authenticated;
