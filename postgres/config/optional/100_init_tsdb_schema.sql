SET search_path TO api;

-- init extensions
CREATE EXTENSION IF NOT EXISTS timescaledb;

-- ! ONLY IF ALL DATA OF ALL TOOLS SHOULD BE QUERYABLE 
-- Internal (GET -> View, POST -> RPC)
CREATE TABLE IF NOT EXISTS api.tools (
  osw_tool CHAR(35) PRIMARY KEY
);
-- GRANT SELECT, INSERT on api.tools TO api_user;

--------- ONLY FOR TESTING, REMOVE IN PRODUCTION ---------
-- GRANT SELECT on api.tools TO api_anon;
GRANT ALL on api.tools TO api_user;
----------------------------------------------------------

-- Endpoint to create a new data channel endpoint
-- !INDEX ON TS, MAYBE CHANGE TO UUID OR ADD INDEX ON UUID
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP FUNCTION IF EXISTS api.create_tool_endpoint(osw_tool CHAR(35));
CREATE OR REPLACE FUNCTION api.create_tool_endpoint(osw_tool CHAR(35)) RETURNS void AS
$$
BEGIN
    EXECUTE format('CREATE TABLE IF NOT EXISTS api.%I (ch CHAR(35), ts TIMESTAMPTZ NOT NULL, data JSONB)', osw_tool);
    EXECUTE format('SELECT public.create_hypertable(''api.%I'', ''ts'')', osw_tool);
    -- EXECUTE format('GRANT SELECT on api.%I to api_anon', osw_tool);
    EXECUTE format('GRANT ALL on api.%I to api_user', osw_tool);
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.create_tool_endpoint TO api_user;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_hypertable (regclass, _timescaledb_internal.dimension_info, boolean , boolean, boolean) TO api_user;
GRANT EXECUTE ON FUNCTION public.create_hypertable (regclass, name, name, integer, name, name, anyelement, boolean, boolean, regproc, boolean, text, regproc, regproc) TO api_user;
GRANT EXECUTE ON FUNCTION _timescaledb_functions.insert_blocker() TO api_user;

-- Function to create a tool, returns status message
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP FUNCTION IF EXISTS api.create_tool(osw_tool CHAR(35));
CREATE OR REPLACE FUNCTION api.create_tool(osw_tool CHAR(35)) RETURNS TEXT AS
$$
BEGIN
    INSERT INTO api.tools (osw_tool) VALUES (osw_tool); --! only if relation api.tools exists
		PERFORM api.create_tool_endpoint(osw_tool);
    RETURN 'OSW tool created successfully: ' || osw_tool;
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.create_tool(char) TO api_user;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;

-- Function to create a tool, input is array of osw_tools, returns status message
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP FUNCTION IF EXISTS api.create_tools(osw_tools CHAR(35)[]);
CREATE OR REPLACE FUNCTION api.create_tools(osw_tools CHAR(35)[]) RETURNS TEXT AS
$$
DECLARE
		osw_tool CHAR(35);
BEGIN
		FOREACH osw_tool IN ARRAY osw_tools LOOP
				PERFORM api.create_tool(osw_tool);
		END LOOP;
		RETURN 'OSW tools created successfully: ' || array_to_string(osw_tools, ', ');
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.create_tools(char[]) TO api_user;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;

-- Endpoint to delete a tool
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP FUNCTION IF EXISTS api.delete_tool_endpoint(osw_tool CHAR(35));
CREATE OR REPLACE FUNCTION api.delete_tool_endpoint(osw_tool CHAR(35)) RETURNS void AS
$$
BEGIN
    EXECUTE format('DROP TABLE IF EXISTS api.%I', osw_tool);
    -- EXECUTE format('REVOKE ALL ON TABLE api.%I FROM api_anon', osw_tool);
    -- EXECUTE format('REVOKE ALL ON TABLE api.%I FROM api_user', osw_tool);
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.delete_tool_endpoint TO api_user;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;


-- NEW: Function to delete a tool, input is osw_tool, returns status message
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP FUNCTION IF EXISTS api.delete_tool(osw_tool CHAR(35));
CREATE OR REPLACE FUNCTION api.delete_tool(osw_tool CHAR(35)) RETURNS TEXT AS
$$
BEGIN
    PERFORM api.delete_tool_endpoint(osw_tool);
    DELETE FROM api.tools WHERE api.tools.osw_tool = delete_tool.osw_tool;
    RETURN 'OSW tool deleted successfully: ' || osw_tool;
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.delete_tool(char) TO api_user;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;

-- New: Function to delete multiple tools, input is array of osw_tools, returns status message
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
DROP FUNCTION IF EXISTS api.delete_tools(osw_tools CHAR(35)[]);
CREATE OR REPLACE FUNCTION api.delete_tools(osw_tools CHAR(35)[]) RETURNS TEXT AS
$$
DECLARE
        osw_tool CHAR(35);
BEGIN
        FOREACH osw_tool IN ARRAY osw_tools LOOP
                PERFORM api.delete_tool(osw_tool);
        END LOOP;
        RETURN 'OSW tools deleted successfully: ' || array_to_string(osw_tools, ', ');
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.delete_tools(char[]) TO api_user;

-- New: Function to get tool configuration (available channels per tools)
-- Note: This function is expensive for millions of rows per table
DROP FUNCTION IF EXISTS api.get_tool_config();
CREATE OR REPLACE FUNCTION api.get_tool_config()
  RETURNS JSONB
  LANGUAGE plpgsql
AS $$
DECLARE
  tbl_name   TEXT;
  chs        JSONB;
  result     JSONB := '{}'::JSONB;
BEGIN
  -- Loop through each tool name in the api.tools table
  FOR tbl_name IN
    SELECT osw_tool::TEXT
    FROM api.tools
  LOOP
    -- Aggregate distinct channels into a JSON array, ordered alphabetically
    EXECUTE format(
      'SELECT jsonb_agg(ch) FROM (SELECT DISTINCT ch FROM api.%I ORDER BY ch) AS temp',
      tbl_name
    ) INTO chs;

    -- Merge the new key/value pair into the result JSON,
    -- using empty array [] if the table had no rows
    result := result
              || jsonb_build_object(tbl_name, COALESCE(chs, '[]'::JSONB));
  END LOOP;

  RETURN result;
END;
$$;

GRANT EXECUTE ON FUNCTION api.get_tool_config() TO api_user;

-- Create tools_view for public access
DROP VIEW IF EXISTS api.tools_view;
CREATE OR REPLACE VIEW api.tools_view AS
SELECT * FROM api.tools;
-- GRANT ALL ON api.tools_view TO api_user;
GRANT SELECT ON api.tools_view TO api_user;

-- =====================================================================
-- Server-side time series downsampling
-- =====================================================================
-- Reduces the number of points transported to a dashboard by bucketing
-- with time_bucket() and applying one of three strategies (see
-- api.downsample_tool_channel below). Uses only core (Apache-2)
-- TimescaleDB features; no timescaledb_toolkit dependency.
--
-- IMPORTANT (unit normalization): the 'average' and 'minmax' strategies
-- compare/combine the bare numeric leaves stored in the JSONB `data`
-- column. They are only correct when all stored values of a given leaf
-- share the same unit. The OSW archive normally stores base-unit
-- normalized values, but data ingested without normalization (mixed
-- units in one channel) will produce wrong average/minmax results.
-- The 'sample' strategy returns whole real rows and is unaffected.

-- Set-returning helper: yields one row per NUMERIC leaf of a JSONB value
-- with its path. Non-numeric scalars (strings/comments, booleans, null)
-- and arrays are silently skipped. Used by the 'minmax' strategy and to
-- decide whether a channel has any numeric leaf at all.
-- Note: recursive helpers must be plpgsql, not sql. The planner inlines
-- sql functions and would try to inline a self-recursive one without bound
-- (stack depth limit exceeded). plpgsql is not inlined, so recursion runs
-- normally at execution time.
CREATE OR REPLACE FUNCTION api._jsonb_numeric_leaves(
    data jsonb,
    prefix text[] DEFAULT ARRAY[]::text[]
)
RETURNS TABLE(path text[], val numeric)
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    k text;
    v jsonb;
BEGIN
    IF jsonb_typeof(data) = 'number' THEN
        path := prefix;
        val := (data #>> '{}')::numeric;
        RETURN NEXT;
    ELSIF jsonb_typeof(data) = 'object' THEN
        FOR k, v IN SELECT key, value FROM jsonb_each(data) LOOP
            RETURN QUERY SELECT * FROM api._jsonb_numeric_leaves(v, prefix || k);
        END LOOP;
    END IF;
    RETURN;
END;
$$;
GRANT EXECUTE ON FUNCTION api._jsonb_numeric_leaves(jsonb, text[]) TO api_user;

-- Element-wise add of two same-shaped JSONB trees: numeric leaves are
-- summed, objects recursed, non-numeric leaves carried from `a`.
CREATE OR REPLACE FUNCTION api._jsonb_tree_add(a jsonb, b jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    result jsonb;
    k text;
BEGIN
    IF a IS NULL THEN RETURN b; END IF;
    IF b IS NULL THEN RETURN a; END IF;
    IF jsonb_typeof(a) = 'number' AND jsonb_typeof(b) = 'number' THEN
        RETURN to_jsonb((a #>> '{}')::numeric + (b #>> '{}')::numeric);
    ELSIF jsonb_typeof(a) = 'object' AND jsonb_typeof(b) = 'object' THEN
        result := '{}'::jsonb;
        FOR k IN
            SELECT key FROM jsonb_object_keys(a) AS t(key)
            UNION
            SELECT key FROM jsonb_object_keys(b) AS t(key)
        LOOP
            result := result || jsonb_build_object(k, api._jsonb_tree_add(a -> k, b -> k));
        END LOOP;
        RETURN result;
    ELSE
        RETURN a;
    END IF;
END;
$$;

-- Scale numeric leaves of a JSONB tree by `factor`; non-numeric kept.
CREATE OR REPLACE FUNCTION api._jsonb_tree_scale(a jsonb, factor numeric)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    result jsonb;
    k text;
    v jsonb;
BEGIN
    IF a IS NULL THEN RETURN NULL; END IF;
    IF jsonb_typeof(a) = 'number' THEN
        RETURN to_jsonb((a #>> '{}')::numeric * factor);
    ELSIF jsonb_typeof(a) = 'object' THEN
        result := '{}'::jsonb;
        FOR k, v IN SELECT key, value FROM jsonb_each(a) LOOP
            result := result || jsonb_build_object(k, api._jsonb_tree_scale(v, factor));
        END LOOP;
        RETURN result;
    ELSE
        RETURN a;
    END IF;
END;
$$;

-- Custom streaming aggregate computing a structure-preserving deep
-- average of JSONB rows. State = {"s": running sum-tree, "n": count}.
CREATE OR REPLACE FUNCTION api._deep_avg_sfunc(state jsonb, val jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN state IS NULL THEN jsonb_build_object('s', val, 'n', 1)
        ELSE jsonb_build_object(
            's', api._jsonb_tree_add(state -> 's', val),
            'n', ((state ->> 'n')::int + 1))
    END
$$;

CREATE OR REPLACE FUNCTION api._deep_avg_combine(s1 jsonb, s2 jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN s1 IS NULL THEN s2
        WHEN s2 IS NULL THEN s1
        ELSE jsonb_build_object(
            's', api._jsonb_tree_add(s1 -> 's', s2 -> 's'),
            'n', ((s1 ->> 'n')::int + (s2 ->> 'n')::int))
    END
$$;

CREATE OR REPLACE FUNCTION api._deep_avg_final(state jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    SELECT CASE
        WHEN state IS NULL OR (state ->> 'n')::int = 0 THEN NULL
        ELSE api._jsonb_tree_scale(state -> 's', 1.0 / (state ->> 'n')::numeric)
    END
$$;

DROP AGGREGATE IF EXISTS api.jsonb_deep_avg(jsonb);
CREATE AGGREGATE api.jsonb_deep_avg(jsonb) (
    SFUNC = api._deep_avg_sfunc,
    STYPE = jsonb,
    FINALFUNC = api._deep_avg_final,
    COMBINEFUNC = api._deep_avg_combine,
    PARALLEL = SAFE
);

-- Main RPC: return a downsampled view of one tool table.
--   method = 'sample'  -> one real row nearest each bucket center (N rows,
--                         schema-agnostic; the default).
--   method = 'average' -> structure-preserving deep average per bucket,
--                         bucket-center timestamp (N rows).
--   method = 'minmax'  -> real argmin/argmax row of every numeric leaf per
--                         bucket (scalar: 2N rows; composite: up to 2*K*N).
-- 'average'/'minmax' fall back to 'sample' when a channel has no numeric
-- leaf at all. Buckets are anchored to ts_start so they tile
-- [ts_start, ts_end] exactly and the last bucket ends at ts_end. With
-- edge_anchors, the first/last returned rows are the window's first/last
-- real datapoints. See the unit-normalization note above.
DROP FUNCTION IF EXISTS api.downsample_tool_channel(
    char, char, timestamptz, timestamptz, int, interval, text, boolean);
CREATE OR REPLACE FUNCTION api.downsample_tool_channel(
    osw_tool     char(35),
    ch_id        char(35)    DEFAULT NULL,
    ts_start     timestamptz DEFAULT NULL,
    ts_end       timestamptz DEFAULT NULL,
    max_points   int         DEFAULT 2000,
    bin_size     interval    DEFAULT NULL,
    method       text        DEFAULT 'sample',
    edge_anchors boolean     DEFAULT true
)
RETURNS TABLE(ts timestamptz, ch char(35), data jsonb)
LANGUAGE plpgsql STABLE AS
$func$
DECLARE
    tbl         text := format('api.%I', osw_tool);
    b           interval;
    ch_filter   text;
    bucket      text;
    core_sql    text;
    anchor_sql  text := '';
    has_numeric boolean;
    m           text := lower(coalesce(method, 'sample'));
BEGIN
    -- Default the window to the data extent when not given.
    IF ts_start IS NULL THEN
        EXECUTE format('SELECT min(ts) FROM %s', tbl) INTO ts_start;
    END IF;
    IF ts_end IS NULL THEN
        EXECUTE format('SELECT max(ts) FROM %s', tbl) INTO ts_end;
    END IF;
    IF ts_start IS NULL OR ts_end IS NULL OR ts_end <= ts_start THEN
        RETURN;  -- nothing to return
    END IF;

    -- Effective bucket width: explicit bin_size, else window / max_points.
    b := coalesce(bin_size, (ts_end - ts_start) / GREATEST(max_points, 1));
    IF b <= interval '0' THEN
        b := (ts_end - ts_start) / GREATEST(max_points, 1);
    END IF;
    b := GREATEST(b, interval '1 microsecond');

    ch_filter := CASE WHEN ch_id IS NULL THEN '' ELSE format(' AND t.ch = %L', ch_id) END;
    bucket := format('time_bucket(%L::interval, t.ts, %L::timestamptz)', b, ts_start);

    -- average/minmax require at least one numeric leaf, else use sample.
    IF m IN ('average', 'avg', 'minmax', 'min-max', 'min_max') THEN
        EXECUTE format(
            'SELECT EXISTS (SELECT 1 FROM %s t '
            'CROSS JOIN LATERAL api._jsonb_numeric_leaves(t.data) l '
            'WHERE t.ts BETWEEN %L AND %L%s LIMIT 1)',
            tbl, ts_start, ts_end, ch_filter)
        INTO has_numeric;
        IF NOT has_numeric THEN
            RAISE NOTICE 'downsample: no numeric leaf for %, falling back to sample', osw_tool;
            m := 'sample';
        END IF;
    END IF;

    IF m IN ('average', 'avg') THEN
        core_sql := format(
            'SELECT (%s + %L::interval / 2) AS ts, t.ch, api.jsonb_deep_avg(t.data) AS data '
            'FROM %s t WHERE t.ts BETWEEN %L AND %L%s GROUP BY %s, t.ch',
            bucket, b, tbl, ts_start, ts_end, ch_filter, bucket);
    ELSIF m IN ('minmax', 'min-max', 'min_max') THEN
        core_sql := format(
            'WITH leaves AS ('
            '  SELECT %s AS tb, t.ts, t.ch, t.data, l.path, l.val '
            '  FROM %s t CROSS JOIN LATERAL api._jsonb_numeric_leaves(t.data) l '
            '  WHERE t.ts BETWEEN %L AND %L%s'
            '), ranked AS ('
            '  SELECT ts, ch, data,'
            '    row_number() OVER (PARTITION BY tb, ch, path ORDER BY val ASC, ts ASC) AS rmin,'
            '    row_number() OVER (PARTITION BY tb, ch, path ORDER BY val DESC, ts ASC) AS rmax'
            '  FROM leaves'
            ') SELECT DISTINCT ts, ch, data FROM ranked WHERE rmin = 1 OR rmax = 1',
            bucket, tbl, ts_start, ts_end, ch_filter);
    ELSE  -- sample
        core_sql := format(
            'SELECT DISTINCT ON (%s, t.ch) t.ts AS ts, t.ch, t.data AS data '
            'FROM %s t WHERE t.ts BETWEEN %L AND %L%s '
            'ORDER BY %s, t.ch, abs(extract(epoch FROM t.ts - (%s + %L::interval / 2)))',
            bucket, tbl, ts_start, ts_end, ch_filter, bucket, bucket, b);
    END IF;

    IF edge_anchors THEN
        anchor_sql := format(
            ' UNION (SELECT DISTINCT ON (t.ch) t.ts, t.ch, t.data FROM %s t '
            'WHERE t.ts BETWEEN %L AND %L%s ORDER BY t.ch, t.ts ASC)'
            ' UNION (SELECT DISTINCT ON (t.ch) t.ts, t.ch, t.data FROM %s t '
            'WHERE t.ts BETWEEN %L AND %L%s ORDER BY t.ch, t.ts DESC)',
            tbl, ts_start, ts_end, ch_filter, tbl, ts_start, ts_end, ch_filter);
    END IF;

    BEGIN
        RETURN QUERY EXECUTE format(
            'SELECT ts, ch, data FROM ((%s)%s) u ORDER BY ts', core_sql, anchor_sql);
    EXCEPTION WHEN OTHERS THEN
        -- Any unexpected structure (e.g. an array where a number was
        -- expected) degrades to the schema-agnostic sample strategy.
        RAISE NOTICE 'downsample: % failed (%), falling back to sample',
            m, SQLERRM;
        core_sql := format(
            'SELECT DISTINCT ON (%s, t.ch) t.ts AS ts, t.ch, t.data AS data '
            'FROM %s t WHERE t.ts BETWEEN %L AND %L%s '
            'ORDER BY %s, t.ch, abs(extract(epoch FROM t.ts - (%s + %L::interval / 2)))',
            bucket, tbl, ts_start, ts_end, ch_filter, bucket, bucket, b);
        RETURN QUERY EXECUTE format(
            'SELECT ts, ch, data FROM ((%s)%s) u ORDER BY ts', core_sql, anchor_sql);
    END;
END;
$func$;
GRANT EXECUTE ON FUNCTION api.downsample_tool_channel(
    char, char, timestamptz, timestamptz, int, interval, text, boolean) TO api_user;

-- Support functions called within the RPC / deep-average aggregate.
GRANT EXECUTE ON FUNCTION api._jsonb_tree_add(jsonb, jsonb) TO api_user;
GRANT EXECUTE ON FUNCTION api._jsonb_tree_scale(jsonb, numeric) TO api_user;
GRANT EXECUTE ON FUNCTION api._deep_avg_sfunc(jsonb, jsonb) TO api_user;
GRANT EXECUTE ON FUNCTION api._deep_avg_combine(jsonb, jsonb) TO api_user;
GRANT EXECUTE ON FUNCTION api._deep_avg_final(jsonb) TO api_user;
GRANT EXECUTE ON FUNCTION api.jsonb_deep_avg(jsonb) TO api_user;