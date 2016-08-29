--
-- Run Table
--

DROP TABLE IF EXISTS run CASCADE;
CREATE TABLE run (

	-- Row identifier
	id		BIGSERIAL
			PRIMARY KEY,

	-- External-use identifier
	uuid		UUID
			UNIQUE
			DEFAULT gen_random_uuid(),

	-- Task this run belongs to
	task		BIGINT
			REFERENCES task(id)
			ON DELETE CASCADE,

	-- Range of times when this task will be run
	times		TSTZRANGE
			NOT NULL,

	--
	-- Information about the local system's participation in the
	-- test
	--

        -- Participant data for the local test
        part_data        JSONB,

	-- State of this run
	state	    	 INTEGER DEFAULT run_state_pending()
			 REFERENCES run_state(id),

	-- Any errors that prevented the run from being put on the
	-- schedule, used when state is run_state_nonstart().  Any
	-- test- or tool-related errors will be incorporated into the
	-- local or merged results.
	errors   	 TEXT,

	-- How it went locally, i.e., what the test returned
	-- TODO: See if this is used anywhere.
	status           INTEGER,

	-- Result from the local run
	-- TODO: Change this to local_result to prevent confusion
	result   	 JSONB,


	--
	-- Information about the whole test
	--

        -- Participant data for all participants in the test.  This is
        -- an array, with each element being the part_data for
        -- each participant.
        part_data_full   JSONB,

	-- Combined resut generated by the lead participant
	result_full    	 JSONB,

	-- Merged result generated by the tool that did the test
	result_merged  	 JSONB,

	-- Clock survey, done if the run was not successful.
	clock_survey  	 JSONB

);


-- This should be used when someone looks up the external ID.  Bring
-- the row ID a long so it can be pulled without having to consult the
-- table.
DROP INDEX IF EXISTS run_uuid;
CREATE INDEX run_uuid
ON run(uuid, id);



DROP INDEX IF EXISTS run_times;
-- GIST accelerates range-specific operators like &&
CREATE INDEX run_times ON run USING GIST (times);

-- These two indexes are used by the schedule_gap view.

DROP INDEX IF EXISTS run_times_lower;
CREATE INDEX run_times_lower ON run(lower(times), state);

DROP INDEX IF EXISTS run_times_upper;
CREATE INDEX run_times_upper ON run(upper(times));



-- Runs which could cause conflicts

CREATE OR REPLACE VIEW run_conflictable
AS
    SELECT
        run.*,
        scheduling_class.anytime,
        scheduling_class.exclusive
    FROM
        run
        JOIN task ON task.id = run.task
	JOIN test ON test.id = task.test
        JOIN scheduling_class ON scheduling_class.id = test.scheduling_class
    WHERE
        run.state <> run_state_nonstart()
        AND NOT scheduling_class.anytime
;



CREATE OR REPLACE FUNCTION run_alter()
RETURNS TRIGGER
AS $$
DECLARE
    horizon INTERVAL;
    taskrec RECORD;
    tool_name TEXT;
    run_result external_program_result;
    pdata_out JSONB;
    result_merge_input JSONB;
BEGIN

    -- TODO: What changes to a run don't we allow?


    SELECT INTO taskrec
        task.*,
        test.scheduling_class,
        scheduling_class.anytime,
        scheduling_class.exclusive
    FROM
        task
        JOIN test ON test.id = task.test
        JOIN scheduling_class ON scheduling_class.id = test.scheduling_class
    WHERE
        task.id = NEW.task;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'No task % exists.', NEW.task;
    END IF;


    -- Non-background gets bounced if trying to schedule beyond the
    -- scheduling horizon.

    SELECT INTO horizon schedule_horizon FROM configurables;
    IF taskrec.scheduling_class <> scheduling_class_background()
       AND (upper(NEW.times) - now()) > horizon THEN
        RAISE EXCEPTION 'Cannot schedule runs more than % in advance', horizon;
    END IF;


    -- Reject new runs that overlap with anything that isn't a
    -- non-starter or where this insert would cause a normal/exclusive
    -- conflict

    IF ( (TG_OP = 'INSERT')
        -- Don't care about non-starters
        AND NEW.state <> run_state_nonstart()
        -- These don't count, either.
        AND NOT taskrec.anytime
        AND ( 
            -- Exclusive can't collide with anything
            ( taskrec.exclusive
              AND EXISTS (SELECT * FROM run_conflictable
                          WHERE times && new.times) )
            -- Non-exclusive can't collide with exclusive
              OR ( NOT taskrec.exclusive
                   AND EXISTS (SELECT * FROM run_conflictable
                               WHERE exclusive AND times && new.times) )
            )
       )
    THEN
       RAISE EXCEPTION 'Run would result in a scheduling conflict.';
    END IF;


    -- Only allow time changes that shorten the run
    IF (TG_OP = 'UPDATE')
        AND ( (lower(NEW.times) <> lower(OLD.times))
              OR ( upper(NEW.times) > upper(OLD.times) ) )
    THEN
        RAISE EXCEPTION 'Runs cannot be rescheduled, only shortened.';
    END IF;

    -- Make sure UUID assignment follows a sane pattern.


    IF (TG_OP = 'INSERT') THEN

        IF taskrec.participant = 0 THEN
	    -- Lead participant should be assigning a UUID
            IF NEW.uuid IS NOT NULL THEN
                RAISE EXCEPTION 'Lead participant should not be given a run UUID.';
            END IF;
            NEW.uuid := gen_random_uuid();
        ELSE
            -- Non-leads should be given a UUID.
            IF NEW.uuid IS NULL THEN
                RAISE EXCEPTION 'Non-lead participant should not be assigning a run UUID.';
            END IF;
        END IF;

    ELSEIF (TG_OP = 'UPDATE') THEN

        IF NEW.uuid <> OLD.uuid THEN
            RAISE EXCEPTION 'UUID cannot be changed';
        END IF;

	-- TODO: Make sure part_data_full, result_ful and
	-- result_merged happen in the right order.

	NOTIFY run_change;

    END IF;


    -- TODO: When there's resource management, assign the resources to this run.

    SELECT INTO tool_name name FROM tool WHERE id = taskrec.tool; 

    -- Finished runs are what get inserted for background tasks.
    IF NEW.state <> run_state_finished() THEN

        pdata_out := row_to_json(t) FROM ( SELECT taskrec.participant AS participant,
                                           cast ( taskrec.json #>> '{test, spec}' AS json ) AS test ) t;

        run_result := pscheduler_internal(ARRAY['invoke', 'tool', tool_name, 'participant-data'], pdata_out::TEXT );
        IF run_result.status <> 0 THEN
	    RAISE EXCEPTION 'Unable to get participant data: %', run_result.stderr;
	END IF;
        NEW.part_data := regexp_replace(run_result.stdout, '\s+$', '')::JSONB;

    END IF;

    IF (TG_OP = 'UPDATE') THEN

        -- Change the state automatically if the status from the run
	-- changes.

        IF (NEW.status IS NOT NULL) THEN

            IF lower(NEW.times) > normalized_now() THEN
  	        RAISE EXCEPTION 'Cannot set state on future runs. % / %', lower(NEW.times), normalized_now();
	    END IF;

            NEW.state := CASE NEW.status
    	        WHEN 0 THEN run_state_finished()
	        ELSE        run_state_failed()
	        END;
        END IF;

	IF NOT run_state_transition_is_valid(OLD.state, NEW.state) THEN
            RAISE EXCEPTION 'Invalid transition between states (% to %).',
                OLD.state, NEW.state;
        END IF;

	-- If the full result changed, update the merged version.

       IF NEW.result_full IS NOT NULL
          AND COALESCE(NEW.result_full::TEXT, '')
	      <> COALESCE(OLD.result_full::TEXT, '') THEN

	       result_merge_input := row_to_json(t) FROM (
	           SELECT 
		       taskrec.json -> 'test' AS test,
                       NEW.result_full AS results
                   ) t;

 	       run_result := pscheduler_internal(ARRAY['invoke', 'tool', tool_name,
	           'merged-results'], result_merge_input::TEXT );
   	       IF run_result.status <> 0 THEN
                   -- TODO: This leaves the result empty.  Maybe post some sort of failure?
	           RAISE EXCEPTION 'Unable to get merged result on %: %',
		       result_merge_input::TEXT, run_result.stderr;
	       END IF;
  	      NEW.result_merged := regexp_replace(run_result.stdout, '\s+$', '')::JSONB;

	      NOTIFY result_available;

        ELSIF NEW.result_full IS NULL THEN

            NEW.result_merged := NULL;

        END IF;


    ELSIF (TG_OP = 'INSERT') THEN

        -- Make a note that this run was put on the schedule

        UPDATE task t SET runs = runs + 1 WHERE t.id = taskrec.id;

        PERFORM pg_notify('run_new', NEW.uuid::TEXT);

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_alter BEFORE INSERT OR UPDATE ON run
       FOR EACH ROW EXECUTE PROCEDURE run_alter();



-- If a task becomes disabled, remove all future runs.

CREATE OR REPLACE FUNCTION run_task_disabled()
RETURNS TRIGGER
AS $$
BEGIN
    IF NEW.enabled <> OLD.enabled AND NOT NEW.enabled THEN
        DELETE FROM run
        WHERE
            task = NEW.id
            AND lower(times) > normalized_now();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_task_disabled BEFORE UPDATE ON task
   FOR EACH ROW EXECUTE PROCEDURE run_task_disabled();


-- If the scheduling horizon changes and becomes smaller, remove runs
-- that go beyond it.

CREATE OR REPLACE FUNCTION run_horizon_change()
RETURNS TRIGGER
AS $$
BEGIN

    IF NEW.schedule_horizon < OLD.schedule_horizon THEN
        DELETE FROM run
        WHERE upper(times) > (normalized_now() + NEW.schedule_horizon);
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_horizon_change AFTER UPDATE ON configurables
    FOR EACH ROW EXECUTE PROCEDURE run_horizon_change();



-- TODO: Should do a trigger after any change to run that calls
-- run_main_minute() to update any run states.


CREATE OR REPLACE VIEW run_straggler_info
AS
    SELECT
        run.id,
        run.state,
        run.times,
        test.scheduling_class
    FROM
        run
        JOIN task on task.id = run.task
        JOIN test on test.id = task.test
;


-- Maintenance functions

CREATE OR REPLACE FUNCTION run_handle_stragglers()
RETURNS VOID
AS $$
BEGIN

    -- TODO: These should ignore background tests

    -- Runs that are still pending after their start times were
    -- missed.

    UPDATE run
    SET state = run_state_missed()
    WHERE id IN (
        SELECT id FROM run_straggler_info
        WHERE
            scheduling_class <> scheduling_class_background()
            AND state = run_state_pending()
            -- TODO: This interval should probably be a tunable.
            AND lower(times) < normalized_now() - 'PT5S'::interval
    );

    -- Runs that started and didn't report back in a timely manner

    UPDATE run
    SET state = run_state_overdue()
    WHERE id IN (
        SELECT id FROM run_straggler_info
        WHERE
            scheduling_class <> scheduling_class_background()
            AND state = run_state_running()
            -- TODO: This interval should probably be a tunable.
            AND upper(times) < normalized_now() - 'PT10S'::interval
    );

    -- Runs still running well after their expected completion times
    -- are treated as having failed.

    UPDATE run
    SET state = run_state_missed()
    WHERE id IN (
        SELECT id FROM run_straggler_info
        WHERE
            scheduling_class <> scheduling_class_background()
            AND state = run_state_overdue()
            -- TODO: This interval should probably be a tunable.
            AND upper(times) < normalized_now() - 'PT1M'::interval
    );

END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION run_purge()
RETURNS VOID
AS $$
BEGIN

    -- TODO: Remove runs older than the keep limit
    NULL;

END;
$$ LANGUAGE plpgsql;



-- Maintenance that happens four times a minute.

CREATE OR REPLACE FUNCTION run_maint_fifteen()
RETURNS VOID
AS $$
BEGIN
    PERFORM run_handle_stragglers();
    PERFORM run_purge();
END;
$$ LANGUAGE plpgsql;



-- Convenient ways to see the goings on

CREATE OR REPLACE VIEW run_status
AS
    SELECT
        run.id AS run,
	run.uuid AS run_uuid,
	task.id AS task,
	task.uuid AS task_uuid,
	test.name AS test,
	tool.name AS tool,
	run.times,
	run_state.display AS state
    FROM
        run
	JOIN run_state ON run_state.id = run.state
	JOIN task ON task.id = task
	JOIN test ON test.id = task.test
	JOIN tool ON tool.id = task.tool
    WHERE
        run.state <> run_state_pending()
	OR (run.state = run_state_pending()
            AND lower(run.times) < (now() + 'PT2M'::interval))
    ORDER BY run.times;


CREATE VIEW run_status_short
AS
    SELECT run, task, times, state
    FROM  run_status
;



--
-- API
--

-- Put a run of a task on the schedule.

CREATE OR REPLACE FUNCTION api_run_post(
    task_uuid UUID,
    start_time TIMESTAMP WITH TIME ZONE,
    run_uuid UUID,  -- NULL to assign one
    nonstart_reason TEXT = NULL
)
RETURNS UUID
AS $$
DECLARE
    task RECORD;
    time_range TSTZRANGE;
    initial_state INTEGER;
BEGIN

    SELECT INTO task * FROM task WHERE uuid = task_uuid;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'No task % exists.', task_uuid;
    END IF;

    IF run_uuid IS NULL AND task.participant <> 0 THEN
        RAISE EXCEPTION 'Cannot set run UUID as non-lead participant';
    END IF;

    start_time := normalized_time(start_time);
    time_range := tstzrange(start_time, start_time + task.duration, '[)');

    IF nonstart_reason IS NOT NULL THEN
       initial_state := run_state_nonstart();
    ELSE
       initial_state := run_state_pending();
    END IF;

    WITH inserted_row AS (
        INSERT INTO run (uuid, task, times, state, errors)
        VALUES (run_uuid, task.id, time_range, initial_state, nonstart_reason)
        RETURNING *
    ) SELECT INTO run_uuid uuid FROM inserted_row;

    RETURN run_uuid;

END;
$$ LANGUAGE plpgsql;
