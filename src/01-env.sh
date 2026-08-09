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
PROJECT_VERSION="4.5.2"
PROJECT_REPO="ShJChow/xhttp-cdn-tuned"
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
# 节点集：5 条，全部由 Xray 单核心提供
# ==================================================
#   1. Vless-xhttp-tls-UDP-cdn   经 CDN，TLS+XHTTP —— 稳定首选
#   2. Vless-xhttp-h3-direct     直连 UDP 443，h3/QUIC
#   3. Hysteria2-obfs            直连 UDP 8443，Salamander 混淆
#   4. Vless-reality-vision      直连 TCP 443，Vision
#   5. Vless-xhttp-reality       直连 TCP 443，XHTTP 上下行不分离
#
# v4.4.7 起删除 Vless-xhttp-split-realityup-cdndown（上下行分离节点）：
# 上行 Reality 直连 / 下行 CDN，实测不通且依赖跨 inbound 分离（下行腿落
# CDN_DIRECT_PORT、上行腿落 8001），上游原版两条腿都落在同一个 inbound，
# 本仓无已验证先例，故移除（README 与客户端配置同步精简为 5 条）。
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
# 均 closed as not planned）。v4.0.3 已把端口独立为 8444，最坏情况是 h3 退回 TCP 后
# 它自己不通，不再与 Reality 抢占 443。不需要时可设 FEATURE_H3_DIRECT=false 关闭。
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-true}
FEATURE_HY2=${FEATURE_HY2:-true}

