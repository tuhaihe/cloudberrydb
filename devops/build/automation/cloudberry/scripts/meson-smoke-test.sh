#!/usr/bin/env bash
# --------------------------------------------------------------------
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed
# with this work for additional information regarding copyright
# ownership.  The ASF licenses this file to You under the Apache
# License, Version 2.0 (the "License"); you may not use this file
# except in compliance with the License.  You may obtain a copy of the
# License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
# implied.  See the License for the specific language governing
# permissions and limitations under the License.
# --------------------------------------------------------------------
#
# Smoke test for a meson-built Apache Cloudberry installation.
#
# Checks that the install is complete, that initdb succeeds (which exercises
# catalog generation end to end), and that the MPP-specific pieces are really
# there rather than merely linked.
#
# Usage: meson-smoke-test.sh <install-prefix>
# --------------------------------------------------------------------
set -euo pipefail

PREFIX="${1:?usage: $0 <install-prefix>}"
export LD_LIBRARY_PATH="${PREFIX}/lib:${LD_LIBRARY_PATH:-}"

fail() { echo "::error::$*" >&2; exit 1; }

# --------------------------------------------------------------------
# 1. Installed artifacts
# --------------------------------------------------------------------
echo "== checking installed binaries =="
for b in postgres initdb pg_ctl psql pg_dump pg_upgrade gpfdist gpfts \
         gpmapreduce gpcheckcloud pg_alterckey; do
  [ -x "${PREFIX}/bin/${b}" ] || fail "missing bin/${b}"
  echo "  ok  bin/${b}"
done

echo "== checking GP extensions =="
for e in interconnect gp_exttable_fdw gp_toolkit gp_distribution_policy pxf_fdw; do
  [ -f "${PREFIX}/share/postgresql/extension/${e}.control" ] || fail "missing extension ${e}"
  echo "  ok  ${e}"
done

echo "== checking PAX =="
[ -f "${PREFIX}/share/postgresql/cdb_init.d/pax-cdbinit--1.0.sql" ] \
  || fail "missing generated pax-cdbinit--1.0.sql"
echo "  ok  pax-cdbinit--1.0.sql"

echo "== checking generated catalog data =="
for f in system_views_gp.sql cdb_init.d/cdb_schema.sql postgres.bki; do
  [ -f "${PREFIX}/share/postgresql/${f}" ] || fail "missing share/postgresql/${f}"
  echo "  ok  ${f}"
done

"${PREFIX}/bin/postgres" --version

# --------------------------------------------------------------------
# 2. initdb
# --------------------------------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT
DATADIR="${WORKDIR}/pgdata"

echo "== running initdb =="
"${PREFIX}/bin/initdb" -D "${DATADIR}" --no-locale --encoding=UTF8 >"${WORKDIR}/initdb.log" 2>&1 || {
  tail -30 "${WORKDIR}/initdb.log" >&2
  fail "initdb failed"
}
echo "  ok  initdb"

# --------------------------------------------------------------------
# 3. Runtime checks, in single-user mode
# --------------------------------------------------------------------
# A full postmaster needs an MPP identity (-b dbid) and a segment
# configuration; single-user mode is enough to prove the catalogs, the
# optimizer and the storage layer are functional.
run_sql() {
  printf '%s\n' "$1" | "${PREFIX}/bin/postgres" --single -D "${DATADIR}" \
    -c gp_role=utility -c optimizer=on postgres 2>&1
}

echo "== checking GP catalogs =="
run_sql "select count(*) as n from pg_class where relname in ('gp_segment_configuration', 'gp_distribution_policy', 'pg_resgroup', 'pg_appendonly');" \
  >"${WORKDIR}/catalogs.out"
grep -q 'n = "4"' "${WORKDIR}/catalogs.out" || {
  cat "${WORKDIR}/catalogs.out" >&2
  fail "expected 4 GP catalogs"
}
echo "  ok  4/4 GP catalogs present"

echo "== checking the gp_* views generated from system_views_gp.in =="
run_sql "select count(*) as n from pg_views where viewname like 'gp\\_%';" >"${WORKDIR}/views.out"
grep -qE 'n = "[1-9][0-9]*"' "${WORKDIR}/views.out" || {
  cat "${WORKDIR}/views.out" >&2
  fail "no gp_* views were created"
}
echo "  ok  $(sed -n 's/.*n = "\([0-9]*\)".*/\1/p' "${WORKDIR}/views.out" | head -1) gp_* views"

echo "== checking ORCA =="
run_sql "select gp_opt_version();" >"${WORKDIR}/orca.out"
grep -q "GPOPT version" "${WORKDIR}/orca.out" || {
  cat "${WORKDIR}/orca.out" >&2
  fail "ORCA is not available"
}
echo "  ok  $(sed -n 's/.*gp_opt_version = "\([^"]*\)".*/\1/p' "${WORKDIR}/orca.out" | head -1)"

echo "== checking append-only storage =="
run_sql "create table t_ao(a int) with (appendonly=true);" >/dev/null
run_sql "insert into t_ao select generate_series(1,100);" >/dev/null
run_sql "select count(*) as n from t_ao;" >"${WORKDIR}/ao.out"
grep -q 'n = "100"' "${WORKDIR}/ao.out" || {
  cat "${WORKDIR}/ao.out" >&2
  fail "append-only table did not return 100 rows"
}
echo "  ok  append-only table returned 100 rows"

echo
echo "Smoke test passed."
