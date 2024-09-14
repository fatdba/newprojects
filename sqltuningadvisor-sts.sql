DECLARE
  l_sql_tune_task_id  VARCHAR2(100);
BEGIN
  -- Create a tuning task for the specific SQL ID
  l_sql_tune_task_id := DBMS_SQLTUNE.create_tuning_task(
    sql_id => '5ctgnwy9a5qdf',
    time_limit => 21600, -- 3 hours in seconds (3 * 60 * 60)
    task_name => 'SQL_Tuning_Task_5ctgnwy9a5qdf',
    description => 'Tuning task for SQL ID 6v5t44awvgd6m'
  );

  -- Execute the tuning task
  DBMS_SQLTUNE.execute_tuning_task(task_name => l_sql_tune_task_id);

  DBMS_OUTPUT.put_line('SQL Tuning Task Started: ' || l_sql_tune_task_id);
END;
/


------------------

SELECT TASK_NAME, STATUS, MESSAGE
FROM DBA_ADVISOR_LOG
WHERE TASK_NAME = 'SQL_Tuning_Task_495kwmux28c65';
------------------

SELECT DBMS_SQLTUNE.report_tuning_task('SQL_Tuning_Task_5ctgnwy9a5qdf') AS report FROM dual;
