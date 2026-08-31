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
# Bring up a real multi-segment demo cluster on a meson-built Apache
# Cloudberry installation and exercise the MPP paths against it.
#
# meson-smoke-test.sh only runs single-user mode, which proves the catalogs and
# storage layers work but never starts a segment. This goes further: it uses
# gpinitsystem from the installed gpMgmt tree, so it also proves that the
# management utilities, the generated cloudberry-env.sh and the Python
# dependencies are all in place -- the parts a single-node smoke test cannot
# reach.
#
# Usage: meson-cluster-test.sh <install-prefix> <source-dir>
# --------------------------------------------------------------------
set -euo pipefail

PREFIX="${1:?usage: $0 <install-prefix> <source-dir>}"
SRCDIR="${2:?usage: $0 <install-prefix> <source-dir>}"

fail() { echo "::error::$*" >&2; exit 1; }
section() { echo; echo "== $* =="; }

# --------------------------------------------------------------------
# Environment
# --------------------------------------------------------------------
section "sourcing cloudberry-env.sh"
# gpMgmt/Makefile generates this into the install prefix; the meson build does
# the same. demo_cluster.sh and every gpMgmt utility depend on it.
[ -f "${PREFIX}/cloudberry-env.sh" ] || fail "missing ${PREFIX}/cloudberry-env.sh"
# shellcheck disable=SC1090,SC1091
source "${PREFIX}/cloudberry-env.sh"
echo "  GPHOME=${GPHOME:-unset}"
[ -n "${GPHOME:-}" ] || fail "cloudberry-env.sh did not set GPHOME"

section "checking the Python dependencies gpMgmt needs"
# The meson build deliberately does not vendor these: --with-pythonsrc-ext
# downloads them from PyPI during install, which has no meson equivalent, so
# they are external runtime dependencies. gpinitsystem fails without them.
for m in psutil pygresql yaml; do
  mod="${m}"
  [ "${m}" = "pygresql" ] && mod="pg"
  python3 -c "import ${mod}" 2>/dev/null && echo "  ok  ${m}" \
    || fail "python module ${m} is missing; install python-dependencies.txt"
done

section "verifying ssh to localhost"
# gpinitsystem drives segments over ssh even for a single-host demo cluster.
ssh -o BatchMode=yes -o StrictHostKeyChecking=no "$(hostname)" 'true' \
  || fail "passwordless ssh to $(hostname) does not work"
echo "  ok  ssh $(hostname)"

# --------------------------------------------------------------------
# Cluster
# --------------------------------------------------------------------
section "creating the demo cluster"
# gpAux/gpdemo/Makefile uses `-include src/Makefile.global`, so this target
# works on a tree that was never configured with autoconf.
make -C "${SRCDIR}/gpAux/gpdemo" create-demo-cluster \
  || fail "demo cluster creation failed"

# shellcheck disable=SC1090,SC1091
source "${SRCDIR}/gpAux/gpdemo/gpdemo-env.sh" \
  || fail "could not source gpdemo-env.sh"
echo "  ok  cluster created, PGPORT=${PGPORT:-unset}"

cleanup() {
  echo
  echo "== tearing down the demo cluster =="
  make -C "${SRCDIR}/gpAux/gpdemo" destroy-demo-cluster >/dev/null 2>&1 || true
}
trap cleanup EXIT

section "restarting the cluster"
gpstop -a  || fail "gpstop failed"
gpstart -a || fail "gpstart failed"
gpstate    || fail "gpstate failed"

# --------------------------------------------------------------------
# MPP checks
# --------------------------------------------------------------------
q() { psql -d postgres -tAc "$1"; }

section "segment configuration"
q "select role, count(*) from gp_segment_configuration group by role order by role;" \
  | sed 's/^/    /'
NPRIM=$(q "select count(*) from gp_segment_configuration where role='p' and content >= 0;")
[ "${NPRIM}" -ge 1 ] || fail "no primary segments registered"
echo "  ok  ${NPRIM} primary segment(s)"

section "data really distributes across segments"
q "create table t_dist(a int, b text) distributed by (a);" >/dev/null
q "insert into t_dist select i, 'v'||i from generate_series(1,1000) i;" >/dev/null
NSEG=$(q "select count(distinct gp_segment_id) from t_dist;")
TOTAL=$(q "select count(*) from t_dist;")
[ "${TOTAL}" = "1000" ] || fail "expected 1000 rows, got ${TOTAL}"
[ "${NSEG}" -ge 2 ] || fail "table did not distribute: rows on ${NSEG} segment(s)"
echo "  ok  1000 rows spread over ${NSEG} segments"

section "a plan uses Motion"
q "explain select count(*) from t_dist;" | grep -qi motion \
  || fail "no Motion node in a distributed aggregate plan"
echo "  ok  Motion present"

section "ORCA plans a distributed query"
q "select gp_opt_version();" | sed 's/^/    /'
q "set optimizer=on; select count(*) from t_dist a join t_dist b using (a);" \
  | tail -1 | grep -q '^1000$' || fail "ORCA-planned join returned unexpected rows"
echo "  ok  ORCA join returned 1000 rows"

section "append-only storage, distributed"
q "create table t_ao(a int) using ao_row distributed by (a);" >/dev/null
q "insert into t_ao select generate_series(1,500);" >/dev/null
[ "$(q 'select count(*) from t_ao;')" = "500" ] || fail "AO table wrong row count"
echo "  ok  ao_row returned 500 rows"

section "PAX storage, distributed"
if q "select count(*) from pg_am where amname='pax';" | grep -q '^1$'; then
  q "create table t_pax(a int, b text) using pax distributed by (a);" >/dev/null
  q "insert into t_pax select i, 'p'||i from generate_series(1,500) i;" >/dev/null
  [ "$(q 'select count(*) from t_pax;')" = "500" ] || fail "PAX table wrong row count"
  echo "  ok  pax returned 500 rows"
else
  echo "  skip  pax access method not present in this build"
fi

section "resource groups are queryable"
q "select count(*) from gp_toolkit.gp_resgroup_config;" | sed 's/^/    rows: /'

echo
echo "Cluster test passed."
