#!/usr/bin/env bash
#
# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
version=2025.7.1
workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

url="https://github.com/modelcontextprotocol/servers/archive/refs/tags/${version}.tar.gz"
curl -fsSL "$url" | tar -xz -C "$workdir"

server_dir="$workdir/servers-${version}"
(
    cd "$server_dir"
    npm ci
    npm run build --workspace @modelcontextprotocol/server-filesystem
)

dest_dir="$repo_root/t/plugin/mcp/servers"
rm -rf "$dest_dir"
mv "$server_dir" "$dest_dir"
