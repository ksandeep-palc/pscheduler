--
-- Table of Test Types
--

-- NOTE: Rows in this table should only be maintained (i.e., inserted
-- or updated) using the test_upsert() function.
-- TODO: Use native upserting when Pg is upgraded to 9.5


DO $$
DECLARE
    t_name TEXT;            -- Name of the table being worked on
    t_version INTEGER;      -- Current version of the table
    t_version_old INTEGER;  -- Version of the table at the start
BEGIN

    --
    -- Preparation
    --

    t_name := 'test';

    t_version := table_version_find(t_name);
    t_version_old := t_version;


    --
    -- Upgrade Blocks
    --

    -- Version 0 (nonexistant) to version 1
    IF t_version = 0
    THEN

        CREATE TABLE test (

        	-- Row identifier
        	id		BIGSERIAL
        			PRIMARY KEY,

        	-- Original JSON
        	json		JSONB
        			NOT NULL,

        	-- Test Name
        	name		TEXT
        			UNIQUE NOT NULL,

        	-- Verbose description
        	description	TEXT,

        	-- Version
        	version		NUMERIC
        			NOT NULL,

        	-- When this record was last updated
        	updated		TIMESTAMP WITH TIME ZONE,

        	-- Whether or not the test is currently available
        	available	BOOLEAN
        			DEFAULT TRUE,

                -- Scheduling class for this type of test
        	scheduling_class INTEGER
                                NOT NULL
        			REFERENCES scheduling_class(id)
        			-- Deletes should never happen but for consistency...
        			ON DELETE CASCADE
        );

	t_version := t_version + 1;

    END IF;

    -- Version 1 to version 2
    --IF t_version = 1
    --THEN
    --    ALTER TABLE ...
    --    t_version := t_version + 1;
    --END IF;


    --
    -- Cleanup
    --

    PERFORM table_version_set(t_name, t_version, t_version_old);

END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION test_json_is_valid(json JSONB)
RETURNS BOOLEAN
AS $$
BEGIN
    RETURN (json ->> 'name') IS NOT NULL
      AND text_to_numeric(json ->> 'version', false) IS NOT NULL
      AND scheduling_class_find(json ->> 'scheduling-class') IS NOT NULL
      ;
END;
$$ LANGUAGE plpgsql;



DROP TRIGGER IF EXISTS test_alter ON test CASCADE;

CREATE OR REPLACE FUNCTION test_alter()
RETURNS TRIGGER
AS $$
BEGIN
    IF NOT test_json_is_valid(NEW.json) THEN
        RAISE EXCEPTION 'Test JSON is invalid.';
    END IF;

    NEW.name := NEW.json ->> 'name';
    NEW.description := NEW.json ->> 'description';
    NEW.version := text_to_numeric(NEW.json ->> 'version');
    NEW.scheduling_class := scheduling_class_find(NEW.json ->> 'scheduling-class');

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER test_alter
BEFORE INSERT OR UPDATE
ON test
FOR EACH ROW
    EXECUTE PROCEDURE test_alter();



-- Insert a new test or update an existing one by name
CREATE OR REPLACE FUNCTION test_upsert(new_json JSONB)
RETURNS VOID
AS $$
DECLARE
    existing_id BIGINT;
    new_name TEXT;
BEGIN

   new_name := (new_json ->> 'name')::TEXT;

   SELECT id from test into existing_id WHERE test.name = new_name;

   IF NOT FOUND THEN

      -- Legitimately-new row.
      INSERT INTO test (json, updated, available)
      VALUES (new_json, now(), true);

   ELSE

     -- Update of existing row.
     UPDATE test
     SET
       json = new_json,
       updated = now(),
       available = true
     WHERE id = existing_id;

   END IF;

END;
$$ LANGUAGE plpgsql;




-- Function to run at startup.
CREATE OR REPLACE FUNCTION test_boot()
RETURNS VOID
AS $$
DECLARE
    run_result external_program_result;
    test_list JSONB;
    test_name TEXT;
    test_enumeration JSONB;
BEGIN
    run_result := pscheduler_internal(ARRAY['list', 'test']);
    IF run_result.status <> 0 THEN
       RAISE EXCEPTION 'Unable to list installed tests: %', run_result.stderr;
    END IF;

    test_list := run_result.stdout::JSONB;

    FOR test_name IN (select * from jsonb_array_elements_text(test_list))
    LOOP
	run_result := pscheduler_internal(ARRAY['invoke', 'test', test_name, 'enumerate']);
        IF run_result.status <> 0 THEN
         RAISE EXCEPTION 'Test "%" failed to enumerate: %',
	       test_name, run_result.stderr;
        END IF;

	test_enumeration := run_result.stdout::JSONB;

	IF NOT test_json_is_valid(test_enumeration) THEN
	    RAISE WARNING 'Test "%" enumeration is invalid', test_name;
	    CONTINUE;
	END IF;

	PERFORM test_upsert(test_enumeration);

    END LOOP;

    -- Disable, but don't remove, tests that aren't installed.
    UPDATE test SET available = FALSE WHERE updated < now();
    -- TODO: Should also can anything on the schedule.  (Do that elsewhere.)
END;
$$ LANGUAGE plpgsql;
