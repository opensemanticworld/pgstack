-- Migration 001: move the TimescaleDB extension out of the exposed schema
--
-- Context
-- -------
-- 100_init_tsdb_schema.sql used to run "SET search_path TO api" before
-- "CREATE EXTENSION timescaledb". An extension created without a SCHEMA clause
-- lands in the first schema of search_path, so on stacks whose image does not
-- preinstall TimescaleDB the extension was created inside api. Images that ship
-- it in template1 (timescaledb-ha) kept it in public and masked the difference,
-- so the two constellations drifted apart unnoticed.
--
-- Why this matters
-- ----------------
-- api is the schema PostgREST exposes (PGRST_DB_SCHEMAS=api). Every function in
-- it becomes an /rpc endpoint, and TimescaleDB grants EXECUTE on its functions
-- to PUBLIC, so in that constellation they are callable by the anonymous role.
-- PostgREST expects extensions on db-extra-search-path (default: public), which
-- is reachable from the exposed schema but is never exposed itself.
--
-- What this does
-- --------------
-- The extension is not relocatable (ALTER EXTENSION ... SET SCHEMA is refused),
-- so rather than moving the extension this moves the API out from under it: the
-- old api schema is renamed to public (the extension travels with its
-- namespace) and a fresh api schema takes back the application objects.
-- Catalog-only: no table rewrite, no data copy, no chunk movement. Hypertables,
-- chunks and compression settings are preserved.
--
-- Usage
-- -----
--   1. stop writers (ingestion and PostgREST) for the duration
--   2. psql -v ON_ERROR_STOP=1 -f 001_normalize_timescaledb_schema.sql
--   3. re-run optional/100_init_tsdb_schema.sql to recreate the API functions
--   4. NOTIFY pgrst, 'reload schema'   (or restart the PostgREST container)
--
-- Re-runnable: exits with a notice if the database is already normalized.

BEGIN;

DO $migrate$
DECLARE
    ts_schema    text;
    blocking     int;
    r            record;
    moved        int := 0;
    dropped      int := 0;
    role_name    text;
    drop_stmts   text[];
    stmt         text;
BEGIN
    SELECT n.nspname INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
     WHERE e.extname = 'timescaledb';

    IF ts_schema IS NULL THEN
        RAISE EXCEPTION 'TimescaleDB is not installed in this database';
    END IF;

    IF ts_schema = 'public' THEN
        RAISE NOTICE 'already normalized: timescaledb is in public, nothing to do';
        RETURN;
    END IF;

    IF ts_schema <> 'api' THEN
        RAISE EXCEPTION
            'timescaledb is in schema %, expected api (drifted) or public '
            '(normalized). Migrate this database manually.', ts_schema;
    END IF;

    -- public is about to be replaced by the renamed api schema, so it has to be
    -- empty. Abort with a clear message instead of destroying anything.
    SELECT count(*) INTO blocking
      FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public';
    IF blocking > 0 THEN
        RAISE EXCEPTION
            'schema public holds % relation(s); move or drop them before '
            'running this migration', blocking;
    END IF;

    SELECT count(*) INTO blocking
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public';
    IF blocking > 0 THEN
        RAISE EXCEPTION
            'schema public holds % routine(s); move or drop them before '
            'running this migration', blocking;
    END IF;

    -- 1. Swap the namespaces. The extension keeps its namespace OID, so it ends
    --    up in public without being moved (which the extension forbids).
    EXECUTE 'DROP SCHEMA public RESTRICT';
    EXECUTE 'ALTER SCHEMA api RENAME TO public';
    EXECUTE 'CREATE SCHEMA api';

    -- 2. Move the application relations back into the fresh exposed schema.
    --    Extension-owned objects (pg_depend deptype 'e') stay behind, as do
    --    sequences owned by a table, which travel with their table.
    FOR r IN
        SELECT c.relname, c.relkind
          FROM pg_class c
          JOIN pg_namespace n ON n.oid = c.relnamespace
     LEFT JOIN pg_depend de ON de.objid = c.oid AND de.deptype = 'e'
     LEFT JOIN pg_depend da ON da.objid = c.oid AND da.deptype IN ('a', 'i')
         WHERE n.nspname = 'public'
           AND de.objid IS NULL
           AND da.objid IS NULL
           AND c.relkind IN ('r', 'p', 'f', 'v', 'm', 'S')
         ORDER BY CASE c.relkind WHEN 'v' THEN 2 WHEN 'm' THEN 2 ELSE 1 END
    LOOP
        EXECUTE format(
            CASE r.relkind
                WHEN 'v' THEN 'ALTER VIEW public.%I SET SCHEMA api'
                WHEN 'm' THEN 'ALTER MATERIALIZED VIEW public.%I SET SCHEMA api'
                WHEN 'S' THEN 'ALTER SEQUENCE public.%I SET SCHEMA api'
                ELSE 'ALTER TABLE public.%I SET SCHEMA api'
            END, r.relname);
        moved := moved + 1;
    END LOOP;

    -- 3. Drop the API routines left behind in the extension schema. They are
    --    recreated in api by 100_init_tsdb_schema.sql (step 3 of Usage), which
    --    keeps them in sync with the current definitions.
    --    The statements are rendered up front: dropping one routine can cascade
    --    to another, and a regprocedure whose function is already gone renders
    --    as a bare OID, which is not valid syntax.
    SELECT array_agg(
               format(
                   CASE p.prokind
                       WHEN 'a' THEN 'DROP AGGREGATE IF EXISTS %s CASCADE'
                       ELSE 'DROP FUNCTION IF EXISTS %s CASCADE'
                   END, p.oid::regprocedure))
      INTO drop_stmts
      FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
 LEFT JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
     WHERE n.nspname = 'public'
       AND d.objid IS NULL;

    FOREACH stmt IN ARRAY COALESCE(drop_stmts, ARRAY[]::text[]) LOOP
        EXECUTE stmt;
        dropped := dropped + 1;
    END LOOP;

    -- 4. Restore the grants of the exposed schema (see 010_init_postgrest.sql);
    --    the fresh schema starts without any.
    FOREACH role_name IN ARRAY ARRAY['api_anon', 'api_user', 'api_admin'] LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = role_name);
        IF role_name = 'api_anon' THEN
            EXECUTE format('GRANT USAGE ON SCHEMA api TO %I', role_name);
        ELSE
            EXECUTE format('GRANT ALL ON SCHEMA api TO %I', role_name);
        END IF;

        -- The extension schema must be resolvable from the exposed schema but
        -- must not be writable by API roles (no self-published endpoints).
        EXECUTE format('REVOKE CREATE ON SCHEMA public FROM %I', role_name);
        EXECUTE format('GRANT USAGE ON SCHEMA public TO %I', role_name);
    END LOOP;

    RAISE NOTICE
        'normalized: timescaledb now in public, % relation(s) moved back into '
        'api, % stale routine(s) dropped. Re-run 100_init_tsdb_schema.sql and '
        'reload PostgREST.', moved, dropped;
END
$migrate$;

-- Restore the PostgREST schema cache trigger. api.pgrst_watch() is defined in
-- docker-entrypoint-initdb.d/010_init_postgrest.sql, so it is one of the
-- routines dropped above, and dropping it cascades to the event trigger. Since
-- 100_init_tsdb_schema.sql does not recreate it, PostgREST would otherwise stop
-- noticing new tool tables: a create_tool would not appear as an endpoint until
-- a manual reload. Runs unconditionally, outside the block above, which returns
-- early on an already normalized database.
CREATE OR REPLACE FUNCTION api.pgrst_watch()
RETURNS event_trigger
LANGUAGE plpgsql
AS $$
BEGIN
NOTIFY pgrst, 'reload schema';
END;
$$;

DROP EVENT TRIGGER IF EXISTS pgrst_watch;
CREATE EVENT TRIGGER pgrst_watch ON ddl_command_end
EXECUTE PROCEDURE api.pgrst_watch();

COMMIT;
