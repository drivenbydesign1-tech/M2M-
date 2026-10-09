-- Correction to muon_validate_source_url shipped minutes earlier in this session.
-- Defect: reasons were appended as bare string literals (v_reasons || 'text').
-- With v_reasons of type text[] and the right operand of unknown type, PostgreSQL
-- resolves the operator as anyarray || anyarray and tries to parse the literal as
-- an array, raising 22P02 malformed array literal. Every branch appending a bare
-- literal therefore RAISED instead of returning a verdict.
--
-- That matters more than a normal type slip: a validator that raises instead of
-- returning {"allowed": false} is a validator whose caller may treat the error as
-- a transient failure and retry, or catch it and continue. A security check must
-- fail closed with a verdict, not explode. Caught by the attack corpus on the
-- 'no scheme' and empty-string cases before the function was ever wired to a fetcher.
--
-- Fix: every appended reason is explicitly ::text.
create or replace function public.muon_validate_source_url(p_url text)
returns jsonb
language plpgsql
stable
set search_path to 'public'
as $function$
DECLARE
  v_reasons text[] := '{}'::text[];
  v_scheme text; v_authority text; v_hostport text; v_host text; v_port text;
  v_denied text; v_allowed text;
BEGIN
  IF p_url IS NULL OR btrim(p_url) = '' THEN
    RETURN jsonb_build_object('allowed', false, 'url', p_url, 'host', null,
      'reasons', to_jsonb(array['url is null or empty']::text[]));
  END IF;

  IF p_url ~ '[[:space:]]' OR p_url ~ '[\x00-\x1F\x7F]' THEN
    v_reasons := v_reasons || 'url contains whitespace or control characters'::text;
  END IF;

  IF length(p_url) > 2048 THEN
    v_reasons := v_reasons || 'url exceeds 2048 characters'::text;
  END IF;

  v_scheme := lower(substring(p_url from '^([A-Za-z][A-Za-z0-9+.\-]*):'));
  IF v_scheme IS NULL THEN
    v_reasons := v_reasons || 'no scheme; a bare host or relative reference is not fetchable'::text;
  ELSIF v_scheme <> 'https' THEN
    v_reasons := v_reasons || ('scheme '||v_scheme||' is not permitted; https only')::text;
  END IF;

  v_authority := substring(p_url from '^[A-Za-z][A-Za-z0-9+.\-]*://([^/?#]*)');
  IF v_authority IS NULL OR v_authority = '' THEN
    v_reasons := v_reasons || 'no authority component'::text;
  ELSE
    IF position('@' in v_authority) > 0 THEN
      v_reasons := v_reasons || 'userinfo (@) is not permitted in the authority'::text;
    END IF;

    v_hostport := v_authority;

    IF left(v_hostport, 1) = '[' THEN
      v_reasons := v_reasons || 'IPv6 literal host is not permitted; use a hostname'::text;
      v_host := null;
    ELSE
      v_host := lower(split_part(v_hostport, ':', 1));
      v_port := nullif(split_part(v_hostport, ':', 2), '');
      IF split_part(v_hostport, ':', 3) <> '' THEN
        v_reasons := v_reasons || 'malformed authority'::text;
      END IF;
    END IF;

    IF v_port IS NOT NULL AND v_port <> '443' THEN
      v_reasons := v_reasons || ('port '||v_port||' is not permitted; 443 only')::text;
    END IF;

    IF v_host IS NOT NULL THEN
      IF v_host ~ '^[0-9]+$'
         OR v_host ~ '^0[xX][0-9a-fA-F]+$'
         OR v_host ~ '^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
         OR v_host ~ '^[0-9.]+$' THEN
        v_reasons := v_reasons || 'IP literal host is not permitted; use a hostname'::text;
      ELSIF v_host = 'localhost'
         OR v_host LIKE '%.localhost'
         OR v_host LIKE '%.local'
         OR v_host LIKE '%.internal'
         OR v_host LIKE '%.home.arpa'
         OR v_host NOT LIKE '%.%' THEN
        v_reasons := v_reasons || ('host '||v_host||' is an internal or unqualified name')::text;
      ELSIF v_host !~ '^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$' THEN
        v_reasons := v_reasons || 'hostname contains characters outside the permitted set'::text;
      END IF;
    END IF;
  END IF;

  IF v_host IS NOT NULL THEN
    SELECT host_suffix INTO v_denied FROM muon_source_policy
     WHERE active AND disposition = 'DENY'
       AND (v_host = host_suffix OR v_host LIKE '%.'||host_suffix)
     ORDER BY length(host_suffix) DESC LIMIT 1;

    SELECT host_suffix INTO v_allowed FROM muon_source_policy
     WHERE active AND disposition = 'ALLOW'
       AND (v_host = host_suffix OR v_host LIKE '%.'||host_suffix)
     ORDER BY length(host_suffix) DESC LIMIT 1;

    IF v_denied IS NOT NULL THEN
      v_reasons := v_reasons || ('host matches an active DENY rule for '||v_denied)::text;
    ELSIF v_allowed IS NULL THEN
      v_reasons := v_reasons || ('no ALLOW rule covers host '||v_host||'; policy is deny by default')::text;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'allowed', (cardinality(v_reasons) = 0),
    'url', p_url,
    'host', v_host,
    'port', coalesce(v_port,'443'),
    'matched_allow', v_allowed,
    'matched_deny', v_denied,
    'reasons', to_jsonb(v_reasons));
END; $function$;

comment on function public.muon_validate_source_url(text) is
  'Deterministic SSRF policy check for an outbound source URL. Returns a verdict, never raises, performs no network access. The fetcher must call this before connecting AND again for every redirect hop, and must additionally verify the resolved IP is publicly routable — a hostname check alone does not stop DNS rebinding.';

revoke execute on function public.muon_validate_source_url(text) from anon;
