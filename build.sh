#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
: "${OHOS_BASE_SDK_HOME:?请设置为 OpenHarmony SDK 根目录（其下有 26.0.0/ 或 20/）}"
if [[ -n "${JAVA_HOME:-}" ]]; then export PATH="$JAVA_HOME/bin:$PATH"; fi
case ${1:-26} in
  26|api26) product=api26; sdk=26 ;;
  20|default) product=default; sdk=20 ;;
  *) printf 'Usage: bash build.sh [26|20]\n' >&2; exit 2 ;;
esac
hvigor=${HVIGOR_JS:-node_modules/@ohos/hvigor/bin/hvigor.js}
node "$hvigor" --mode module -p "product=$product" -p buildMode=release assembleHap --no-daemon
mkdir -p dist
cp "entry/build/$product/outputs/default/entry-default-unsigned.hap" "dist/wrist-git-watch-0.3.11-api$sdk-full-test-unsigned.hap"
