SELECT 
    'CREATE ' || CASE WHEN ind.uniqueness = 'UNIQUE' THEN 'UNIQUE ' ELSE '' END || 'INDEX ' || ind.index_name || 
    ' ON ' || ind.table_owner || '.' || ind.table_name || ' (' || 
    LISTAGG(col.column_name, ', ') WITHIN GROUP (ORDER BY col.column_position) || ');' AS create_index_statement
FROM 
    dba_indexes ind
JOIN 
    dba_ind_columns col
    ON ind.index_name = col.index_name
WHERE 
    ind.table_name = 'GL_JE_LINES'
    AND ind.table_owner = 'GL'  -- Replace 'GL' with the actual owner/schema if needed
GROUP BY 
    ind.uniqueness, ind.index_name, ind.table_owner, ind.table_name
ORDER BY 
    ind.index_name;
