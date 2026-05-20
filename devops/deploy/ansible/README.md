<!--
  Licensed to the Apache Software Foundation (ASF) under one
  or more contributor license agreements.  See the NOTICE file
  distributed with this work for additional information
  regarding copyright ownership.  The ASF licenses this file
  to you under the Apache License, Version 2.0 (the
  "License"); you may not use this file except in compliance
  with the License.  You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

  Unless required by applicable law or agreed to in writing,
  software distributed under the License is distributed on an
  "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
  KIND, either express or implied.  See the License for the
  specific language governing permissions and limitations
  under the License.
-->

# Apache Cloudberry Deployment Via Ansible

This directory contains an Ansible playbook for deploying Apache Cloudberry on physical or virtual machines via Ansible.

## Quick Start

```bash
# 1. Edit inventory and variables
vi ansible/inventory/hosts       # set hostnames and IPs
vi ansible/group_vars/all.yml    # set password, disk, segments, etc.

# 2. Run the playbook
ansible-playbook ansible/site.yml -i ansible/inventory/hosts \
    -e package_path=./apache-cloudberry-db-incubating-2.1.0-1.el9.x86_64.rpm
```

## Cluster Layout (default)

| Host | Role |
|------|------|
| cdw  | Coordinator |
| scdw | Standby Coordinator |
| sdw1 | Segment Host 1 |
| sdw2 | Segment Host 2 |
| sdw3 | Segment Host 3 |

Each segment host runs 2 primary segments and 2 mirror segments (spread mirroring).

## Prerequisites

- Ansible installed on the control machine (tested with ansible-core 2.14+)
- Root SSH access from the control machine to all hosts
- All hosts have Rocky Linux 8/9 or compatible OS installed
- Apache Cloudberry RPM/DEB package downloaded to the control machine

Ansible 2.10+ requires the following collections to be installed separately:

```bash
ansible-galaxy collection install ansible.posix community.general community.crypto
```

To suppress the Python `crypt` module deprecation warning, install `passlib`:

```bash
pip3 install passlib
```

## Directory Structure

```
ansible/
├── ansible.cfg           # disable host key checking
├── site.yml              # main playbook
├── inventory/
│   └── hosts             # hostnames and IPs
└── group_vars/
    └── all.yml           # deployment variables
```

## What the Playbook Does

1. Disable SELinux and firewall
2. Configure hostnames and `/etc/hosts`
3. Set kernel parameters (`sysctl`)
4. Set resource limits (`limits.conf`)
5. Configure XFS mount and disk I/O settings
6. Disable Transparent Huge Pages
7. Disable IPC object removal
8. Configure SSH thresholds
9. Synchronize system clocks (chronyd)
10. Create `gpadmin` user with sudo
11. Install Apache Cloudberry package on all hosts
12. Configure passwordless SSH for gpadmin (N-N)
13. Create data storage directories
14. Initialize the cluster with `gpinitsystem`
15. Set environment variables in `.bashrc`

## After Deployment

```bash
su - gpadmin
psql -d warehouse    # connect to the database
gpstate -s           # check cluster status
```
