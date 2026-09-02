# ==================================================
# 基础输出与环境检测
# ==================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "请使用 root 用户运行此脚本"

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  OS_ID="$ID"
else
  error "无法识别当前系统发行版"
fi

# ==================================================
# 项目常量
# ==================================================

PROJECT_NAME="xray-xhttp"
PROJECT_VERSION="4.7.21"
PROJECT_REPO="ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned"
MANAGE_CMD="xh"
MANAGE_BIN="/usr/local/bin/${MANAGE_CMD}"
STATE_DIR="/etc/xhttp-cdn"
NODE_ENV_FILE="${STATE_DIR}/node.env"
SYSCTL_CONF="/etc/sysctl.d/99-xray-xhttp.conf"
LIMITS_CONF="/etc/security/limits.d/99-xray-xhttp.conf"

# ==================================================
# 功能开关（均可用环境变量覆盖）
#   FEATURE_KEEPALIVE   保活自愈与开机自启
#   FEATURE_AUTOUPDATE  每周自动更新 Xray-core
#   AUTO=1              非交互一键部署
#
# v2.0.0：安装期不再做任何参数优化。渲染出的 xray-config.json 与上游
# Yulinanami/my-xhttp-cdn-config 逐字节一致，nginx.conf 只保留正确性修复。
# 内核 / 句柄 / systemd 层的调优全部收进管理命令，按需 `xh tuning on`。
# ==================================================

FEATURE_KEEPALIVE=${FEATURE_KEEPALIVE:-true}
FEATURE_AUTOUPDATE=${FEATURE_AUTOUPDATE:-true}
AUTO=${AUTO:-0}

# ==================================================
# 节点集：默认 6 条，全部由 Xray 单核心提供
# ==================================================
#   1. Vless-xhttp-h3-cdn    经 CDN，h3/QUIC
#   2. Vless-xhttp-h3-direct 直连 UDP 8446，h3/QUIC
#   3. Hysteria2-obfs        直连 UDP 8443，Salamander 混淆
#   4. Vless-reality-vision  直连 TCP 443，Vision
#   5. Vless-xhttp-reality   直连 TCP 443，XHTTP 上下行不分离
#   6. Vless-xhttp-reality-up-cdn-down 直连上行 / CDN 下行
#
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-true}
FEATURE_HY2=${FEATURE_HY2:-true}

# FEATURE_H2_DIRECT（v4.7.0 新增）：h3-direct 的 TCP 孪生体（监听 TCP 8445）。
# 默认关闭（保持 6 节点布局），需要时可通过 FEATURE_H2_DIRECT=true 开启。
FEATURE_H2_DIRECT=${FEATURE_H2_DIRECT:-false}


# ==================================================
# 未识别环境变量检查（v4.7.10）
# ==================================================
# 本脚本全靠环境变量做非交互配置，而 bash 对不存在的变量没有任何反馈：
# 拼错一个名字（CDN_DIRECT_PORT、FEATURE_XRAY_AUTO_UPGRADE 这类看起来
# 很合理但脚本里根本没有的），安装照常成功、日志一切正常，
# 用户以为配置生效了，实际被静默忽略——排查时几乎不可能想到这一层。
#
# 已知变量表不写死：直接在脚本自身里搜这个名字有没有被引用。
# 好处是永远不会和实现漂移——新增一个变量就自动被认可，删掉一个就自动开始告警。
# 代价是脚本得能读到自己；`bash <(curl ...)` 这种进程替换下 $0 是
# /dev/fd/63 且已被读尽，读不到就跳过检查（best-effort，绝不因此中断安装）。
check_unknown_env_vars() {
  local self="${BASH_SOURCE[0]}" name unknown=() code
  [[ -r "$self" && -s "$self" ]] || return 0

  # 必须先剥掉整行注释再搜：上面那段注释里举了两个「不存在的变量」当例子，
  # 直接搜原文会把它们搜到，检查永远报不出东西（第一版就栽在这）。
  # 只剥整行注释、不碰行尾注释——后者要正确处理引号内的 # 才不会误伤代码。
  code=$(grep -v '^[[:space:]]*#' "$self")

  # 只看长得像本项目参数的变量，避免把系统里成百上千的环境变量全扫一遍
  while IFS= read -r name; do
    grep -q "\b${name}\b" <<< "$code" || unknown+=("$name")
  done < <(compgen -v | grep -E '^(AUTO|FEATURE_|CDN_|REALITY_|XHTTP_|HY2_|OBFS_|H2_|H3_|IP_CHOICE|FALLBACK_|VISION_|KEEP_|NODE_|XRAY_)')

  [[ ${#unknown[@]} -eq 0 ]] && return 0
  warn "以下环境变量本脚本不认识，已被忽略（通常是拼写或版本差异）："
  for name in "${unknown[@]}"; do
    echo -e "         ${YELLOW}${name}${NC}=${!name}"
  done
  warn "确认拼写无误后再继续；可用变量见 README「可用环境变量」一节"
  echo ""
}
check_unknown_env_vars
