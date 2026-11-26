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

source ./ci/common.sh

export_version_info

RUNTIME_MODE=${RUNTIME_MODE:-custom}
PATCH_DIR=${PATCH_DIR:-${PWD}/ci/patches}
OUTPUT_TARBALL=${OUTPUT_TARBALL:-apisix-runtime-1.3.2-custom.tar.gz}

repo_root=$PWD

if [[ "$RUNTIME_MODE" == "baseline" ]]; then
    echo "Building official baseline APISIX Runtime (${APISIX_RUNTIME})..."
    OPENRESTY_VERSION=source ./ci/linux-install-openresty.sh
elif [[ "$RUNTIME_MODE" == "custom" ]]; then
    echo "Building standard APISIX Runtime ${APISIX_RUNTIME} with patches from ${PATCH_DIR}..."

    if [[ ! -d "$PATCH_DIR" ]]; then
        echo "Patch directory not found: $PATCH_DIR" >&2
        exit 2
    fi

    if [[ ! -f "$PATCH_DIR/series" ]] && ! compgen -G "$PATCH_DIR/*.patch" > /dev/null; then
        echo "No patch files found in $PATCH_DIR (expected series or *.patch)." >&2
        exit 2
    fi

    ARCH=${ARCH:-$(uname -m | tr '[:upper:]' '[:lower:]')}
    arch_path=""
    if [[ "$ARCH" == "arm64" ]] || [[ "$ARCH" == "aarch64" ]]; then
        arch_path="arm64/"
    fi

    wget -qO - https://openresty.org/package/pubkey.gpg | sudo apt-key add -
    wget -qO - http://repos.apiseven.com/pubkey.gpg | sudo apt-key add -
    sudo apt-get -y update --fix-missing
    sudo apt-get -y install software-properties-common
    sudo add-apt-repository -y "deb https://openresty.org/package/${arch_path}ubuntu $(lsb_release -sc) main"
    sudo add-apt-repository -y "deb http://repos.apiseven.com/packages/${arch_path}debian bullseye main"

    sudo apt-get update
    sudo apt-get install -y openresty-pcre-dev openresty-zlib-dev build-essential gcc g++ cpanminus git python3

    workdir=$(mktemp -d)
    trap 'rm -rf "$workdir"' EXIT

    export runtime_version=${APISIX_RUNTIME}
    build_script="$workdir/build-apisix-runtime.sh"
    patch_marker="$workdir/patches-applied.marker"

    wget -q "https://raw.githubusercontent.com/api7/apisix-build-tools/apisix-runtime/${APISIX_RUNTIME}/build-apisix-runtime.sh" -O "$build_script"
    chmod +x "$build_script"

    # Inject patch application right before OpenResty's ./configure step
    python3 - "$build_script" "$PATCH_DIR" "$patch_marker" <<'PYEOF'
import re
import sys
from pathlib import Path

script_path = Path(sys.argv[1])
patch_dir = sys.argv[2]
marker_path = sys.argv[3]
content = script_path.read_text(encoding="utf-8")

hook = f"""
# --- Begin custom runtime patch hook ---
echo "Applying custom patches from {patch_dir} in $(pwd)..."
if [ -f "{patch_dir}/series" ]; then
    while IFS= read -r pfile; do
        [ -z "$pfile" ] && continue
        case "$pfile" in \\#*) continue ;; esac
        echo "Applying patch: $pfile"
        git apply --check "{patch_dir}/$pfile"
        git apply "{patch_dir}/$pfile"
    done < "{patch_dir}/series"
else
    for pfile in "{patch_dir}"/*.patch; do
        echo "Applying patch: $(basename "$pfile")"
        git apply --check "$pfile"
        git apply "$pfile"
    done
fi
if [ -f "{patch_dir}/runtime-1.3.2.sha256" ]; then
    sha256sum -c "{patch_dir}/runtime-1.3.2.sha256"
fi
touch "{marker_path}"
# --- End custom runtime patch hook ---
"""

# Locate the OpenResty ./configure line (following 'cd openresty')
or_cd = re.search(r"^[ \t]*cd[ \t]+openresty[^\n]*$", content, re.MULTILINE)
if not or_cd:
    sys.stderr.write("Could not find 'cd openresty...' in build-apisix-runtime.sh\n")
    sys.exit(1)

cfg = re.search(r"^[ \t]*\./configure\b", content[or_cd.end():], re.MULTILINE)
if not cfg:
    sys.stderr.write("Could not find OpenResty './configure' after 'cd openresty' in build-apisix-runtime.sh\n")
    sys.exit(1)

idx = or_cd.end() + cfg.start()
patched = content[:idx] + hook + content[idx:]
script_path.write_text(patched, encoding="utf-8")
PYEOF

    (
        cd "$workdir"
        ./build-apisix-runtime.sh latest
    )

    if [[ ! -f "$patch_marker" ]]; then
        echo "Custom patch hook did not execute!" >&2
        exit 1
    fi

    curl -fsSL -o /usr/local/openresty/openssl3/ssl/openssl.cnf \
        "https://raw.githubusercontent.com/api7/apisix-build-tools/apisix-runtime/${APISIX_RUNTIME}/conf/openssl3/openssl.cnf"

    # Match APISIX CI's lua-resty-events log level patch in ci/linux-install-openresty.sh
    sed -i 's/log(ERR, "event worker failed: ", perr)/log(ngx.WARN, "event worker failed: ", perr)/' \
        /usr/local/openresty/lualib/resty/events/worker.lua
else
    echo "Unsupported RUNTIME_MODE: $RUNTIME_MODE (expected 'custom' or 'baseline')" >&2
    exit 2
fi

echo "Verifying built APISIX Runtime..."
ldd /usr/local/openresty/nginx/sbin/nginx | tee /tmp/runtime-ldd.txt
if grep -q 'not found' /tmp/runtime-ldd.txt; then
    echo "Missing shared library dependency in built nginx binary!" >&2
    exit 1
fi

/usr/local/openresty/bin/openresty -V
nginx_sha256=$(sha256sum /usr/local/openresty/nginx/sbin/nginx | awk '{print $1}')
echo "Built nginx SHA-256: ${nginx_sha256}"

cat <<EOF > /usr/local/openresty/.custom-runtime-meta
runtime_mode=${RUNTIME_MODE}
apisix_runtime=${APISIX_RUNTIME}
nginx_sha256=${nginx_sha256}
built_at_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

tar -czf "${repo_root}/${OUTPUT_TARBALL}" -C /usr/local openresty
ls -lh "${repo_root}/${OUTPUT_TARBALL}"
