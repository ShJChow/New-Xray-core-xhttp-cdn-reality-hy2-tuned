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
PROJECT_VERSION="4.9.24"
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
# 节点集：默认 7 条，全部由 Xray 单核心提供
# ==================================================
#   1. Vless-xhttp-h2-cdn    经 CDN，h2/TCP
#   2. Vless-xhttp-h3-cdn    经 CDN，h3/QUIC
#   3. Vless-xhttp-h3-direct 直连 UDP 8446，h3/QUIC
#   4. Hysteria2-obfs        直连 UDP 8443，Salamander 混淆
#   5. Vless-reality-vision  直连 TCP 443，Vision
#   6. Vless-xhttp-reality   直连 TCP 443，XHTTP 上下行不分离
#   7. Vless-xhttp-reality-up-cdn-down 直连上行 / CDN 下行
#
FEATURE_H3_DIRECT=${FEATURE_H3_DIRECT:-true}
FEATURE_HY2=${FEATURE_HY2:-true}

# FEATURE_H2_DIRECT（v4.7.0 新增）：h3-direct 的 TCP 孪生体（监听 TCP 8445）。
# 默认关闭（保持 6 节点布局），需要时可通过 FEATURE_H2_DIRECT=true 开启。
FEATURE_H2_DIRECT=${FEATURE_H2_DIRECT:-false}

# FEATURE_UP_CDN_DOWN_MIHOMO（v4.9.19 完美修复并默认开启）：是否把 7 号节点
# Vless-xhttp-reality-up-cdn-down 下发进 mihomo 配置。**默认开启**。
#
# 【历史根因溯源】：此前在 mihomo 上测试报 REALITY authentication failed，
# 曾误以为是 mihomo 内核限制。经深入查阅 MetaCubeX/mihomo Go 源码（adapter/outbound/vless.go
# 第 764 行与 reality.go）：
#   downloadRealityCfg := v.realityConfig
#   if ds.RealityOpts != nil { downloadRealityCfg, err = ds.RealityOpts.Parse() }
# 若 download-settings 未声明 reality-opts，下行腿会自动继承父级的 realityConfig，
# 导致 mihomo 连接下行腿 CDN 域名（Cloudflare 443）时强行发起 REALITY 握手认证，
# Cloudflare 证书不符必然报 authentication failed！
# 【攻克方案】：在 download-settings 中显式声明 `reality-opts: { public-key: "" }`，
# 使得 ds.RealityOpts.Parse() 返回 nil，彻底覆写清空继承的 realityConfig，
# 下行腿恢复标准 TLS 1.3 握手；同时扁平化 path/host/reuse-settings 结构。
# 实测 mihomo v1.19.30+ 完美跑通，0-RTT 极速上行 + CDN 满速下行！
FEATURE_UP_CDN_DOWN_MIHOMO=${FEATURE_UP_CDN_DOWN_MIHOMO:-true}

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
