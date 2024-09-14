SET LINESIZE 150
SET PAGESIZE 50
SET TRIMOUT ON
SET TRIMSPOOL ON
SET WRAP OFF
COLUMN index_name FORMAT A30 HEADING 'Index Name'
COLUMN table_name FORMAT A20 HEADING 'Table Name'
COLUMN index_columns FORMAT A80 HEADING 'Index Columns'
SELECT
    i.index_name,
    i.table_name,
    LISTAGG(c.column_name, ', ') WITHIN GROUP (ORDER BY c.column_position) AS index_columns
FROM
    all_indexes i
JOIN
    all_ind_columns c ON i.index_name = c.index_name AND i.table_name = c.table_name
WHERE
    i.table_name IN ('GL_CODE_COMBINATIONS', 'GL_JE_LINES')
    AND i.owner = 'GL'
GROUP BY
    i.index_name,
    i.table_name
ORDER BY
    i.table_name,
    i.index_name;
