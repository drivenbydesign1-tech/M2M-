-- Switch on semantic skill routing.
--
-- Finding SEL-20260822-1BD26D3B: 72 of 75 skills carry embeddings and
-- idx_skill_embedding_hnsw had been scanned zero times. The embedding cost was
-- already paid; the retrieval capability it was bought for had never been called.
--
-- The index is hnsw (embedding vector_cosine_ops), so the ordering operator must be
-- <=> (cosine distance) for the planner to use it. Similarity is returned as
-- 1 - distance so that higher is better, which is the convention callers expect.
--
-- search_path includes extensions: pgvector is installed there, so a search_path of
-- 'public' alone leaves the <=> operator invisible and the function fails to create.
--
-- MEASURED CAVEAT: at 75 rows the planner does NOT use the HNSW index. EXPLAIN
-- ANALYZE shows Seq Scan over 72 embedded rows in 18ms, which is correct -- an exact
-- scan of this many rows is cheaper and more accurate than an approximate probe.
-- Results are right either way. The index earns its keep only once the registry is
-- far larger.
create or replace function public.m2m_match_skills(
  p_query_embedding extensions.vector(1024),
  p_k               integer default 5,
  p_min_similarity  double precision default 0.0
)
returns table(skill_id text, skl_ref text, description text, similarity double precision)
language sql
stable
set search_path to 'public', 'extensions'
as $function$
  select s.skill_id,
         s.skl_ref,
         s.description,
         1 - (s.embedding <=> p_query_embedding) as similarity
  from skill_registry s
  where s.embedding is not null
    and 1 - (s.embedding <=> p_query_embedding) >= p_min_similarity
  order by s.embedding <=> p_query_embedding
  limit greatest(coalesce(p_k, 5), 1);
$function$;

comment on function public.m2m_match_skills(extensions.vector, integer, double precision) is
  'Semantic skill retrieval over skill_registry.embedding using the existing HNSW cosine index. Returns the k nearest skills with similarity as 1 - cosine distance, higher being closer. Callers embed the query first (voyage-3, 1024 dims) via the m2m-embedder Edge Function. Joins on skill_id, never skl_ref, which is present on only a minority of rows.';

revoke execute on function public.m2m_match_skills(extensions.vector, integer, double precision) from anon;
