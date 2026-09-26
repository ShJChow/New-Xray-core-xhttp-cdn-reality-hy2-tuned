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

# 支持 `bash install.sh key=value ...` 位置参数传入（与环境变量前缀等价，且彻底规避终端换行/转义断行报错）
for arg in "$@"; do
  case "$arg" in
    *=*) export "$arg" ;;
  esac
done

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
PROJECT_VERSION="4.9.38"
PROJECT_REPO="ShJChow/New-Xray-core-xhttp-cdn-reality-hy2-tuned"
# 默认推荐的 Xray-core 版本：仅适用官方正式版本（releases/latest，严格排除 pre-release / beta 测试版）。
# 官方最新正式版为 v26.3.27，具备完整的 Hysteria 2、XHTTP 与全客户端高兼容 REALITY。
XRAY_DEFAULT_VERSION="latest"
MANAGE_CMD="xh"
MANAGE_BIN="/usr/local/bin/${MANAGE_CMD}"
STATE_DIR="/etc/xhttp-cdn"
NODE_ENV_FILE="${STATE_DIR}/node.env"
SYSCTL_CONF="/etc/sysctl.d/99-xray-xhttp.conf"
LIMITS_CONF="/etc/security/limits.d/99-xray-xhttp.conf"

# ==================================================
# 功能开关（均可用环境变量覆盖）
# 端口规划 (默认配置，全部单端口，默认关闭端口跳跃)
# ==================================================
# 443      TCP (Xray VLESS 兜底)
# 8443     UDP (Xray Hysteria 2)
# 8445     TCP (Xray h2-direct，默认关闭)
# 8446     UDP (Xray h3-direct)
# 80       TCP (Nginx HTTP 验证与重定向)
# 8001     TCP (Xray XHTTP CDN 回源入站，仅监听 127.0.0.1)
# 8002     TCP (Nginx 反代分流，仅监听 127.0.0.1)
# 8003     TCP (Nginx SSL 回落与伪装站点，仅监听 127.0.0.1)

# ==================================================
# 客户端 / 调优管理命令别名
# ==================================================
MANAGE_CMD="xh"

# ==================================================
# 流控调优开关（默认开启）
# ==================================================
# 系统级调优默认开启；安装期只写内核与网卡队列，
# systemd 层的调优全部收进管理命令，按需 `xh tuning on`。
# ==================================================

FEATURE_KEEPALIVE=${FEATURE_KEEPALIVE:-true}
FEATURE_AUTOUPDATE=${FEATURE_AUTOUPDATE:-true}
AUTO=${AUTO:-0}

# ==================================================
# 节点集：默认 7 条核心主力节点，全部由 Xray 单核心提供
# ==================================================
#   1. VLESS-XHTTP-CDN-H2    经 CDN，h2/TCP
#   2. VLESS-XHTTP-CDN-H3    经 CDN，h3/QUIC
#   3. VLESS-XHTTP-Direct-H3 直连 UDP 8443，h3/QUIC
#   4. Hysteria2-H3-Direct   直连 UDP 443，标准 HTTP/3
#   5. VLESS-Reality-Vision-Direct 直连 TCP 443，Vision
#   6. VLESS-Reality-XHTTP-Direct  直连 TCP 443，XHTTP 上下行不分离
#   7. VLESS-Reality-Up-CDN-Down   直连上行 / CDN 下行
#
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-true}
FEATURE_HY2=${FEATURE_HY2:-true}
# FEATURE_HY2_H3（v4.9.26）：在 UDP 443 上再开一条**不加混淆**的 Hysteria2（Hysteria2-H3-Direct），
# 流量形态就是一个普通网站的 HTTP/3，是 UDP 里最不容易被运营商按端口/特征 QoS 的样子。
# 依附于 FEATURE_HY2（共用认证密码与证书）；UDP 443 被占用时自动关闭。v4.9.28 起为 Xray 唯一的 Hysteria2 节点。
FEATURE_HY2_H3=${FEATURE_HY2_H3:-true}
# FEATURE_HY2_OBFS（v4.9.28）：UDP 8443 + salamander 混淆的 Hysteria2-Obfs-Direct，**默认关闭**。
# 同条件实测 Hysteria2-H3-Direct 下行三种线路都更快、上行持平、延迟更低，Xray 侧只保留它一条。
# 所处网络对 QUIC 做深度识别封锁、需要混淆时再打开：FEATURE_HY2_OBFS=true bash install.sh
# （同机 sbbox 的 Hysteria2 自带 salamander，也可作为混淆备选）。
# FEATURE_HY2 仍是 Hysteria2 的总开关（内核版本不够、缺证书时两条一起关）。
FEATURE_HY2_OBFS=${FEATURE_HY2_OBFS:-false}
HY2_H3_PORT=443

# FEATURE_CDN_H2：是否生成经 CDN 的 TCP(h2) 节点 VLESS-XHTTP-CDN-H2。
# 默认开启（作为 7 大核心主力节点之一，提供 UDP 封锁时的 TCP CDN 兜底逃生通道）。
FEATURE_CDN_H2=${FEATURE_CDN_H2:-true}

# FEATURE_H2_DIRECT（v4.7.0 新增）：h3-direct 的 TCP 孪生体（监听 TCP 8445）。
# 默认关闭（保持 6 节点布局），需要时可通过 FEATURE_H2_DIRECT=true 开启。
FEATURE_H2_DIRECT=${FEATURE_H2_DIRECT:-false}

# FEATURE_REALITY_UP_CDN_DOWN（v4.9.36 默认启用）：上下行分离节点
# VLESS-Reality-Up-CDN-Down（上行 Reality 直连 443 / 下行 CDN H2 443）。
# 0-RTT Reality 极速直连上行 + Cloudflare CDN 满速下行防封。默认作为 6 大核心节点之一。
FEATURE_REALITY_UP_CDN_DOWN=${FEATURE_REALITY_UP_CDN_DOWN:-true}
FEATURE_UP_CDN_DOWN_MIHOMO=${FEATURE_UP_CDN_DOWN_MIHOMO:-${FEATURE_REALITY_UP_CDN_DOWN}}

# FEATURE_CDN_UP_REALITY_DOWN（v4.9.29 新增，v4.9.36 默认关闭）：反向的上下行分离节点
# VLESS-CDN-Up-Reality-Down —— 上行 XHTTP+TLS 经 Cloudflare CDN，下行 XHTTP+Reality 直连。
# 与 Reality-Up-CDN-Down 一样落到同一个 8001 入站（Reality 443 回落 / Nginx 8003 回源），
# 默认关闭保持核心节点精简，需要时可通过 FEATURE_CDN_UP_REALITY_DOWN=true 开启。
FEATURE_CDN_UP_REALITY_DOWN=${FEATURE_CDN_UP_REALITY_DOWN:-false}

# FEATURE_XHTTP_VLESSENC（v4.9.29）：8001 XHTTP 入站启用 VLESS Encryption（默认开启）。
# 8001 是唯一经过 CDN 的入站，Cloudflare 边缘会解开外层 TLS，不加 vlessenc 时
# VLESS 头和明文载荷对 CDN 可见。Reality-Vision 直连（443 主入站）不需要，保持 none。
# 代价：小火箭不支持 vlessenc，开启后它的专属订阅不再附带 VLESS-XHTTP-CDN-H2。
# 置为 false 回到 v4.9.21 的行为（8001 decryption none）。
FEATURE_XHTTP_VLESSENC=${FEATURE_XHTTP_VLESSENC:-true}

# FEATURE_PORT_HOPPING：UDP 端口跳跃（默认关闭）。
# 避免客户端在服务端未配置 nat/iptables 端口段重定向时握手失败，或劫持同机其他 UDP 服务。
FEATURE_PORT_HOPPING=${FEATURE_PORT_HOPPING:-false}

# FEATURE_BRUTAL：TCP Brutal (HyNetworks/tcp-brutal) 极速拥塞控制（默认开启）。
# 当系统内核存在 brutal 模块时，自动为 Xray TCP 入站启用 Brutal 拥塞控制。
FEATURE_BRUTAL=${FEATURE_BRUTAL:-true}
BRUTAL_DEFAULT_MBPS=${BRUTAL_DEFAULT_MBPS:-auto}

# REALITY_MIN_CLIENT_VER：Reality 客户端最低兼容版本（默认 1.8.0）。
# 设为 1.8.0 可让 mihomo / Clash Meta / sing-box 客户端正常握手；
# 设为 none 或 default 则不写 minClientVer，回到 Xray 内核最新默认版本（严格模式）。
# 兼容别名：MIN_CLIENT_VER、MINVERSION、MIN_VERSION。
REALITY_MIN_CLIENT_VER="${REALITY_MIN_CLIENT_VER:-${MIN_CLIENT_VER:-${MINVERSION:-${MIN_VERSION:-1.8.0}}}}"


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
  done < <(compgen -v | grep -E '^(AUTO|FEATURE_|CDN_|REALITY_|XHTTP_|HY2_|OBFS_|H2_|H3_|IP_CHOICE|FALLBACK_|VISION_|KEEP_|NODE_|XRAY_|MIN_CLIENT_VER|MINVERSION|MIN_VERSION)')

  [[ ${#unknown[@]} -eq 0 ]] && return 0
  warn "以下环境变量本脚本不认识，已被忽略（通常是拼写或版本差异）："
  for name in "${unknown[@]}"; do
    echo -e "         ${YELLOW}${name}${NC}=${!name}"
  done
  warn "确认拼写无误后再继续；可用变量见 README「可用环境变量」一节"
  echo ""
}
check_unknown_env_vars
