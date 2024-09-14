COLUMN sid FORMAT 9999
COLUMN serial# FORMAT 9999999
COLUMN machine FORMAT A30
COLUMN progress_pct FORMAT 99999999.00
COLUMN elapsed FORMAT A10
COLUMN remaining FORMAT A10
COLUMN sql_id FORMAT A13
COLUMN sql_text FORMAT A40
COLUMN event FORMAT A38

WITH session_info AS (
  SELECT s.sid,
         s.serial#,
         s.machine,
         s.sql_id,
         ROUND(sl.elapsed_seconds/60) || ':' || LPAD(MOD(sl.elapsed_seconds,60), 2, '0') elapsed,
         ROUND(sl.time_remaining/60) || ':' || LPAD(MOD(sl.time_remaining,60), 2, '0') remaining,
         ROUND(sl.sofar/sl.totalwork*100, 2) progress_pct,
         sw.event
  FROM   v$session s
  JOIN   v$session_longops sl ON s.sid = sl.sid AND s.serial# = sl.serial#
  JOIN   v$session_wait sw ON s.sid = sw.sid
  WHERE  s.machine NOT IN ('blackbox-datadog-agent', 'leapfrog-for-cron-worker')
)
SELECT si.sid,
       si.serial#,
       si.machine,
       si.elapsed,
       si.remaining,
       si.progress_pct,
       si.event,
       q.sql_id,
       SUBSTR(q.sql_text, 1, 40) AS sql_text
FROM   session_info si
LEFT JOIN v$sql q ON si.sql_id = q.sql_id;
