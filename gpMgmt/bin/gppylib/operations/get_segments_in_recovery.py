#!/usr/bin/env python3
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.

from gppylib import gplog
from gppylib.db.catalog import RemoteQueryCommand

logger = gplog.get_default_logger()


def is_seg_in_backup_mode(hostname, port):
    """
    To check if segment is already in backup mode. If yes, then differential recovery might be
    running already to recover its mirror. And in that case the mirror should be skipped from
    being recovered again.

    In PG16, pg_is_in_backup() was removed along with exclusive backup mode.
    Use pg_backup_start_time() which returns non-null if a non-exclusive backup is in progress.

    Parameters:
        hostname: host name of source server
        port: port of source server

    Returns:
         boolean: true if backup is in progress for the segment
    """
    logger.debug(
        "Checking if backup is already in progress for the source server with host {} and port {}".format(
            hostname, port))

    sql = "SELECT pg_backup_start_time() IS NOT NULL"
    try:
        query_cmd = RemoteQueryCommand("pg_backup_start_time", sql, hostname, port)
        query_cmd.run()
        res = query_cmd.get_results()

    except Exception as e:
        raise Exception("Failed to query pg_backup_start_time() for segment with hostname {}, port {}, error: {}".format(
            hostname, str(port), str(e)))

    return res[0][0]
