#!/usr/bin/env bash
set -euo pipefail

# ==========================================
# Sing-box Mini Installer
# Only: Hysteria2 + VLESS Reality
# ==========================================

info() { echo -e "\033[1;34m[INFO]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CACHE_FILE="$CONFIG_DIR/cache.conf"
URI_FILE="$CONFIG_DIR/uris.txt"
SERVICE_FILE="/etc/systemd/system/sing-box.service"
SB_CMD="/usr/local/bin/sb"

# =====================
# Root 检查
# =====================
[ "$(id -u)" -ne 0 ] && {
    err "请使用 root 运行"
    exit 1
}

# =====================
# 安装依赖
# =====================
install_deps() {
    if command -v apt >/dev/null 2>&1; then
        apt update -y
        apt install -y curl jq openssl unzip ca-certificates
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl jq openssl unzip ca-certificates
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl jq openssl unzip ca-certificates
    else
        err "不支持的系统"
        exit 1
    fi
}

# =====================
# 随机工具
# =====================
rand_port() {
    shuf -i 10000-60000 -n 1
}

rand_pass() {
    openssl rand -base64 16 | tr -d '\n\r'
}

rand_uuid() {
    cat /proc/sys/kernel/random/uuid
}

get_public_ip() {
    curl -s https://api.ipify.org || echo "YOUR_SERVER_IP"
}

# =====================
# 安装/更新 Sing-box
# =====================
install_singbox() {
    info "安装最新版 Sing-box..."
    bash <(curl -fsSL https://sing-box.app/install.sh)
}

# =====================
# 生成证书（HY2 用）
# =====================
generate_cert() {
    mkdir -p "$CONFIG_DIR"

    openssl req -x509 -newkey rsa:2048 -nodes \
      -keyout "$CONFIG_DIR/key.pem" \
      -out "$CONFIG_DIR/cert.pem" \
      -days 3650 \
      -subj "/CN=www.bing.com" >/dev/null 2>&1
}

# =====================
# Reality 密钥
# =====================
generate_reality() {
    local keys
    keys=$(sing-box generate reality-keypair)

    REALITY_PRIVATE=$(echo "$keys" | awk '/PrivateKey/ {print $2}')
    REALITY_PUBLIC=$(echo "$keys" | awk '/PublicKey/ {print $2}')
    REALITY_SID=$(sing-box generate rand 8 --hex)
}

# =====================
# 用户输入
# =====================
read_input() {
    echo
    read -rp "节点 IP 或域名（留空自动检测）: " SERVER_HOST
    SERVER_HOST=${SERVER_HOST:-$(get_public_ip)}

    read -rp "Hysteria2 端口（默认随机）: " HY2_PORT
    HY2_PORT=${HY2_PORT:-$(rand_port)}

    read -rp "Reality 端口（默认随机）: " REALITY_PORT
    REALITY_PORT=${REALITY_PORT:-$(rand_port)}

    read -rp "Reality SNI（默认 addons.mozilla.org）: " REALITY_SNI
    REALITY_SNI=${REALITY_SNI:-addons.mozilla.org}

    HY2_PASSWORD=$(rand_pass)
    REALITY_UUID=$(rand_uuid)
}

# =====================
# 保存缓存
# =====================
save_cache() {
    cat > "$CACHE_FILE" <<EOF
SERVER_HOST="$SERVER_HOST"
HY2_PORT="$HY2_PORT"
HY2_PASSWORD="$HY2_PASSWORD"
REALITY_PORT="$REALITY_PORT"
REALITY_UUID="$REALITY_UUID"
REALITY_SNI="$REALITY_SNI"
REALITY_PUBLIC="$REALITY_PUBLIC"
REALITY_PRIVATE="$REALITY_PRIVATE"
REALITY_SID="$REALITY_SID"
EOF
}

# =====================
# 生成配置
# =====================
generate_config() {
    cat > "$CONFIG_FILE" <<EOF
{
  "log": {
    "level": "error"
  },
  "inbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [
        {
          "password": "$HY2_PASSWORD"
        }
      ],
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "$CONFIG_DIR/cert.pem",
        "key_path": "$CONFIG_DIR/key.pem"
      }
    },
    {
      "type": "vless",
      "tag": "reality",
      "listen": "::",
      "listen_port": $REALITY_PORT,
      "users": [
        {
          "uuid": "$REALITY_UUID",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$REALITY_SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$REALITY_SNI",
            "server_port": 443
          },
          "private_key": "$REALITY_PRIVATE",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct"
    }
  ]
}
EOF

    sing-box check -c "$CONFIG_FILE"
}

# =====================
# Systemd
# =====================
setup_service() {
    cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Sing-box Service
After=network.target

[Service]
ExecStart=/usr/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable sing-box
    systemctl restart sing-box
}

# =====================
# 生成 URI
# =====================
generate_uri() {
    cat > "$URI_FILE" <<EOF
=== Hysteria2 ===
hy2://$HY2_PASSWORD@$SERVER_HOST:$HY2_PORT/?sni=www.bing.com&alpn=h3&insecure=1#Hysteria2

=== VLESS Reality ===
vless://$REALITY_UUID@$SERVER_HOST:$REALITY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUBLIC&sid=$REALITY_SID#Reality
EOF
}

# =====================
# 创建 sb 命令
# =====================
create_sb() {
    cat > "$SB_CMD" <<'EOF'
#!/usr/bin/env bash

CONFIG_DIR="/etc/sing-box"
URI_FILE="$CONFIG_DIR/uris.txt"

case "${1:-menu}" in
    start)
        systemctl start sing-box
        ;;
    stop)
        systemctl stop sing-box
        ;;
    restart)
        systemctl restart sing-box
        ;;
    status)
        systemctl status sing-box --no-pager
        ;;
    log)
        journalctl -u sing-box -f
        ;;
    uri)
        cat "$URI_FILE"
        ;;
    update)
        bash <(curl -fsSL https://sing-box.app/install.sh)
        systemctl restart sing-box
        sing-box version
        ;;
    uninstall)
        systemctl stop sing-box || true
        systemctl disable sing-box || true
        rm -f /etc/systemd/system/sing-box.service
        systemctl daemon-reload
        rm -rf /etc/sing-box
        rm -f /usr/local/bin/sb
        echo "卸载完成"
        ;;
    menu|*)
        echo "sb start      启动"
        echo "sb stop       停止"
        echo "sb restart    重启"
        echo "sb status     状态"
        echo "sb log        日志"
        echo "sb uri        查看链接"
        echo "sb update     更新 Sing-box"
        echo "sb uninstall  卸载"
        ;;
esac
EOF

    chmod +x "$SB_CMD"
}

# =====================
# 主流程
# =====================
main() {
    install_deps
    install_singbox
    read_input
    generate_cert
    generate_reality
    save_cache
    generate_config
    setup_service
    generate_uri
    create_sb

    echo
    info "安装完成！"
    echo
    cat "$URI_FILE"
    echo
    info "管理命令: sb"
}

main
```

---

## 管理命令

```bash
sb
sb uri
sb status
sb log
sb update
sb uninstall
```

---

## 内存占用

| 协议                  |     内存占用 |
| ------------------- | -------: |
| Hysteria2 + Reality | 20–35 MB |

---

## 在线更新

```bash
sb update
```

会自动：

1. 下载最新版本
2. 保留配置
3. 重启服务
4. 显示版本

---

## 查看链接

```bash
sb uri
```

或：

```bash
cat /etc/sing-box/uris.txt
```
