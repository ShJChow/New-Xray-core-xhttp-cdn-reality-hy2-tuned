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
PROJECT_VERSION="2.0.1"
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

# v2.0.1：节点集收敛为「Reality + Hysteria2」。
# 三条涉及 CDN 的节点（xhttp-tls-UDP-cdn、split-cdnup-realitydown、
# split-realityup-cdndown）默认不再输出——它们在 v2rayN TUN 模式下最不稳
# （服务器是域名，需先解析；h3 那条还叠加 QUIC，见 tasks/lessons.md L15）。
#
# 用开关而不是删代码（L7）：服务端 CDN 基础设施（证书、nginx 的 CDN server 块、
# XHTTP location）全部保留，改回 true 即可恢复这三条节点，无需改代码。
# 注意 extensions/dual-cdn 与 dual-ip 按名定位 CDN 节点派生自己的配置，
# 关闭时它们会明确报错退出；要用那两个扩展就得设为 true。
FEATURE_CDN_NODES=${FEATURE_CDN_NODES:-false}

