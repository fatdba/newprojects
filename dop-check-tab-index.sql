SET LINESIZE 150
SET PAGESIZE 100
COLUMN table_name FORMAT A30
COLUMN index_name FORMAT A30
COLUMN table_degree FORMAT A10
COLUMN index_degree FORMAT A10

SELECT 
    i.table_name,
    i.index_name,
    t.degree AS table_degree,
    i.degree AS index_degree
FROM 
    dba_indexes i
JOIN 
    dba_tables t ON i.table_name = t.table_name AND i.owner = t.owner
WHERE 
    i.table_name IN ('GL_JE_LINES', 'GL_ARC_LINES_CSI_2020', 'GL_ARC_LINES_CSI_2021', 'GL_ARC_LINES_CSI_2022')
    AND (t.degree > 1 OR i.degree > 1)
ORDER BY 
    i.table_name, i.index_name;

CLEAR COLUMNS

