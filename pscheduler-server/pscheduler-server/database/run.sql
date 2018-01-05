--
-- Run Table
--

DO $$
DECLARE
    t_name TEXT;            -- Name of the table being worked on
    t_version INTEGER;      -- Current version of the table
    t_version_old INTEGER;  -- Version of the table at the start
BEGIN

    --
    -- Preparation
    --

    t_name := 'run';

    t_version := table_version_find(t_name);
    t_version_old := t_version;


    --
    -- Upgrade Blocks
    --

    -- Version 0 (nonexistant) to version 1
    IF t_version = 0
    THEN

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
        CREATE INDEX run_uuid ON run(uuid, id);

        -- GIST accelerates range-specific operators like &&
        CREATE INDEX run_times ON run USING GIST (times);

        -- These two indexes are used by the schedule_gap view.
        CREATE INDEX run_times_lower ON run(lower(times), state);
        CREATE INDEX run_times_upper ON run(upper(times));

	t_version := t_version + 1;

    END IF;

    -- Version 1 to version 2
    -- Adds indexes for task to aid cascading deletes
    IF t_version = 1
    THEN
        CREATE INDEX run_task ON run(task);

        t_version := t_version + 1;
    END IF;

    -- Version 2 to version 3
    -- Adds index for upcoming/current runs
    IF t_version = 2
    THEN
        CREATE INDEX run_current ON run(state)
        WHERE state in (
            run_state_pending(),
            run_state_on_deck(),
            run_state_running()
        );

        t_version := t_version + 1;
    END IF;

    -- Version 3 to version 4
    -- Rebuilds index from previous version, which didn't have
    -- IMMUTABLE versions of the run_state_* functions.
    IF t_version = 3
    THEN
        DROP INDEX IF EXISTS run_current CASCADE;
        CREATE INDEX run_current ON run(state)
        WHERE state in (
            run_state_pending(),
            run_state_on_deck(),
            run_state_running()
        );

        t_version := t_version + 1;
    END IF;

    -- Version 4 to version 5
    -- Adds state to index of upper times
    IF t_version = 4
    THEN
        DROP INDEX IF EXISTS run_times_upper;
        CREATE INDEX run_times_upper ON run(upper(times), state);

        t_version := t_version + 1;
    END IF;


    -- Version 5 to version 6
    -- Adds 'added' column
    IF t_version = 5
    THEN
        ALTER TABLE run ADD COLUMN
        added TIMESTAMP WITH TIME ZONE;

        t_version := t_version + 1;
    END IF;


    --
    -- Cleanup
    --

    PERFORM table_version_set(t_name, t_version, t_version_old);

END;
$$ LANGUAGE plpgsql;





-- Runs which could cause conflicts

DROP VIEW IF EXISTS run_conflictable;
CREATE OR REPLACE VIEW run_conflictable
AS
    SELECT
        run.*,
        task.duration,
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



-- Determine if a proposed run would have conflicts
CREATE OR REPLACE FUNCTION run_has_conflicts(
    task_id BIGINT,
    proposed_start TIMESTAMP WITH TIME ZONE
)
RETURNS BOOLEAN
AS $$
DECLARE
    taskrec RECORD;
    proposed_times TSTZRANGE;
BEGIN

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
        task.id = task_id;

    IF NOT FOUND
    THEN
        RAISE EXCEPTION 'No such task.';
    END IF;

    -- Anytime tasks don't ever count
    IF taskrec.anytime
    THEN
        RETURN FALSE;
    END IF;

    proposed_times := tstzrange(proposed_start,
        proposed_start + taskrec.duration, '[)');

    RETURN ( 
        -- Exclusive can't collide with anything
        ( taskrec.exclusive
          AND EXISTS (SELECT * FROM run_conflictable
                      WHERE times && proposed_times) )
        -- Non-exclusive can't collide with exclusive
          OR ( NOT taskrec.exclusive
               AND EXISTS (SELECT * FROM run_conflictable
                           WHERE exclusive AND times && proposed_times) )
        );

END;
$$ LANGUAGE plpgsql;



DROP TRIGGER IF EXISTS run_alter ON run CASCADE;

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


    IF TG_OP = 'INSERT' THEN
        NEW.added := now();
    ELSIF TG_OP = 'UPDATE' AND NEW.added <> OLD.added THEN
        RAISE EXCEPTION 'Insertion time cannot be updated.';
    END IF;



    -- Non-background gets bounced if trying to schedule beyond the
    -- scheduling horizon.

    SELECT INTO horizon schedule_horizon FROM configurables;
    IF taskrec.scheduling_class <> scheduling_class_background_multi()
       AND (upper(NEW.times) - normalized_now()) > horizon THEN
        RAISE EXCEPTION 'Cannot schedule runs more than % in advance (% is % outside the range %)',
            horizon, NEW.times, (upper(NEW.times) - normalized_now() - horizon),
	    tstzrange(normalized_now(), normalized_now()+horizon);
    END IF;


    -- Reject new runs that overlap with anything that isn't a
    -- non-starter or where this insert would cause a normal/exclusive
    -- conflict

    IF (TG_OP = 'INSERT') AND (NEW.state <> run_state_nonstart())
    THEN

        -- Once we start the process of deciding whether or not there
        -- would be any scheduling conflicts, no other transactions
        -- can make the same decisions based on what would be the old
        -- data.  Nonstarters don't matter because they don't result
        -- in any action by the runner.

	-- TODO: This could probably happen a lot further down after
	-- all of the other sanity checks have passed.

        LOCK TABLE run IN ACCESS EXCLUSIVE MODE;

        IF run_has_conflicts(taskrec.id, lower(NEW.times))
        THEN
           RAISE EXCEPTION 'Run would result in a scheduling conflict.';
        END IF;
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

        IF NEW.state <> OLD.state AND NEW.state = run_state_canceled() THEN
	    PERFORM pg_notify('run_canceled', NEW.id::TEXT);
        END IF;

	-- TODO: Make sure part_data_full, result_ful and
	-- result_merged happen in the right order.

	NOTIFY run_change;

    END IF;


    -- TODO: When there's resource management, assign the resources to this run.

    SELECT INTO tool_name name FROM tool WHERE id = taskrec.tool; 

    -- Finished runs are what get inserted for background tasks.
    IF TG_OP = 'INSERT' AND NEW.state <> run_state_finished() THEN

        pdata_out := row_to_json(t) FROM ( SELECT taskrec.participant AS participant,
                                           cast ( taskrec.json #>> '{test, spec}' AS json ) AS test ) t;

        run_result := pscheduler_internal(ARRAY['invoke', 'tool', tool_name, 'participant-data'], pdata_out::TEXT );
        IF run_result.status <> 0 THEN
	    RAISE EXCEPTION 'Unable to get participant data: %', run_result.stderr;
	END IF;
        NEW.part_data := regexp_replace(run_result.stdout, '\s+$', '')::JSONB;

    END IF;

    IF (TG_OP = 'UPDATE') THEN

	IF NOT run_state_transition_is_valid(OLD.state, NEW.state) THEN
            RAISE EXCEPTION 'Invalid transition between states (% to %).',
                OLD.state, NEW.state;
        END IF;


        -- Handle changes in status

        IF NEW.status IS NOT NULL
           AND ( (OLD.status IS NULL) OR (NEW.status <> OLD.status) )
        THEN
            -- Future runs are fatal
            IF lower(NEW.times) > normalized_now()
            THEN
                RAISE EXCEPTION 'Cannot set state on future runs. % / %', lower(NEW.times), normalized_now();
            END IF;

	    -- Adjust the state
	    NEW.state = CASE
                WHEN NEW.status = 0 THEN run_state_finished()
                ELSE run_state_failed()
                END;

        END IF;


	-- If the state of the run changes to finished or failed, trim
	-- its scheduled time.

	IF NEW.state <> OLD.state
            AND NEW.state IN ( run_state_finished(), run_state_overdue(),
                 run_state_missed(), run_state_failed() )
        THEN
            NEW.times = tstzrange(lower(OLD.times), normalized_now(), '[]');
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

        -- Make a note that this run was put on the schedule and
        -- update the start time if we don't have one.

        UPDATE task t
        SET
            runs = runs + 1,
            -- TODO: This skews future runs when the first run slips.
            first_start = coalesce(t.first_start, t.start, lower(NEW.times))
        WHERE t.id = taskrec.id;

        PERFORM pg_notify('run_new', NEW.uuid::TEXT);

    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_alter BEFORE INSERT OR UPDATE ON run
       FOR EACH ROW EXECUTE PROCEDURE run_alter();



-- If a task becomes disabled, remove all future runs.

DROP TRIGGER IF EXISTS run_task_disabled ON task CASCADE;

CREATE OR REPLACE FUNCTION run_task_disabled()
RETURNS TRIGGER
AS $$
BEGIN
    IF NEW.enabled <> OLD.enabled AND NOT NEW.enabled THEN

        -- Chuck future runs
        DELETE FROM run
        WHERE
            task = NEW.id
            AND lower(times) > normalized_now();

        -- Mark anything current as canceled.
	UPDATE run SET state = run_state_canceled()
	WHERE
	    run.task = NEW.id
	    AND times @> normalized_now()
	    AND state <> run_state_nonstart();
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER run_task_disabled BEFORE UPDATE ON task
   FOR EACH ROW EXECUTE PROCEDURE run_task_disabled();


-- If the scheduling horizon changes and becomes smaller, remove runs
-- that go beyond it.

DROP TRIGGER IF EXISTS run_horizon_change ON configurables CASCADE;

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



-- Maintenance functions

CREATE OR REPLACE FUNCTION run_handle_stragglers()
RETURNS VOID
AS $$
DECLARE
    straggle_time TIMESTAMP WITH TIME ZONE;
    straggle_time_bg_multi TIMESTAMP WITH TIME ZONE;
BEGIN

    -- When non-background-multi tasks are considered tardy
    SELECT INTO straggle_time
        normalized_now() - run_straggle FROM configurables;

    -- When non-background-multi tasks are considered tardy
    SELECT INTO straggle_time_bg_multi
        normalized_now() - run_straggle FROM configurables;

    -- Runs that failed to start
    UPDATE run
    SET state = run_state_missed()
    WHERE id IN (
        SELECT
            run.id
        FROM
            run
            JOIN task ON task.id = run.task
            JOIN test ON test.id = task.test
        WHERE

            -- Non-background-multi runs pending on deck after start times
            -- were missed
            ( test.scheduling_class <> scheduling_class_background_multi()
              AND lower(times) < straggle_time
              AND run.state IN ( run_state_pending(), run_state_on_deck() )
            )

            OR

            -- Background-multi runs that passed their end time
            ( test.scheduling_class = scheduling_class_background_multi()
              AND upper(times) < straggle_time_bg_multi
              AND run.state IN ( run_state_pending(), run_state_on_deck() )
            )
    );


    -- Runs that started and didn't report back in a timely manner
    UPDATE run
    SET state = run_state_overdue()
    WHERE
        upper(times) < straggle_time
        AND state = run_state_running();

END;
$$ LANGUAGE plpgsql;



CREATE OR REPLACE FUNCTION run_purge()
RETURNS VOID
AS $$
DECLARE
    purge_before TIMESTAMP WITH TIME ZONE;
BEGIN

    -- Most runs
    SELECT INTO purge_before now() - keep_runs_tasks FROM configurables;
    DELETE FROM run
    WHERE
        upper(times) < purge_before
        AND state NOT IN (run_state_pending(),
                          run_state_on_deck(),
                          run_state_running());

    -- Extra margin for anything that might actually be running
    purge_before := purge_before - 'PT1H'::INTERVAL;
    DELETE FROM run
    WHERE
        upper(times) < purge_before
        AND state IN (run_state_pending(),
                      run_state_on_deck(),
                      run_state_running());

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


CREATE OR REPLACE VIEW run_status_short
AS
    SELECT run, task, times, state
    FROM  run_status
;



--
-- API
--

-- Put a run of a task on the schedule.

-- TODO: Remove this after the first producion release.
DROP FUNCTION IF EXISTS api_run_post(UUID, TIMESTAMP WITH TIME ZONE, UUID, TEXT);

CREATE OR REPLACE FUNCTION api_run_post(
    task_uuid UUID,
    start_time TIMESTAMP WITH TIME ZONE,
    run_uuid UUID,  -- NULL to assign one
    nonstart_reason TEXT = NULL
)
RETURNS TABLE (
    succeeded BOOLEAN,  -- True if the post was successful
    new_uuid UUID,      -- UUID of run, NULL if post failed
    conflict BOOLEAN,   -- True of failed because of a conflict
    error TEXT          -- Error text if post failed
)
AS $$
DECLARE
    task RECORD;
    time_range TSTZRANGE;
    initial_state INTEGER;
    initial_status INTEGER;
BEGIN

    SELECT INTO task * FROM task WHERE uuid = task_uuid;
    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, FALSE,
            'Task does not exist'::TEXT;
        RETURN;
    END IF;

    IF run_uuid IS NULL AND task.participant <> 0 THEN
        RETURN QUERY SELECT FALSE, NULL::UUID, FALSE,
            'Cannot set run UUID as non-lead participant'::TEXT;
        RETURN;
    END IF;

    IF nonstart_reason IS NULL THEN

        -- This is a "live" run, so we lock the table down early (see
        -- run_alter() for commentary) and check early for conflicts.

        -- TODO: It would be nicer if we could catch the exception
        -- that the INSERT below would throw and bail out based on
        -- that.
        LOCK TABLE run IN ACCESS EXCLUSIVE MODE;

        IF run_has_conflicts(task.id, start_time) THEN
            RETURN QUERY SELECT FALSE, NULL::UUID, TRUE,
                'Posting this run would cause a schedule conflict'::TEXT;
            RETURN;
        END IF;

        initial_state := run_state_pending();
        initial_status := NULL;

    ELSE

        -- Nonstarters don't require conflict checks or table locks.
        initial_state := run_state_nonstart();
        initial_status := 1;  -- Nonzero means failure.

    END IF;
    
    start_time := normalized_time(start_time);
    time_range := tstzrange(start_time, start_time + task.duration, '[)');

    WITH inserted_row AS (
        INSERT INTO run (uuid, task, times, state, errors)
        VALUES (run_uuid, task.id, time_range, initial_state, nonstart_reason)
        RETURNING *
    ) SELECT INTO run_uuid uuid FROM inserted_row;

    RETURN QUERY SELECT TRUE, run_uuid, FALSE, ''::TEXT;
    RETURN;

END;
$$ LANGUAGE plpgsql;
