-- Preflight for migration 001 (normalize the TimescaleDB extension schema).
--
-- Read-only: reports where the extension lives, whether the target schema is
-- free and how much of the API surface is currently exposed. Run it before and
-- after 001; see 001_normalize_timescaledb_schema.sql for the migration itself.
--
--   docker exec -i postgres_container sh -c \
--     'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
--     < postgres/migrations/000_preflight_check.sql

WITH state AS (
    SELECT n.nspname AS ext_schema, n.nspname = 'api' AS drifted
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'timescaledb'
)
SELECT check_name, value, verdict
FROM (
    SELECT 1 AS ord,
           'timescaledb schema' AS check_name,
           n.nspname AS value,
           CASE n.nspname
               WHEN 'public' THEN 'OK: already normalized, 001 is a no-op'
               WHEN 'api'    THEN 'DRIFTED: run migration 001'
               ELSE 'UNEXPECTED: stop and migrate manually'
           END AS verdict
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'timescaledb'

    UNION ALL
    SELECT 2, 'timescaledb version', extversion,
           'info: a restore target needs this exact version'
      FROM pg_extension WHERE extname = 'timescaledb'

    UNION ALL
    SELECT 3, 'license', current_setting('timescaledb.license'),
           CASE current_setting('timescaledb.license')
               WHEN 'apache' THEN 'info: job scheduling functions unavailable'
               ELSE 'info: TSL build, job scheduling functions available'
           END

    -- 001 replaces public with the renamed api schema, so public has to be
    -- droppable. Only meaningful while drifted: once normalized, public holds
    -- the extension itself and is expected to be populated.
    UNION ALL
    SELECT 4, 'relations in public', count(*)::text,
           CASE WHEN NOT (SELECT drifted FROM state) THEN 'n/a: already normalized'
                WHEN count(*) = 0 THEN 'OK: target schema is free'
                ELSE 'BLOCKER: move or drop them before running 001' END
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public'

    UNION ALL
    SELECT 5, 'routines in public', count(*)::text,
           CASE WHEN NOT (SELECT drifted FROM state) THEN 'n/a: already normalized'
                WHEN count(*) = 0 THEN 'OK: target schema is free'
                ELSE 'BLOCKER: move or drop them before running 001' END
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public'

    UNION ALL
    SELECT 6, 'timescaledb functions in exposed api', count(*)::text,
           CASE WHEN count(*) = 0 THEN 'OK: not exposed'
                ELSE 'EXPOSED as /rpc endpoints; 001 removes this' END
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
      JOIN pg_extension e ON e.oid = d.refobjid
     WHERE n.nspname = 'api' AND e.extname = 'timescaledb'

    UNION ALL
    SELECT 7, 'application relations to move', count(*)::text,
           'info: 001 must report this many moved'
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
 LEFT JOIN pg_depend d ON d.objid = c.oid AND d.deptype = 'e'
     WHERE n.nspname = 'api'
       AND d.objid IS NULL
       AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S')

    UNION ALL
    SELECT 8, 'hypertables', count(*)::text,
           'info: must be unchanged after the migration'
      FROM timescaledb_information.hypertables

    -- Who can actually reach the extension functions that sit in the exposed
    -- schema. PostgREST turns those into /rpc endpoints for any role holding
    -- EXECUTE, so these are the real exposure numbers (0 once normalized).
    UNION ALL
    SELECT 9, 'exposed ts functions executable by api_anon', count(*)::text,
           CASE WHEN count(*) = 0 THEN 'OK: not reachable anonymously'
                ELSE 'anonymous RPC surface; 001 removes it' END
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
      JOIN pg_extension e ON e.oid = d.refobjid
     CROSS JOIN pg_roles r
     WHERE n.nspname = 'api' AND e.extname = 'timescaledb'
       AND r.rolname = 'api_anon'
       AND has_function_privilege(r.oid, p.oid, 'EXECUTE')

    UNION ALL
    SELECT 10, 'exposed ts functions executable by api_user', count(*)::text,
           CASE WHEN count(*) = 0 THEN 'OK: not reachable'
                ELSE 'authenticated RPC surface; 001 removes it' END
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
      JOIN pg_extension e ON e.oid = d.refobjid
     CROSS JOIN pg_roles r
     WHERE n.nspname = 'api' AND e.extname = 'timescaledb'
       AND r.rolname = 'api_user'
       AND has_function_privilege(r.oid, p.oid, 'EXECUTE')
) checks
ORDER BY ord;
