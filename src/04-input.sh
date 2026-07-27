# ==================================================
# 初始化说明与交互参数
# ==================================================

info "检测到系统: $PRETTY_NAME"

if [[ -n "$SUDO_USER" && "$SUDO_USER" != "root" ]]; then
  USER_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
  USER_HOME=$(getent passwd 1000 2>/dev/null | cut -d: -f6 || true)
fi
[[ -z "$USER_HOME" || ! -d "$USER_HOME" ]] && USER_HOME="/root"

# ask VAR "提示语" "默认值"
#   1. 变量已由环境变量提供 → 直接采用（交互模式也复用，便于重装）
#   2. AUTO=1               → 采用默认值，不读取 stdin
#   3. 其余                  → 交互读取，回车取默认值
ask() {
  local __var="$1" __prompt="$2" __default="${3-}"

  if [[ -n "${!__var-}" ]]; then
    info "${__prompt%%[：:]*}: ${!__var}（来自环境变量）"
    return 0
  fi

  if [[ "$AUTO" == "1" ]]; then
    printf -v "$__var" '%s' "$__default"
    return 0
  fi

  local __reply
  read -rp "$__prompt" __reply
  printf -v "$__var" '%s' "${__reply:-$__default}"
}

pause_confirm() {
  [[ "$AUTO" == "1" ]] && return 0
  read -rp "$1" || true
}

echo -e "\n${CYAN}[+] XHTTP + CDN 一键部署脚本${NC}\n"
echo -e "${GREEN}[+] 推荐系统: Ubuntu 24.04 / Debian 12${NC}"
[[ "$AUTO" == "1" ]] && info "非交互模式（AUTO=1），全部参数取环境变量或默认值"
echo -e "${YELLOW}[+] 前置条件 (请确认已在 Cloudflare 完成):${NC}"
echo "  1. Reality 域名 DNS → 仅 DNS (灰色云朵)"
echo "  2. CDN 域名 DNS    → 代理开启 (橙色云朵)"
echo "  3. SSL/TLS 加密    → 完全(严格)"
echo "  4. 网络 → gRPC     → 已开启"
echo "  5. 缓存规则         → 部署完成后根据提示配置 (建议)"
if [[ "$FEATURE_CDN_ECH" == true ]]; then
  echo "  6. Edge Certificates → 如需使用 ECH 请先开启"
fi
echo ""

ask REALITY_DOMAIN "请输入 Reality 域名 (如 reality.example.com): "
[[ -z "$REALITY_DOMAIN" ]] && error "Reality 域名不能为空（非交互模式请设置环境变量 REALITY_DOMAIN）"
[[ "$REALITY_DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$REALITY_DOMAIN" != "." && "$REALITY_DOMAIN" != ".." ]] || error "Reality 域名格式无效"

ask CDN_DOMAIN "请输入 CDN 域名 (如 cdn.example.com): "
[[ -z "$CDN_DOMAIN" ]] && error "CDN 域名不能为空（非交互模式请设置环境变量 CDN_DOMAIN）"
[[ "$CDN_DOMAIN" =~ ^[A-Za-z0-9.-]+$ && "$CDN_DOMAIN" != "." && "$CDN_DOMAIN" != ".." ]] || error "CDN 域名格式无效"
[[ "$REALITY_DOMAIN" != "$CDN_DOMAIN" ]] || error "Reality 域名和 CDN 域名不能相同"

echo ""
echo "  1) IPv4"
echo "  2) IPv6"
ask IP_CHOICE "请选择 IP 类型 [1/2] (默认 1): " "1"
IP_CHOICE=${IP_CHOICE:-1}
[[ "$IP_CHOICE" == "1" || "$IP_CHOICE" == "2" ]] || error "IP 类型只能选择 1 或 2"

normalize_proxy_origin() {
  local url="$1"
  [[ "$url" =~ ^https?:// ]] || url="https://${url}"
  [[ "$url" =~ ^(https?)://([^/?#]+) ]] || return 1
  printf '%s://%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

echo ""
echo -e "${YELLOW}[+] 主动探测回落方式${NC}"
echo "  1) 使用自己的 index.html"
echo "  2) Nginx 反向代理网站（默认）"
# FALLBACK_MODE 也可直接由环境变量给出 static / proxy
# v1.2.2：默认由 static 改为 proxy —— 静态页需要用户自备两个域名的 index.html，
# 未准备时回落内容是脚本生成的占位页，主动探测下与真实网站差异明显。
# 注意这同时改变了 AUTO=1 的非交互路径：默认会反代 REALITY_FALLBACK_ORIGIN。
case "${FALLBACK_MODE-}" in
  static) FALLBACK_CHOICE=1 ;;
  proxy)  FALLBACK_CHOICE=2 ;;
  *)      ask FALLBACK_CHOICE "请选择回落方式 [1/2] (默认 2): " "2" ;;
esac

case "${FALLBACK_CHOICE:-2}" in
  1)
    FALLBACK_MODE="static"
    STATIC_SITE_DIR="${USER_HOME}/dist"
    for domain in "$REALITY_DOMAIN" "$CDN_DOMAIN"; do
      mkdir -p "${STATIC_SITE_DIR}/${domain}"
      if [[ ! -f "${STATIC_SITE_DIR}/${domain}/index.html" ]]; then
        cat > "${STATIC_SITE_DIR}/${domain}/index.html" <<'INITIAL_HTML_EOF'
@@include templates/default-index.html.tmpl
INITIAL_HTML_EOF
        sed -i \
          -e "s|<title>欢迎</title>|<title>${domain}</title>|" \
          -e "s|<h1>欢迎访问</h1>|<h1>${domain}</h1>|" \
          "${STATIC_SITE_DIR}/${domain}/index.html"
        chmod 644 "${STATIC_SITE_DIR}/${domain}/index.html"
        info "已生成 ${STATIC_SITE_DIR}/${domain}/index.html"
      fi
      chown "$(stat -c '%u:%g' "$USER_HOME")" \
        "${STATIC_SITE_DIR}/${domain}" \
        "${STATIC_SITE_DIR}/${domain}/index.html"
    done
    echo ""
    echo "Reality 页面：${STATIC_SITE_DIR}/${REALITY_DOMAIN}/index.html"
    echo "CDN 页面：    ${STATIC_SITE_DIR}/${CDN_DOMAIN}/index.html"
    echo "可用 SingleFile 抓取网页后分别上传。"
    pause_confirm "确认两个域名的页面准备完成后按 Enter 继续: "
    [[ -f "${STATIC_SITE_DIR}/${REALITY_DOMAIN}/index.html" ]] || error "未找到 Reality 域名页面"
    [[ -f "${STATIC_SITE_DIR}/${CDN_DOMAIN}/index.html" ]] || error "未找到 CDN 域名页面"
    ;;
  2)
    FALLBACK_MODE="proxy"
    ask REALITY_FALLBACK_ORIGIN "请输入 Reality 域名回落网站 [默认 https://www.sjsu.edu]: " "https://www.sjsu.edu"
    REALITY_FALLBACK_ORIGIN=$(normalize_proxy_origin "${REALITY_FALLBACK_ORIGIN:-https://www.sjsu.edu}") ||
      error "Reality 回落网站格式无效"
    ask CDN_FALLBACK_ORIGIN "请输入 CDN 域名回落网站 [默认 https://www.harvard.edu]: " "https://www.harvard.edu"
    CDN_FALLBACK_ORIGIN=$(normalize_proxy_origin "${CDN_FALLBACK_ORIGIN:-https://www.harvard.edu}") ||
      error "CDN 回落网站格式无效"
    [[ "$REALITY_FALLBACK_ORIGIN" != "$CDN_FALLBACK_ORIGIN" ]] ||
      error "Reality 域名和 CDN 域名不能共用同一个回落网站"
    REALITY_FALLBACK_HOST=${REALITY_FALLBACK_ORIGIN#*://}
    CDN_FALLBACK_HOST=${CDN_FALLBACK_ORIGIN#*://}
    ;;
  *)
    error "回落方式只能选择 1 或 2"
    ;;
esac

if [[ "$FEATURE_XPADDING" == true ]]; then
  echo ""
  echo -e "${YELLOW}[+] xpadding 自定义填充${NC}"
  ask XHTTP_PADDING_HEADER "请输入 xpadding Header 名 [默认 Referer]: " "Referer"
  XHTTP_PADDING_HEADER=${XHTTP_PADDING_HEADER:-Referer}
  ask XHTTP_PADDING_KEY "请输入 xpadding 参数名 [默认 x_padding]: " "x_padding"
  XHTTP_PADDING_KEY=${XHTTP_PADDING_KEY:-x_padding}
fi

if [[ "$FEATURE_CDN_ECH" == true ]]; then
  echo ""
  echo -e "${YELLOW}[+] CDN ECH（作用于 CDN-TLS）${NC}"
  ask CDN_ECH "是否启用 CDN ECH [y/N]: " "n"
  if [[ "${CDN_ECH,,}" == "y" || "${CDN_ECH,,}" == "yes" ]]; then
    CDN_ECH_ENABLED=true
    CDN_ECH_QUERY="cloudflare-ech.com+https://223.5.5.5/dns-query"
  else
    CDN_ECH_ENABLED=false
    CDN_ECH_QUERY=""
  fi
fi

echo ""
info "Reality: $REALITY_DOMAIN"
info "CDN:     $CDN_DOMAIN"
if [[ "$FALLBACK_MODE" == "static" ]]; then
  info "回落方式: 本地静态页面"
else
  info "回落方式: Nginx 反向代理"
  info "Reality 回落网站: $REALITY_FALLBACK_ORIGIN"
  info "CDN 回落网站:     $CDN_FALLBACK_ORIGIN"
fi
if [[ "$FEATURE_XPADDING" == true ]]; then
  info "xpadding Header:   $XHTTP_PADDING_HEADER"
  info "xpadding Key:      $XHTTP_PADDING_KEY"
fi
if [[ "$FEATURE_CDN_ECH" == true ]]; then
  if [[ "$CDN_ECH_ENABLED" == true ]]; then
    info "CDN ECH:          已开启"
  else
    info "CDN ECH:          未开启"
  fi
fi
if [[ "$FEATURE_TUNING" == true ]]; then
  info "流控调优:          开启（BBR + fq + 缓冲区 + 句柄，可用 ${MANAGE_CMD} tuning off 回滚）"
else
  info "流控调优:          关闭"
fi
echo ""
