SET search_path TO api;

-- init extensions
CREATE EXTENSION timescaledb;

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
    EXECUTE format('SELECT api.create_hypertable(''api.%I'', ''ts'')', osw_tool);
    -- EXECUTE format('GRANT SELECT on api.%I to api_anon', osw_tool);
    EXECUTE format('GRANT ALL on api.%I to api_user', osw_tool);
END;
$$
LANGUAGE plpgsql;
GRANT EXECUTE ON FUNCTION api.create_tool_endpoint TO api_user;
ALTER DEFAULT PRIVILEGES GRANT EXECUTE ON FUNCTIONS TO PUBLIC;
GRANT EXECUTE ON FUNCTION api.create_hypertable (regclass, _timescaledb_internal.dimension_info, boolean , boolean, boolean) TO api_user;
GRANT EXECUTE ON FUNCTION api.create_hypertable (regclass, name, name, integer, name, name, anyelement, boolean, boolean, regproc, boolean, text, regproc, regproc) TO api_user;
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
GRANT EXECUTE ON FUNCTION api.create_tool(char) TO api_anon;
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
GRANT EXECUTE ON FUNCTION api.create_tools(char[]) TO api_anon;
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
GRANT EXECUTE ON FUNCTION api.delete_tool(char) TO api_anon;
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
GRANT EXECUTE ON FUNCTION api.delete_tools(char[]) TO api_anon;
GRANT EXECUTE ON FUNCTION api.delete_tools(char[]) TO api_user;

-- New: Function to get tool configuration (available channels per tools)
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
      'SELECT jsonb_agg(DISTINCT ch ORDER BY ch)
         FROM api.%I',
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

-- Create tools_view for public access
DROP VIEW IF EXISTS api.tools_view;
CREATE OR REPLACE VIEW api.tools_view AS
SELECT * FROM api.tools;
GRANT SELECT ON api.tools_view TO api_anon;
-- GRANT ALL ON api.tools_view TO api_user;
GRANT SELECT ON api.tools_view TO api_user;