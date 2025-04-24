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

==============

SELECT 
    owner,
    SUM(CASE 
            WHEN last_analyzed IS NOT NULL AND last_analyzed > SYSDATE - 31 THEN 1 
            ELSE 0 
        END) AS fresh_table_count,
    SUM(CASE 
            WHEN last_analyzed IS NULL OR last_analyzed <= SYSDATE - 31 THEN 1 
            ELSE 0 
        END) AS stale_table_count,
    COUNT(*) AS total_table_count
FROM 
    dba_tables
WHERE 
    owner IN ('CSUSER', 'NNUSER')
GROUP BY 
    owner
ORDER BY 
    owner;


===============================================


WITH stats_data AS (
    SELECT 
        owner,
        SUM(CASE 
                WHEN last_analyzed IS NOT NULL AND last_analyzed > SYSDATE - 31 THEN 1 
                ELSE 0 
            END) AS fresh_table_count,
        SUM(CASE 
                WHEN last_analyzed IS NULL OR last_analyzed <= SYSDATE - 31 THEN 1 
                ELSE 0 
            END) AS stale_table_count,
        COUNT(*) AS total_table_count
    FROM 
        dba_tables
    WHERE 
        owner IN ('CSUSER', 'NNUSER')
    GROUP BY 
        owner
),
size_data AS (
    SELECT 
        owner,
        ROUND(SUM(bytes) / 1024 / 1024 / 1024, 2) AS schema_size_gb
    FROM 
        dba_segments
    WHERE 
        owner IN ('CSUSER', 'NNUSER')
    GROUP BY 
        owner
)
SELECT 
    s.owner,
    s.fresh_table_count,
    s.stale_table_count,
    s.total_table_count,
    ROUND(100 * s.stale_table_count / s.total_table_count, 2) AS stale_percentage,
    sz.schema_size_gb
FROM 
    stats_data s
JOIN 
    size_data sz ON s.owner = sz.owner
ORDER BY 
    s.owner;
