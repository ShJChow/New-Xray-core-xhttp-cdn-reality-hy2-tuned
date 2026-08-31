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

case "$OS_ID" in
  debian|ubuntu|centos|rhel|almalinux|rocky|ol|amzn|fedora|opensuse*|sles|alpine) ;;
  *)
    error "不支持的发行版: $OS_ID，目前支持 Debian/Ubuntu/CentOS/RHEL/Fedora/openSUSE/SLES/Alpine"
    ;;
esac

if [[ "$OS_ID" == "alpine" ]]; then
  SERVICE_TYPE="openrc"
  NGINX_RESTART_CMD="rc-service nginx restart"
else
  SERVICE_TYPE="systemd"
  NGINX_RESTART_CMD="systemctl restart nginx"
fi

service_restart() {
  if [[ "$SERVICE_TYPE" == "openrc" ]]; then
    rc-service "$1" restart || rc-service "$1" start
  else
    systemctl reset-failed "$1" >/dev/null 2>&1 || true
    systemctl restart "$1"
  fi
}

rawurlencode() {
  local string="$1"
  local encoded="" i char hex
  local LC_ALL=C

  for ((i = 0; i < ${#string}; i++)); do
    char="${string:i:1}"
    case "$char" in
      [a-zA-Z0-9.~_-])
        encoded+="$char"
        ;;
      *)
        printf -v hex '%%%02X' "'$char"
        encoded+="$hex"
        ;;
    esac
  done

  printf '%s' "$encoded"
}

get_query_param() {
  local line="$1"
  local key="$2"
  local query part
  local -a parts

  query="${line#*\?}"
  query="${query%%#*}"

  IFS='&' read -r -a parts <<< "$query"
  for part in "${parts[@]}"; do
    if [[ "${part%%=*}" == "$key" ]]; then
      printf '%s' "${part#*=}"
      return 0
    fi
  done
  return 1
}

extract_uri_user() {
  local line="$1"
  line="${line#vless://}"
  printf '%s' "${line%%@*}"
}

extract_uri_server() {
  local server="${1#*@}"
  server="${server%%\?*}"
  printf '%s' "${server%:443}"
}

strip_ipv6_brackets() {
  local value="$1"
  value="${value#[}"
  value="${value%]}"
  printf '%s' "$value"
}

format_uri_host() {
  local value="$1"
  if [[ "$value" == *:* ]]; then
    printf '[%s]' "$value"
  else
    printf '%s' "$value"
  fi
}

# ==================================================
# 节点定位（兼容 v1.1.0 之前的中文节点备注）
# v1.1.0 起节点名改为纯 ASCII + 主机名后缀，这里同时匹配新旧两种写法，
# 保证升级前部署的机器仍能被扩展脚本正确识别。
# ==================================================

NODE_RE_XHTTP_REALITY='#(Vless-xhttp-reality-|xhttp%2BReality%20)'
# v1.2.0 起 h2 的双向 CDN 节点已删除，CDN 参数改从 UDP 版节点读取。
# 旧装机两条都在时，grep|head -n1 按文件顺序仍优先命中 h2 那条。
NODE_RE_CDN_BOTH='#(Vless-xhttp-tls-cdn-|Vless-xhttp-tls-cdn-|xhttp%2Btls%20%E5%8F%8C%E5%90%91CDN)'
NODE_RE_REALITY_VISION='#(Vless-reality-vision-|reality%2Bvision)'
# v4.0.0 删除两条上下行分离节点，对应的 NODE_RE_SPLIT_* 一并移除（全仓无消费者）。
# NODE_RE_CDN_BOTH 保留：它匹配的 Vless-xhttp-tls-cdn 仍是默认节点，
# 且被 4 处扩展的 01-read-existing.sh 硬依赖。

# find_node_line FILE REGEX
find_node_line() {
  grep -E "$2" "$1" | head -n1 | tr -d '
' || true
}

# 节点名后缀，与主脚本保持一致
HOSTNAME_TAG=$(printf '%s' "${NODE_TAG:-$(hostname -s 2>/dev/null)}" | tr -cd 'A-Za-z0-9-' | cut -c1-20)
[[ -z "$HOSTNAME_TAG" || "$HOSTNAME_TAG" == "localhost" ]] && HOSTNAME_TAG="vps"

find_client_files() {
  if [[ -n "${SUDO_USER:-}" && "$SUDO_USER" != "root" ]]; then
    USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
  else
    USER_HOME=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)
  fi
  [[ -n "$USER_HOME" && -d "$USER_HOME" ]] || USER_HOME="/root"

  V2RAYN_FILE="$USER_HOME/client-config.txt"
  MIHOMO_FULL_FILE="$USER_HOME/client-config-mihomo-full.yaml"
  MIHOMO_NODES_FILE="$USER_HOME/client-config-mihomo-nodes.yaml"

  [[ -f "$V2RAYN_FILE" ]] || error "未找到 $V2RAYN_FILE，请先运行主脚本"
  [[ -f "$MIHOMO_FULL_FILE" ]] || error "未找到 $MIHOMO_FULL_FILE，请先运行主脚本"
  [[ -f "$MIHOMO_NODES_FILE" ]] || error "未找到 $MIHOMO_NODES_FILE，请先运行主脚本"
}

# ==================================================
# v2.0.1：本扩展默认只产出 Hysteria2 节点
# ==================================================
# Vless-xhttp-tls-h3-direct 默认不再输出。它是「域名/裸 IP + QUIC」的组合，
# 在 v2rayN TUN 模式下最不稳（tasks/lessons.md L15：TUN 自环对 UDP 兜不住），
# 且本项目从未在真机上确认它可用。
#
# 用开关而不是删代码（L7）：改成 true 即恢复该节点与配套的 nginx quic 监听。
# 关闭时同时跳过 nginx 的 location/listen 插入——节点 2（xhttp-reality）直连
# xray 的 TCP 443、不经 nginx，所以那段配置只服务这条 h3 节点，留着就是死配置。
FEATURE_XHTTP_H3_NODE=${FEATURE_XHTTP_H3_NODE:-false}

# ==================================================
# v4.7.0：本扩展 QUIC 节点的 TCP 兜底提示
# ==================================================
# 本扩展只产出 UDP/QUIC 节点，运营商封 UDP 时它整条不可用。主脚本 v4.7.0 起
# 已经提供对应的 TCP 通路，所以这里**不重复生成**节点（重复会让订阅里出现
# 两条实际同链路的条目），只在结尾指出该走哪一条——以及主脚本版本过旧、
# 那条 TCP 通路根本不存在时，明确告诉用户怎么补。
#
# 判定依据是 client-config.txt 里有没有 h2-tcp-direct 节点，而不是 node.env
# 里的 FEATURE_H2_DIRECT：本系列扩展一律从客户端配置反查参数（见 01-read-existing.sh），
# 保持同一个信息源，node.env 缺失或过期时也不会误报。
report_tcp_twin() {
  # QUIC_TWIN_DESC 由各扩展的 03-client-config.sh 设置，描述本扩展的 QUIC
  # 节点在主脚本里对应哪一条 TCP 节点。未设置时跳过整段。
  [[ -n "${QUIC_TWIN_DESC:-}" ]] || return 0

  echo ""
  echo -e "${YELLOW}[+] UDP 被封时的兜底${NC}"
  echo "  本扩展新增的是 QUIC/UDP 节点，运营商封 UDP 时整条不可用。"
  echo "  ${QUIC_TWIN_DESC}"

  if grep -q '#Vless-xhttp-h2-tcp-direct-' "$V2RAYN_FILE" 2>/dev/null; then
    echo "  Mihomo 订阅里的「直连回落」策略组已按 QUIC → TCP 的顺序自动切换。"
  else
    warn "  当前订阅里没有 h2-tcp-direct 节点（主脚本早于 v4.7.0）"
    warn "  重跑一次主安装脚本即可补上它与「直连回落」策略组，本扩展的节点不受影响"
  fi
}
