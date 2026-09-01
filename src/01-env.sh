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
PROJECT_VERSION="4.7.15"
PROJECT_REPO="ShJChow/Xray-core-xhttp-cdn-tuned"
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
# v4.0.0 节点集：5 条，全部由 Xray 单核心提供
# ==================================================
#   1. Vless-xhttp-tls-cdn   经 CDN，h3/QUIC —— 实测最快
#   2. Vless-xhttp-h3-direct     直连 UDP 443，h3/QUIC
#   3. Hysteria2-obfs            直连 UDP 8443，Salamander 混淆
#   4. Vless-reality-vision      直连 TCP 443，Vision
#   5. Vless-xhttp-reality       直连 TCP 443，XHTTP 上下行不分离
#
# 不再引入 sing-box 或独立 hysteria 二进制：Hysteria2 由 Xray 原生 inbound 提供
# （v26.3.27+）。TUIC v5 无法提供——Xray 的 inbound 协议列表中没有 TUIC，
# 第 5 条由 h3-direct 顶替（同为 QUIC 传输）。
#
# 下面两个开关控制的节点依赖 **Xray ≥ 26.6.1**，原因见 03-xray-install.sh 的
# require_xray_version：低于该版本时 finalmask 的 UDP listener 会在收到第一个
# 无效包后死亡（issue #6184），Hysteria2 与 XHTTP/3 双双静默失效。
# 版本不足时这两个开关会被自动置 false，只保留 3 条能用的节点（L1 best-effort）。
# FEATURE_H3_DIRECT 默认**开启**（v4.2.0）：5 节点全出。
# XHTTP over h3 在上游有两个未修复的问题（#4391 alpn=h3 被静默忽略、#5849 长期不工作，
# 均 closed as not planned）。v4.0.3 已把端口独立为 8446，最坏情况是 h3 退回 TCP 后
# 它自己不通，不再与 Reality 抢占 443。不需要时可设 FEATURE_H3_DIRECT=false 关闭。
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-true}
FEATURE_HY2=${FEATURE_HY2:-true}

# FEATURE_H2_DIRECT（v4.7.0 新增）：h3-direct 的 TCP 孪生体，同 UUID / 同 path /
# 同 decryption，只把传输层从 QUIC 换成 TCP（alpn h2 + http/1.1）。
# 引入原因：h3-direct 整条链路压在 UDP 上，运营商封 UDP 或 QUIC 丢包严重时
# 完全不可用，且 mihomo 在 alpn 只有 h3 时不会自动回落 TCP
# （transport/xhttp/client.go:159），表现为该节点单独连不上而非降速。
# 直连侧此前的 TCP 兜底只有 Reality，多一条 XHTTP TCP 可以和 h3-direct 组成
# 对，客户端「直连择优」策略组即依赖这一对。
# 默认跟随 FEATURE_H3_DIRECT：关掉 h3 的人不会想单独留一条它的孪生体。
FEATURE_H2_DIRECT=${FEATURE_H2_DIRECT:-$FEATURE_H3_DIRECT}


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
