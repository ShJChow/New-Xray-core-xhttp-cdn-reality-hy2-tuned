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
PROJECT_REPO="ShJChow26/xhttp-cdn-tuned"
MANAGE_CMD="xh"
MANAGE_BIN="/usr/local/bin/${MANAGE_CMD}"
STATE_DIR="/etc/xhttp-cdn"
NODE_ENV_FILE="${STATE_DIR}/node.env"
SYSCTL_CONF="/etc/sysctl.d/99-xray-xhttp.conf"
LIMITS_CONF="/etc/security/limits.d/99-xray-xhttp.conf"

# ==================================================
# 功能开关（均可用环境变量覆盖）
#   FEATURE_TUNING      内核 / 句柄流控调优
#   FEATURE_KEEPALIVE   保活自愈与开机自启
#   FEATURE_AUTOUPDATE  每周自动更新 Xray-core
#   AUTO=1              非交互一键部署
# ==================================================

FEATURE_TUNING=${FEATURE_TUNING:-true}
FEATURE_KEEPALIVE=${FEATURE_KEEPALIVE:-true}
FEATURE_AUTOUPDATE=${FEATURE_AUTOUPDATE:-true}
# 直连 VPS 的 XHTTP-over-H3 节点需要 Nginx 监听 UDP 443 quic，是配置里唯一有
# SSL 库依赖的指令（http3 需要支持 QUIC 的 TLS 库，标准 OpenSSL 未必满足），
# 曾导致部分环境下 nginx 启动失败。若重装后 nginx -t / 服务启动失败，先用
# FEATURE_H3_DIRECT=false 重跑一次以排除该因素，问题不在此项再继续排查。
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-true}
AUTO=${AUTO:-0}

