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
PROJECT_REPO="ShJChow/xhttp-cdn-tuned"
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
# v1.2.2：把"改动宿主机全局状态"的部分从 FEATURE_TUNING 里拆出来，默认关闭。
# 内核参数 / 句柄上限 / systemd drop-in 与"节点能不能通"无关，却是安装期最容易
# 出问题的一段；先把节点跑通，确认无误后再 `xh tuning on` 打开。
# Xray 侧的 bufferSize / sockopt 不写系统状态，仍由 FEATURE_TUNING 控制且默认开启。
FEATURE_SYSCTL=${FEATURE_SYSCTL:-false}
FEATURE_KEEPALIVE=${FEATURE_KEEPALIVE:-true}
FEATURE_AUTOUPDATE=${FEATURE_AUTOUPDATE:-true}
# 直连 VPS 的 XHTTP-over-H3 节点（Vless-xhttp-tls-UDP-direct）。
# v1.2.7 起默认 false：用户在 Shadowrocket 下实测该节点不通，与 add-quic.sh 的
# Vless-xhttp-tls-h3-direct 表现一致。经 CDN 的 h3 节点（Vless-xhttp-tls-UDP-cdn）
# 不受影响，仍默认启用。
# 该开关同时控制 Nginx 的 UDP 443 quic 监听（src/09-server-config.sh）与客户端
# 节点链接 / mihomo 块（src/11-client-config.sh），关闭后不会留下打不通的死节点。
# 该监听也是配置里唯一有 SSL 库依赖的指令（http3 需要支持 QUIC 的 TLS 库，标准
# OpenSSL 未必满足），曾导致部分环境下 nginx 启动失败——默认关闭一并规避了这点。
# 想自行验证的用 FEATURE_H3_DIRECT=true 重跑，代码路径完整保留。
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-false}
AUTO=${AUTO:-0}

