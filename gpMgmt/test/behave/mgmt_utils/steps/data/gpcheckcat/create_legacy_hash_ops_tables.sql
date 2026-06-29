-- Create tables using legacy hash ops for distribution
SET gp_use_legacy_hashops = on;

DROP TABLE IF EXISTS legacy_hash_table1;
CREATE TABLE legacy_hash_table1 (id int, name text) DISTRIBUTED BY (id);

DROP TABLE IF EXISTS legacy_hash_table2;
CREATE TABLE legacy_hash_table2 (id int, val int) DISTRIBUTED BY (id);
