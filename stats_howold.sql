SELECT 
    owner, 
    table_name, 
    num_rows, 
    blocks, 
    TO_CHAR(last_analyzed, 'DD-MON-YY') AS last_analyzed,
    CASE 
        WHEN last_analyzed IS NOT NULL AND last_analyzed > SYSDATE - 31 THEN 'FRESH'
        ELSE 'STALE'
    END AS stats,
    TRUNC(SYSDATE - last_analyzed) AS days_since_last_analyzed
FROM 
    dba_tables
WHERE 
    owner IN ('CSUSER', 'NNUSER')
ORDER BY 
    owner, table_name;


==========

    SELECT 
    owner, 
    table_name, 
    num_rows, 
    blocks, 
    TO_CHAR(last_analyzed, 'DD-MON-YY') AS last_analyzed,
    CASE 
        WHEN last_analyzed IS NOT NULL AND last_analyzed > SYSDATE - 31 THEN 'FRESH'
        ELSE 'STALE'
    END AS stats,
    TRUNC(SYSDATE - last_analyzed) AS days_since_last_analyzed,
    partitioned
FROM 
    dba_tables
WHERE 
    owner IN ('CSUSER', 'NNUSER')
ORDER BY 
    owner, table_name;



==========

SELECT owner, COUNT(*) AS stale_table_count
FROM (
  SELECT owner,
         CASE
           WHEN last_analyzed IS NOT NULL AND last_analyzed > SYSDATE - 31 THEN 'FRESH'
           ELSE 'STALE'
         END AS stats
  FROM dba_tables
  WHERE owner IN ('CSUSER', 'NNUSER')
)
WHERE stats = 'STALE'
GROUP BY owner;

