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
PROJECT_VERSION="3.0.0"
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

# v2.0.2：默认节点集 = 2 条 Reality 直连 + Vless-xhttp-tls-UDP-cdn，
# 加上 add-quic.sh 扩展的 Hysteria2，共 4 条。
#
# Vless-xhttp-tls-UDP-cdn（经 CDN 的 alpn=h3）**保留为默认输出**：
# 用户实测它在 iOS onexray 下速度最快、快于 Hysteria2（见 README 首行，
# 测试机 Oracle 4 OCPU / 24 GB）。v2.0.1 曾把它和两条 split 节点一起关掉，
# 那是错的——「TUN 下最脆弱」与「实测最快」可以同时成立，正确做法是保留节点、
# 用客户端绕行规则解决 TUN 自环（安装时生成的 client-config-v2rayn-tun.txt
# 已给出本机要加直连的 CDN 域名），而不是删掉一条实测最快的节点。
#
# 本开关管两条**上下行分离**节点（split-cdnup-realitydown /
# split-realityup-cdndown）。v2.0.3 起**默认开启**：v2.0.1 关掉它们的理由是
# 「收益未经测量」，但既然默认输出就没有测量的机会，等于用一个自我实现的理由
# 永久隐藏功能。改为默认给出，由用户实测决定去留。
# 设 false 可关闭。兼容 v2.0.1 短暂存在过的 FEATURE_CDN_NODES 旧名。
FEATURE_SPLIT_NODES=${FEATURE_SPLIT_NODES:-${FEATURE_CDN_NODES:-true}}

