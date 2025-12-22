-- start_ignore
\i fixeddecimal--opclass.sql
-- end_ignore
CREATE TABLE fixdec (id INT, d FIXEDDECIMAL(5,2)) DISTRIBUTED BY (d);

INSERT INTO fixdec (id,d) VALUES(1,-123.45);
INSERT INTO fixdec (id,d) VALUES(2,-123);
INSERT INTO fixdec (id,d) VALUES(3,-12.34);
INSERT INTO fixdec (id,d) VALUES(4,-1.34);
INSERT INTO fixdec (id,d) VALUES(5, 0.12);
INSERT INTO fixdec (id,d) VALUES(6, 1.23);
INSERT INTO fixdec (id,d) VALUES(7, 12.34);
INSERT INTO fixdec (id,d) VALUES(8, 123.45);
-- CBDB: disallow discard precision implicitly, add the expected value
-- to violate unique constraint.
INSERT INTO fixdec (id,d) VALUES(9, 123.45);
INSERT INTO fixdec (id,d) VALUES(9, 123.456);

-- Should fail
CREATE UNIQUE INDEX fixdec_d_idx ON fixdec (d);

DELETE FROM fixdec WHERE id = 9;

CREATE UNIQUE INDEX fixdec_d_idx ON fixdec (d);

SET enable_seqscan = off;

EXPLAIN (COSTS OFF) SELECT * FROM fixdec ORDER BY d;

SELECT * FROM fixdec ORDER BY d;

EXPLAIN (COSTS OFF) SELECT * FROM fixdec WHERE d = '12.34'::FIXEDDECIMAL;

SELECT * FROM fixdec WHERE d = '12.34'::FIXEDDECIMAL;

SELECT * FROM fixdec WHERE d = '-12.34'::FIXEDDECIMAL;

SELECT * FROM fixdec WHERE d = '123.45'::FIXEDDECIMAL;

DROP INDEX fixdec_d_idx;

SET client_min_messages = ERROR;
CREATE INDEX fixdec_d_idx ON fixdec USING hash (d);
RESET client_min_messages;

EXPLAIN (COSTS OFF) SELECT * FROM fixdec WHERE d = '12.34'::FIXEDDECIMAL;

SELECT * FROM fixdec WHERE d = '12.34'::FIXEDDECIMAL;

SELECT * FROM fixdec WHERE d = '-12.34'::FIXEDDECIMAL;

SELECT * FROM fixdec WHERE d = '123.45'::FIXEDDECIMAL;

DROP TABLE fixdec;

SET enable_seqscan = on;
