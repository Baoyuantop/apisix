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

ARCH=${ARCH:-`(uname -m | tr '[:upper:]' '[:lower:]')`}
arch_path=""
if [[ $ARCH == "arm64" ]] || [[ $ARCH == "aarch64" ]]; then
    arch_path="arm64/"
fi

sudo apt-get -y update --fix-missing
sudo apt-get -y install wget lsb-release gnupg
sudo mkdir -p /etc/apt/keyrings
wget -qO - https://openresty.org/package/pubkey.gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/openresty.gpg
wget -qO - https://repos.apiseven.com/pubkey.gpg | sudo gpg --dearmor --yes -o /etc/apt/keyrings/api7.gpg
sudo chmod 0644 /etc/apt/keyrings/openresty.gpg /etc/apt/keyrings/api7.gpg

codename=$(lsb_release -sc)
openresty_repo="https://openresty.org/package/${arch_path}ubuntu"
if ! wget -q --spider "${openresty_repo}/dists/${codename}/Release"; then
    codename=noble
fi
echo "deb [signed-by=/etc/apt/keyrings/openresty.gpg] ${openresty_repo} ${codename} main" \
    | sudo tee /etc/apt/sources.list.d/openresty.list
echo "deb [signed-by=/etc/apt/keyrings/api7.gpg] https://repos.apiseven.com/packages/${arch_path}debian bullseye main" \
    | sudo tee /etc/apt/sources.list.d/api7.list

sudo apt-get update
sudo apt-get install -y openresty-pcre-dev openresty-zlib-dev build-essential gcc g++ cpanminus

SSL_LIB_VERSION=${SSL_LIB_VERSION-openssl}
ENABLE_FIPS=${ENABLE_FIPS:-"false"}

if [ "$OPENRESTY_VERSION" == "source" ]; then
    if [ "$SSL_LIB_VERSION" == "tongsuo" ]; then
        export openssl_prefix=/usr/local/tongsuo
        export zlib_prefix=$OPENRESTY_PREFIX/zlib
        export pcre_prefix=$OPENRESTY_PREFIX/pcre

        export cc_opt="-DNGX_LUA_ABORT_AT_PANIC -I${zlib_prefix}/include -I${pcre_prefix}/include -I${openssl_prefix}/include"
        export ld_opt="-L${zlib_prefix}/lib -L${pcre_prefix}/lib -L${openssl_prefix}/lib64 -Wl,-rpath,${zlib_prefix}/lib:${pcre_prefix}/lib:${openssl_prefix}/lib64"
    fi
fi

if [ -n "${PREBUILT_RUNTIME_TARBALL:-}" ]; then
    echo "Installing prebuilt APISIX Runtime from ${PREBUILT_RUNTIME_TARBALL}"
    test -f "${PREBUILT_RUNTIME_TARBALL}"
    sudo rm -rf /usr/local/openresty
    sudo tar -xzf "${PREBUILT_RUNTIME_TARBALL}" -C /usr/local/
    ldd /usr/local/openresty/nginx/sbin/nginx
    /usr/local/openresty/bin/openresty -V
    sha256sum /usr/local/openresty/nginx/sbin/nginx
    if [ -f /usr/local/openresty/.custom-runtime-meta ]; then
        cat /usr/local/openresty/.custom-runtime-meta
    fi
else
    install_apisix_runtime

    if [ ! "$ENABLE_FIPS" == "true" ]; then
    curl -o /usr/local/openresty/openssl3/ssl/openssl.cnf \
        https://raw.githubusercontent.com/api7/apisix-build-tools/apisix-runtime/${APISIX_RUNTIME}/conf/openssl3/openssl.cnf
    fi
fi

# patch lua-resty-events
sed -i 's/log(ERR, "event worker failed: ", perr)/log(ngx.WARN, "event worker failed: ", perr)/' /usr/local/openresty/lualib/resty/events/worker.lua
