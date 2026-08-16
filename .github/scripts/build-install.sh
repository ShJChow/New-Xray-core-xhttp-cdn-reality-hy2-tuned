#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

MODULES=(
  01-env.sh
  02-os-service.sh
  03-xray-install.sh
  04-input.sh
  05-base-env.sh
  07-acme-cert.sh
  08-nginx-install.sh
  09-server-config.sh
  10-service-check.sh
  11-client-config.sh
  12-subscription.sh
  13-manage-cli.sh
  14-final-output.sh
)

append_with_includes() {
  local line

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" == @@include\ * ]]; then
      append_with_includes "$ROOT_DIR/${line#@@include }"
    else
      printf '%s\n' "$line"
    fi
  done < "$1"
}

# v4.1.0：安全 / 混淆 / 优化功能统一默认开启。
# 关闭方法：FEATURE_XPADDING=false FEATURE_CDN_ECH=false bash install.sh
#
# v4.7.11：这两行原本是无条件赋值（FEATURE_XPADDING=true），会**覆盖掉**用户
# 传进来的环境变量——上面这行注释和 README 里写的关闭方法其实一直是失效的。
# 改成 ${VAR:-默认} 后才真正可覆盖。
append_profile() {
  cat <<'PROFILE'
# ==================================================
# 功能开关
# ==================================================
# FEATURE_XPADDING  XHTTP 填充混淆（xPaddingObfsMode），绕过 CDN 侧特征检测
#                   **默认开启**：它挡的是流量指纹识别，关掉不影响机密性
#                   （那由 TLS + VLESS Encryption 保证），但节点更容易被识别。
# FEATURE_CDN_ECH   是否**询问** ECH；实际是否启用由 CDN_ECH 决定，
#                   而 CDN_ECH **默认关闭**——ECH 要求先在 Cloudflare 的
#                   Edge Certificates 里开启，未满足该前置条件时启用它会
#                   直接导致 CDN 节点握手失败，默认开启对多数人是个陷阱。
# 两个都可用环境变量覆盖，无需改脚本。

FEATURE_XPADDING=${FEATURE_XPADDING:-true}
FEATURE_CDN_ECH=${FEATURE_CDN_ECH:-true}
PROFILE
}

build_one() {
  local output="$1"
  local module

  cat > "$output" <<'SCRIPTHEADER'
#!/bin/bash
set -e
SCRIPTHEADER

  for module in "${MODULES[@]}"; do
    append_with_includes "$ROOT_DIR/src/$module" >> "$output"
    if [[ "$module" == "01-env.sh" ]]; then
      append_profile >> "$output"
    fi
  done

  chmod +x "$output"
}

OUT_DIR="${OUT_DIR:-$ROOT_DIR/dist}"
mkdir -p "$OUT_DIR"

# v4.1.0 起两个版本功能开关完全一致，只保留 install.sh 作为唯一产物；
# install-xpadding.sh 保留同名输出，保证既有文档与用户的链接不失效。
build_one "$OUT_DIR/install.sh"
cp "$OUT_DIR/install.sh" "$OUT_DIR/install-xpadding.sh"

echo "Generated $OUT_DIR/install.sh and $OUT_DIR/install-xpadding.sh"
