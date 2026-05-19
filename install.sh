#!/usr/bin/env bash
set -euo pipefail

# -----------------------
# 彩色输出函数
info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

# 彻底清理缓存（兼容只读文件系统）
sync || true

# -----------------------
# 检测系统类型
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID:-}"
        OS_ID_LIKE="${ID_LIKE:-}"
    else
        OS_ID=""; OS_ID_LIKE=""
    fi

    if echo "$OS_ID $OS_ID_LIKE" | grep -qi "alpine"; then
        OS="alpine"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "debian|ubuntu" >/dev/null; then
        OS="debian"
    elif echo "$OS_ID $OS_ID_LIKE" | grep -Ei "centos|rhel|fedora" >/dev/null; then
        OS="redhat"
    else
        OS="unknown"
    fi
}
detect_os
info "检测到系统: $OS (${OS_ID:-unknown})"

if [ "$(id -u)" != "0" ]; then
    err "此脚本需要 root 权限"
    exit 1
fi

# -----------------------
# 安装极其基础的依赖
install_deps() {
    info "安装系统依赖..."
    case "$OS" in
        alpine)
            apk update || true
            apk add --no-cache bash curl ca-certificates openssl || { err "依赖安装失败"; exit 1; }
            ;;
        debian)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -y || true
            apt-get install -y curl ca-certificates openssl || { err "依赖安装失败"; exit 1; }
            ;;
        redhat)
            yum install -y curl ca-certificates openssl || { err "依赖安装失败"; exit 1; }
            ;;
    esac
}
install_deps

# -----------------------
# 轻量级工具函数
rand_port() {
    echo $((RANDOM % 50001 + 10000))
}
rand_pass() {
    openssl rand -base64 12 | tr -d '\n\r'
}
rand_uuid() {
    if [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        openssl rand -hex 16 | sed 's/\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)\(..\)/\1\2\3\4-\5\6-\7\8-\9\10-\11\12\13\14\15\16/'
    fi
}
url_encode() {
    printf "%s" "$1" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g'
}

# -----------------------
# 节点和基础环境交互设置
echo "请输入节点名称后缀(留空则默认无后缀):"
read -r user_name
suffix=""
if [ -n "$user_name" ]; then
    suffix="-${user_name}"
    echo "$suffix" > /root/node_names.txt
else
    rm -f /root/node_names.txt
fi

echo "请输入节点连接 IP 或 DDNS 域名(留空默认自动获取公网IP):"
read -r CUSTOM_IP
CUSTOM_IP="$(echo "$CUSTOM_IP" | tr -d '[:space:]')"

echo "请输入 Reality 的 SNI (留空默认 itunes.apple.com):"
REALITY_SNI="$(echo "${REALITY_SNI:-itunes.apple.com}" | tr -d '[:space:]')"

# -----------------------
# 获取端口配置
info "配置端口和密码（输入回车可自动生成随机端口）..."
read -p "请输入 VLESS Reality 端口 [默认随机]: " USER_PORT_REALITY
PORT_REALITY="${USER_PORT_REALITY:-$(rand_port)}"
UUID_REALITY=$(rand_uuid)

read -p "请输入 Hysteria 2 端口 [默认随机]: " USER_PORT_HY2
PORT_HY2="${USER_PORT_HY2:-$(rand_port)}"
PSK_HY2=$(rand_pass)

# -----------------------
# 核心安装：初次安装即直接抓取最新版 + 强制控速防爆机制
install_singbox() {
    info "正在检索 Github 最新 sing-box 稳定版版本号..."
    # 免 jq 轻量提取最新版本号
    LATEST_VER=$(curl -sSL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | awk -F '"' '/tag_name/{print $4}' | sed 's/^v//')
    
    if [ -z "$LATEST_VER" ]; then
        warn "无法连接 Github API 获取最新版，将默认采用保底稳定版 1.13.12"
        LATEST_VER="1.13.12"
    fi

    info "开始采用【安全防爆限速模式】下载最新版 sing-box v${LATEST_VER}..."
    mkdir -p /tmp/sb-download && cd /tmp/sb-download
    
    ARCH="amd64"
    if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
        ARCH="arm64"
    fi
    
    info "正在以 1MB/s 安全限速下载 linux-${ARCH} 核心压缩包..."
    # 🎯 初次安装同样锁死 --limit-rate 1M 防爆运存
    if curl -fSL --limit-rate 1M --connect-timeout 15 --retry 3 -o sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${ARCH}.tar.gz"; then
        
        # 🎯 在解压新版大体积核心前，强力回收小鸡系统多余内存
        echo "下载成功！正在强力释放小鸡缓存以保障解压安全..."
        sync && echo 3 > /proc/sys/vm/drop_caches || true
        
        echo "开始解压最新核心..."
        tar -zxf sb.tar.gz
        mkdir -p /usr/bin
        mv sing-box-${LATEST_VER}-linux-${ARCH}/sing-box /usr/bin/sing-box
        chmod +x /usr/bin/sing-box
    else
        err "从 Github 下载最新核心失败，请检查海外小鸡与 Github 的连接情况。"
        exit 1
    fi
    
    cd / && rm -rf /tmp/sb-download
    info "sing-box 最新核心提取并部署成功！"
}
install_singbox

# -----------------------
# 生成 Reality 密钥对
info "生成 Reality 密钥对..."
REALITY_KEYS=$(/usr/bin/sing-box generate reality-keypair 2>/dev/null || echo -e "PrivateKey: xxx\nPublicKey: xxx")
REALITY_PK=$(echo "$REALITY_KEYS" | awk '/PrivateKey/ {print $2}')
REALITY_PUB=$(echo "$REALITY_KEYS" | awk '/PublicKey/ {print $2}')
REALITY_SID=$(openssl rand -hex 8)

mkdir -p /etc/sing-box/certs
echo -n "$REALITY_PUB" > /etc/sing-box/.reality_pub

# -----------------------
# 生成 HY2 自签证书
info "生成 Hysteria 2 自签证书..."
if [ ! -f /etc/sing-box/certs/fullchain.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout /etc/sing-box/certs/privkey.pem \
      -out /etc/sing-box/certs/fullchain.pem \
      -days 3650 -subj "/CN=www.bing.com" >/dev/null 2>&1 || true
fi

# -----------------------
# 写入超轻量配置文件 config.json
info "正在生成超轻量配置文件..."
cat > /etc/sing-box/config.json <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": ${PORT_REALITY},
      "users": [ { "uuid": "${UUID_REALITY}", "flow": "xtls-rprx-vision" } ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_SNI}", "server_port": 443 },
          "private_key": "${REALITY_PK}",
          "short_id": ["${REALITY_SID}"]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT_HY2},
      "users": [ { "password": "${PSK_HY2}" } ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "/etc/sing-box/certs/fullchain.pem",
        "key_path": "/etc/sing-box/certs/privkey.pem"
      }
    }
  ],
  "outbounds": [ { "type": "direct", "tag": "direct-out" } ]
}
EOF

# 保存文本格式的环境缓存文件
cat > /etc/sing-box/.config_cache <<EOF
PORT_REALITY=${PORT_REALITY}
UUID_REALITY=${UUID_REALITY}
REALITY_PUB=${REALITY_PUB}
REALITY_SID=${REALITY_SID}
REALITY_SNI=${REALITY_SNI}
PORT_HY2=${PORT_HY2}
PSK_HY2=${PSK_HY2}
CUSTOM_IP=${CUSTOM_IP}
EOF

# -----------------------
# 配置服务开机自启（秒级复活守护）
info "配置轻量化系统服务..."
if [ "$OS" = "alpine" ]; then
    cat > /etc/init.d/sing-box <<'OPENRC'
#!/sbin/openrc-run
name="sing-box"
command="/usr/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/${RC_SVCNAME}.pid"
command_background="yes"
supervisor=supervise-daemon
supervise_daemon_args="--respawn-max 999 --respawn-delay 1"
depend() { need net; }
OPENRC
    chmod +x /etc/init.d/sing-box
    rc-update add sing-box default >/dev/null 2>&1 || true
    rc-service sing-box restart || true
else
    cat > /etc/systemd/system/sing-box.service <<'SYSTEMD'
[Unit]
Description=Sing-box Proxy Server
After=network.target
[Service]
Type=simple
User=root
ExecStart=/usr/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=1s
[Install]
WantedBy=multi-user.target
SYSTEMD
    systemctl daemon-reload || true
    systemctl enable sing-box >/dev/null 2>&1 || true
    systemctl restart sing-box || true
fi

# 自动刷新防火墙规则
if command -v iptables >/dev/null 2>&1; then
    iptables -I INPUT -p tcp --dport ${PORT_REALITY} -j ACCEPT 2>/dev/null || true
    iptables -I INPUT -p udp --dport ${PORT_HY2} -j ACCEPT 2>/dev/null || true
fi

# -----------------------
# 获取连接 IP
if [ -n "${CUSTOM_IP}" ]; then
    PUB_IP="${CUSTOM_IP}"
else
    PUB_IP=$(curl -s --max-time 5 api.ipify.org || curl -s --max-time 5 ifconfig.me || echo "你的服务器IP")
fi

# -----------------------
# 输出快捷链接
echo ""
echo "=========================================="
info "🎉 极限精简控速特调版最新 Sing-box 部署完成!"
echo "=========================================="
echo ""
echo "🔗 VLESS Reality 节点链接："
echo "vless://${UUID_REALITY}@${PUB_IP}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#Reality${suffix}"
echo ""
echo "🔗 Hysteria 2 节点链接（单端口锁死 hop=0 优化）："
hy2_enc=$(url_encode "${PSK_HY2}")
echo "hy2://${hy2_enc}@${PUB_IP}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1&hop=0#Hysteria2${suffix}"
echo ""
echo "=========================================="
info "输入 sb 可召唤超轻量管理面板"
echo "=========================================="

# -----------------------
# 创建纯文本缓存版、免 jq 的高级 sb 管理后台
SB_PATH="/usr/local/bin/sb"
cat > "$SB_PATH" <<'SB_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_PATH="/etc/sing-box/config.json"
CACHE_FILE="/etc/sing-box/.config_cache"

if [ ! -f "$CACHE_FILE" ]; then
    echo "[ERR] 找不到配置文件缓存"
    exit 1
fi
. "$CACHE_FILE"

if [ -f /etc/init.d/sing-box ]; then
    CMD_START="rc-service sing-box start"
    CMD_STOP="rc-service sing-box stop"
    CMD_REST="rc-service sing-box restart"
    CMD_STAT="rc-service sing-box status"
else
    CMD_START="systemctl start sing-box"
    CMD_STOP="systemctl stop sing-box"
    CMD_REST="systemctl restart sing-box"
    CMD_STAT="systemctl status sing-box --no-pager"
fi

while true; do
    echo "=================================="
    echo "  Sing-box 极轻量面板 (无jq安全版)"
    echo "=================================="
    echo "1) 查看客户端节点链接"
    echo "2) 启动代理服务"
    echo "3) 停止代理服务"
    echo "4) 重启代理服务"
    echo "5) 查看当前服务运行状态"
    echo "6) 更新 sing-box 核心 (限速防爆升级)"
    echo "7) 彻底卸载 sing-box"
    echo "0) 退出面板"
    echo "=================================="
    read -p "请输入选项 [0-7]: " opt
    
    case "$opt" in
        1)
            suffix=$(cat /root/node_names.txt 2>/dev/null || echo "")
            if [ -n "${CUSTOM_IP}" ]; then IP_SHOW="${CUSTOM_IP}"; else IP_SHOW=$(curl -s --max-time 3 api.ipify.org || echo "你的服务器IP"); fi
            echo -e "\n--- VLESS Reality 链接 ---"
            echo "vless://${UUID_REALITY}@${IP_SHOW}:${PORT_REALITY}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${REALITY_PUB}&sid=${REALITY_SID}#Reality${suffix}"
            echo -e "\n--- Hysteria 2 链接 ---"
            hy2_enc=$(printf "%s" "${PSK_HY2}" | sed 's/:/%3A/g; s/+/%2B/g; s/\//%2F/g; s/=/%3D/g')
            echo "hy2://${hy2_enc}@${IP_SHOW}:${PORT_HY2}/?sni=www.bing.com&alpn=h3&insecure=1&hop=0#Hysteria2${suffix}"
            echo ""
            ;;
        2) $CMD_START && echo "已下发启动指令。" ;;
        3) $CMD_STOP && echo "已下发停止指令。" ;;
        4) $CMD_REST && echo "已下发重启指令。" ;;
        5) echo "-----------------"; $CMD_STAT; echo "-----------------"; ;;
        6)
            echo "正在检索 Github 最新 sing-box 稳定版版本号..."
            LATEST_VER=$(curl -sSL --connect-timeout 10 https://api.github.com/repos/SagerNet/sing-box/releases/latest | awk -F '"' '/tag_name/{print $4}' | sed 's/^v//')
            
            if [ -z "$LATEST_VER" ]; then
                echo "[WARN] 无法连接 Github API 获取最新版，将默认尝试更新到 1.13.12"
                LATEST_VER="1.13.12"
            fi
            
            echo "准备将 sing-box 核心平滑升级至 v${LATEST_VER}..."
            mkdir -p /tmp/sb-update && cd /tmp/sb-update
            
            ARCH="amd64"
            if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then ARCH="arm64"; fi
            
            echo "正在以 1MB/s 安全限速下载新核心..."
            if curl -fSL --limit-rate 1M --connect-timeout 15 --retry 3 -o sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VER}/sing-box-${LATEST_VER}-linux-${ARCH}.tar.gz"; then
                
                echo "下载成功！正在强力回收小鸡系统多余内存..."
                sync && echo 3 > /proc/sys/vm/drop_caches || true
                
                echo "开始解压新程序..."
                tar -zxf sb.tar.gz
                
                $CMD_STOP || true
                mv sing-box-${LATEST_VER}-linux-${ARCH}/sing-box /usr/bin/sing-box
                chmod +x /usr/bin/sing-box
                $CMD_START || true
                echo -e "\n\033[1;32m[SUCCESS] 核心已通过限速机制安全升级至 v${LATEST_VER}！\033[0m\n"
            else
                echo "[ERR] 下载失败，请检查网络后重试。"
            fi
            cd / && rm -rf /tmp/sb-update
            ;;
        7)
            read -p "确认完全卸载？(y/N): " un_confirm
            if [[ "$un_confirm" =~ ^[Yy]$ ]]; then
                $CMD_STOP || true
                if [ -f /etc/init.d/sing-box ]; then rc-update del sing-box default || true; rm -f /etc/init.d/sing-box; else systemctl disable sing-box || true; rm -f /etc/systemd/system/sing-box.service; fi
                rm -rf /etc/sing-box /usr/local/bin/sb /usr/bin/sing-box /root/node_names.txt
                echo "Sing-box 卸载成功，已退出。"
                exit 0
            fi
            ;;
        0) exit 0 ;;
        *) echo "无效输入，请重新输入" ;;
    esac
done
SB_SCRIPT

chmod +x "$SB_PATH"
