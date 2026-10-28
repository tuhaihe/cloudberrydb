-- regexp_not_like() is a Cloudberry addition, the negation of regexp_like()
SELECT oracle.regexp_not_like('abc', 'b');
SELECT oracle.regexp_not_like('abc', 'x');
SELECT oracle.regexp_not_like('ABC', 'b', 'i');
SELECT oracle.regexp_not_like('ABC', 'b', 'c');
SELECT oracle.regexp_not_like('ABC', 'b', NULL);
SELECT oracle.regexp_not_like(NULL, 'b') IS NULL AS null_source;
SELECT oracle.regexp_not_like('abc', NULL, 'i') IS NULL AS null_pattern;

-- newline handling follows regexp_like(): '^' only matches at line start with 'm'
SELECT oracle.regexp_not_like('foo' || chr(10) || 'bar', '^bar');
SELECT oracle.regexp_not_like('foo' || chr(10) || 'bar', '^bar', 'm');

-- evaluated on the segments, it must agree with NOT regexp_like()
CREATE TABLE gp_regexp_t (id int, s text) DISTRIBUTED BY (id);
INSERT INTO gp_regexp_t
  SELECT i, CASE WHEN i % 3 = 0 THEN 'Apple' || i ELSE 'pear' || i END
  FROM generate_series(1, 30) i;
SELECT count(*) FROM gp_regexp_t WHERE oracle.regexp_not_like(s, '^apple', 'i');
SELECT count(*) FROM gp_regexp_t
  WHERE oracle.regexp_not_like(s, '^apple', 'i')
        IS DISTINCT FROM NOT oracle.regexp_like(s, '^apple', 'i');
DROP TABLE gp_regexp_t;
