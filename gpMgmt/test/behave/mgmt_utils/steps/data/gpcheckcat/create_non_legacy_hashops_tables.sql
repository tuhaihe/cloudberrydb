-- Create tables using non-legacy (new) hash ops for distribution
SET gp_use_legacy_hashops = off;

DROP TABLE IF EXISTS non_legacy_hash_table1;
CREATE TABLE non_legacy_hash_table1 (id int, name text) DISTRIBUTED BY (id);

DROP TABLE IF EXISTS non_legacy_hash_table2;
CREATE TABLE non_legacy_hash_table2 (id int, val int) DISTRIBUTED BY (id);
