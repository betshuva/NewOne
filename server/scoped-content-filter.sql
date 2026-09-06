CREATE OR REPLACE FUNCTION betshuva_effective_filter(general_filter jsonb, scoped_filter jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
  SELECT jsonb_object_agg(key, to_jsonb(
    COALESCE((scoped_filter->>key)::boolean, (general_filter->>key)::boolean, true)
    AND (COALESCE(general_filter->'enforceGeneralFilter' = 'true'::jsonb, false) = false
      OR COALESCE((general_filter->>key)::boolean, true))
  )) FROM unnest(ARRAY['text','video','nonHumanImages','men','women','children']) AS keys(key)
$$;
