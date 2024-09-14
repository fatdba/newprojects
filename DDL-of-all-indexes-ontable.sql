SET LINESIZE 200;
SET PAGESIZE 0;

-- Output the DDL of all indexes on the specified table, including tablespace and degree
SELECT 'CREATE ' ||
       DECODE(i.uniqueness, 'UNIQUE', 'UNIQUE ', '') ||
       'INDEX ' || i.index_name || ' ON ' || i.table_owner || '.' || i.table_name ||
       ' (' || LISTAGG(c.column_name, ', ') WITHIN GROUP (ORDER BY c.column_position) || ')' ||
       ' TABLESPACE ' || i.tablespace_name ||
       CASE WHEN i.degree > 0 THEN ' PARALLEL ' || i.degree ELSE '' END ||
       ';' AS ddl_statement
FROM   DBA_INDEXES i
JOIN   DBA_IND_COLUMNS c
ON     i.index_name = c.index_name
AND    i.table_owner = c.table_owner
AND    i.table_name = c.table_name
WHERE  i.table_name IN ('GL_ARC_HEADERS_CSI_2020','GL_ARC_HEADERS_CSI_2021','GL_ARC_HEADERS_CSI_2022','GL_ARC_LINES_CSI_2020','GL_ARC_LINES_CSI_2021','GL_ARC_LINES_CSI_2022','GL_ARC_BATCHES_CSI_2020', 'GL_ARC_BAT
CHES_CSI_2021', 'GL_ARC_BATCHES_CSI_2022')
AND    i.table_owner = 'XXGLARC'
GROUP BY i.index_name, i.table_owner, i.table_name, i.uniqueness, i.tablespace_name, i.degree
ORDER BY i.index_name;
