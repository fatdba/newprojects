
SET SERVEROUTPUT ON;
SET LINESIZE 155
COL execs FOR 999,999,999
COL min_etime FOR 999,999.99
COL max_etime FOR 999,999.99
COL avg_etime FOR 999,999.999
COL avg_lio FOR 999,999,999.9
COL norm_stddev FOR 999,999.9999
COL begin_interval_time FOR A30
COL node FOR 99999
SET PAGESIZE 50000 
SET LINESIZE 150
BREAK ON report
BREAK ON plan_hash_value ON startup_time SKIP 1

-- Main PL/SQL Block
DECLARE
    -- Cursor for the first SQL query to get SQL_IDs
    CURSOR sql_cursor IS
        SELECT sql_id
        FROM (
            SELECT sql_id, SUM(execs) AS execs,
                   MIN(avg_etime) AS min_etime,
                   MAX(avg_etime) AS max_etime,
                   stddev_etime / MIN(avg_etime) AS norm_stddev
            FROM (
                SELECT sql_id, plan_hash_value, execs, avg_etime,
                       stddev(avg_etime) OVER (PARTITION BY sql_id) AS stddev_etime
                FROM (
                    SELECT sql_id, plan_hash_value,
                           SUM(NVL(executions_delta, 0)) AS execs,
                           (SUM(elapsed_time_delta) / DECODE(SUM(NVL(executions_delta, 0)), 0, 1, SUM(executions_delta)) / 1000000) AS avg_etime
                    FROM DBA_HIST_SQLSTAT S
                    JOIN DBA_HIST_SNAPSHOT SS ON ss.snap_id = S.snap_id
                    WHERE ss.instance_number = S.instance_number
                      AND executions_delta > 0
                      AND elapsed_time_delta > 0
					  AND ss.begin_interval_time >= SYSDATE - 7  -- Last 7 days
                      AND s.snap_id > NVL('&earliest_snap_id', 0)
                    GROUP BY sql_id, plan_hash_value
                )
            )
            GROUP BY sql_id, stddev_etime
            HAVING stddev_etime / MIN(avg_etime) > NVL(TO_NUMBER('&min_stddev'), 2)
            AND MAX(avg_etime) > NVL(TO_NUMBER('&min_etime'), .1)
            ORDER BY norm_stddev
        );

    sql_record sql_cursor%ROWTYPE;
    found_sql_id BOOLEAN := FALSE;  -- Declare the variable here

BEGIN
    -- Print results of the additional query
    DBMS_OUTPUT.PUT_LINE('Results from the additional SQL query:');
    DBMS_OUTPUT.PUT_LINE('SQL_ID         | Execs     | Min Elapsed Time | Max Elapsed Time | Norm Stddev');
    DBMS_OUTPUT.PUT_LINE('----------------|-----------|------------------|------------------|------------');

    FOR r IN (
        SELECT sql_id, SUM(execs) AS execs,
               MIN(avg_etime) AS min_etime,
               MAX(avg_etime) AS max_etime,
               stddev_etime / MIN(avg_etime) AS norm_stddev
        FROM (
            SELECT sql_id, plan_hash_value, execs, avg_etime,
                   stddev(avg_etime) OVER (PARTITION BY sql_id) AS stddev_etime
            FROM (
                SELECT sql_id, plan_hash_value,
                       SUM(NVL(executions_delta, 0)) AS execs,
                       (SUM(elapsed_time_delta) / DECODE(SUM(NVL(executions_delta, 0)), 0, 1, SUM(executions_delta)) / 1000000) AS avg_etime
                FROM DBA_HIST_SQLSTAT S
                JOIN DBA_HIST_SNAPSHOT SS ON ss.snap_id = S.snap_id
                WHERE ss.instance_number = S.instance_number 
                  AND executions_delta > 0
                  AND elapsed_time_delta > 0
				  AND ss.begin_interval_time >= SYSDATE - 7  -- Last 7 days
                  AND s.snap_id > NVL('&earliest_snap_id', 0)
                GROUP BY sql_id, plan_hash_value
            )
        )
        GROUP BY sql_id, stddev_etime
        HAVING stddev_etime / MIN(avg_etime) > NVL(TO_NUMBER('&min_stddev'), 2)
        AND MAX(avg_etime) > NVL(TO_NUMBER('&min_etime'), .1)
        ORDER BY norm_stddev  -- Sort by Norm Stddev
    ) LOOP
        DBMS_OUTPUT.PUT_LINE(
            RPAD(NVL(r.sql_id, 'N/A'), 15) || ' | ' ||
            LPAD(r.execs, 9) || ' | ' ||
            LPAD(r.min_etime, 17) || ' | ' ||
            LPAD(r.max_etime, 17) || ' | ' ||
            LPAD(r.norm_stddev, 12)
        );
    END LOOP;

    -- Print a separator
    DBMS_OUTPUT.PUT_LINE('----------------|-----------|------------------|------------------|------------');

    -- Print results of the first query
    DBMS_OUTPUT.PUT_LINE('Results from the first query:');
    DBMS_OUTPUT.PUT_LINE('SQL_ID');
    DBMS_OUTPUT.PUT_LINE('-------');

    FOR sql_record IN sql_cursor LOOP
        DBMS_OUTPUT.PUT_LINE(sql_record.sql_id);
        found_sql_id := TRUE;  -- Set flag to true if we found any SQL_IDs

        -- Execute the second query for each SQL_ID
        DECLARE
            v_sql_id VARCHAR2(13) := sql_record.sql_id;  -- Assuming SQL_ID is 13 characters long

            CURSOR sql_details_cursor IS
                SELECT sql_id, plan_hash_value,
                       SUM(execs) AS execs,
                       SUM(etime) AS etime,
                       CASE 
                           WHEN SUM(execs) > 0 THEN SUM(etime) / SUM(execs) 
                           ELSE 0 
                       END AS avg_etime,
                       CASE 
                           WHEN SUM(execs) > 0 THEN SUM(cpu_time) / SUM(execs) 
                           ELSE 0 
                       END AS avg_cpu_time,
                       CASE 
                           WHEN SUM(execs) > 0 THEN SUM(lio) / SUM(execs) 
                           ELSE 0 
                       END AS avg_lio,
                       CASE 
                           WHEN SUM(execs) > 0 THEN SUM(pio) / SUM(execs) 
                           ELSE 0 
                       END AS avg_pio
                FROM (
                    SELECT ss.snap_id, ss.instance_number AS node, begin_interval_time, sql_id, plan_hash_value,
                           NVL(executions_delta, 0) AS execs,
                           elapsed_time_delta / 1000000 AS etime,
                           buffer_gets_delta AS lio,
                           disk_reads_delta AS pio,
                           cpu_time_delta / 1000000 AS cpu_time
                    FROM DBA_HIST_SQLSTAT S
                    JOIN DBA_HIST_SNAPSHOT SS ON ss.snap_id = S.snap_id AND ss.instance_number = S.instance_number
                    WHERE sql_id = v_sql_id
                )
                GROUP BY sql_id, plan_hash_value;

            sql_details_record sql_details_cursor%ROWTYPE;

        BEGIN
            DBMS_OUTPUT.PUT_LINE('Results for SQL_ID: ' || v_sql_id);
            DBMS_OUTPUT.PUT_LINE('Plan Hash Value | Execs     | Total Elapsed Time | Avg Elapsed Time | Avg CPU Time | Avg LIO | Avg PIO');
            DBMS_OUTPUT.PUT_LINE('----------------|-----------|--------------------|------------------|--------------|---------|--------');

            FOR sql_details_record IN sql_details_cursor LOOP
                DBMS_OUTPUT.PUT_LINE(
                    RPAD(NVL(sql_details_record.plan_hash_value, 0), 12) || ' | ' ||  -- Use RPAD for formatting
                    LPAD(sql_details_record.execs, 9) || ' | ' ||
                    LPAD(sql_details_record.etime, 20) || ' | ' ||
                    LPAD(sql_details_record.avg_etime, 17) || ' | ' ||
                    LPAD(sql_details_record.avg_cpu_time, 13) || ' | ' ||
                    LPAD(sql_details_record.avg_lio, 9) || ' | ' ||
                    LPAD(sql_details_record.avg_pio, 9)
                );
            END LOOP;

            DBMS_OUTPUT.PUT_LINE('----------------|-----------|--------------------|------------------|--------------|---------|--------');
        EXCEPTION
            WHEN NO_DATA_FOUND THEN
                DBMS_OUTPUT.PUT_LINE('No details found for SQL_ID: ' || v_sql_id);
        END;
    END LOOP;

    -- If no SQL_IDs were found
    IF NOT found_sql_id THEN
        DBMS_OUTPUT.PUT_LINE('No SQL_IDs found in the first query.');
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        DBMS_OUTPUT.PUT_LINE('An error occurred: ' || SQLERRM);
END;
/





Results from the additional SQL query:
SQL_ID	       | Execs	   | Min Elapsed Time | Max Elapsed Time | Norm Stddev
----------------|-----------|------------------|------------------|------------
gs13vrfs094aw	|	  6 |		.781872 |	   3.178186 | 2.1671704310
1996ddzbat9w7	|	  9 | 4.487090285714285 |	  22.554485 | 2.8471852597
2sbdv4y1gh8bz	|	 14 |	       3.971391 |	  24.408304 | 3.6387955174
3sknktxjqug1w	|	328 | .0508694430379746 |	   4.806558 | 49.192010432
cc1w6bpm0h6ad	|	 21 | .0244223333333333 | 226.5182148888888 | 6557.7393620
----------------|-----------|------------------|------------------|------------
Results from the first query:
SQL_ID
-------
gs13vrfs094aw
Results for SQL_ID: gs13vrfs094aw
Plan Hash Value | Execs     | Total Elapsed Time | Avg Elapsed Time | Avg CPU Time | Avg LIO | Avg PIO
----------------|-----------|--------------------|------------------|--------------|---------|--------
1162885451   |	       4 |	       3.127488 |	    .781872 |	   .7762915 |	98945.5 |	  0
3903005306   |	       2 |	       6.356372 |	   3.178186 |	   1.711877 |	  98947 |     97416
----------------|-----------|--------------------|------------------|--------------|---------|--------
1996ddzbat9w7
Results for SQL_ID: 1996ddzbat9w7
Plan Hash Value | Execs     | Total Elapsed Time | Avg Elapsed Time | Avg CPU Time | Avg LIO | Avg PIO
----------------|-----------|--------------------|------------------|--------------|---------|--------
2464618362   |	      58 |	     264.766837 | 4.564945465517241 | 2.08845824137 | 169552.56 | 160914.13
4156457883   |	      14 |	     322.396623 | 23.02833021428571 | 6.21442542857 | 284598.42 | 183070.85
----------------|-----------|--------------------|------------------|--------------|---------|--------
2sbdv4y1gh8bz
Results for SQL_ID: 2sbdv4y1gh8bz
Plan Hash Value | Execs     | Total Elapsed Time | Avg Elapsed Time | Avg CPU Time | Avg LIO | Avg PIO
----------------|-----------|--------------------|------------------|--------------|---------|--------
4156457883   |	      17 |	     391.210815 | 23.01240088235294 | 5.98843517647 | 270550.17 | 182924.47
2464618362   |	      86 |	     359.926889 | 4.185196383720930 | 1.91583161627 | 163897.87 | 143981.62
----------------|-----------|--------------------|------------------|--------------|---------|--------
3sknktxjqug1w
Results for SQL_ID: 3sknktxjqug1w
Plan Hash Value | Execs     | Total Elapsed Time | Avg Elapsed Time | Avg CPU Time | Avg LIO | Avg PIO
----------------|-----------|--------------------|------------------|--------------|---------|--------
0	     |	       0 |		 .00113 |		  0 |		  0 |	      0 |	  0
583453783    |	      14 |	      65.427144 | 4.673367428571428 | 4.49858178571 | 1657010.7 | 1518.6428
2003578721   |	       5 |	       8.748638 |	  1.7497276 |	  1.7271034 |	13059.8 |      65.8
1103538090   |	      95 |	     101.131242 | 1.064539389473684 | 1.05525206315 | 14415.842 | 8.2631578
2328623641   |	    2221 |	     107.231007 | .0482805074290859 | .047307577667 | 7646.0702 | 5.4416929
4064119247   |	       5 |	       8.352578 |	  1.6705156 |	  1.6569552 |	   8235 |	 .8
----------------|-----------|--------------------|------------------|--------------|---------|--------
cc1w6bpm0h6ad
Results for SQL_ID: cc1w6bpm0h6ad
Plan Hash Value | Execs     | Total Elapsed Time | Avg Elapsed Time | Avg CPU Time | Avg LIO | Avg PIO
----------------|-----------|--------------------|------------------|--------------|---------|--------
3180225096   |	      20 |	       6.046942 |	   .3023471 |	   .1745638 |	28967.6 |    1004.6
4118768231   |	    2581 |	  280148.004248 | 108.5424270623789 | 72.4430339841 | 1789335.7 | 39453.900
----------------|-----------|--------------------|------------------|--------------|---------|--------
