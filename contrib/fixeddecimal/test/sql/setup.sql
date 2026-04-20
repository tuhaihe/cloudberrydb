SELECT am.amname, opc.opcname
FROM pg_opclass opc
JOIN pg_am am ON am.oid = opc.opcmethod
JOIN pg_namespace nsp ON nsp.oid = opc.opcnamespace
WHERE nsp.nspname = current_schema()
  AND opc.opcname IN (
    'fixeddecimal_minmax_ops',
    'fixeddecimal_ops',
    'fixeddecimal_numeric_ops',
    'numeric_fixeddecimal_ops',
    'fixeddecimal_int4_ops',
    'int4_fixeddecimal_ops',
    'fixeddecimal_int2_ops',
    'int2_fixeddecimal_ops'
  )
ORDER BY am.amname, opc.opcname;
