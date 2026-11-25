#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${OHOS_BASE_SDK_HOME:?请设置为 OpenHarmony SDK 根目录（其下有 20/）}"
if [[ -n "${JAVA_HOME:-}" ]]; then export PATH="$JAVA_HOME/bin:$PATH"; fi
hvigor=${HVIGOR_JS:-node_modules/@ohos/hvigor/bin/hvigor.js}
node "$hvigor" --mode module -p product=default -p buildMode=release assembleHap --no-daemon
mkdir -p dist
cp entry/build/default/outputs/default/entry-default-unsigned.hap dist/wrist-git-watch-0.2.0-api20-unsigned.hap
