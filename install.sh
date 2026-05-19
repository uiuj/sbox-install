#!/bin/sh

# ==========================================
# 脚本名称：极简 Sing-box 一键安装脚本
# 适用环境：Linux (支持 Alpine/Debian/Ubuntu 等)
# ==========================================

# 1. 定义版本变量（以后官方更新了，你只需要改这里）
VERSION="1.11.0"
DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-amd64.tar.gz"

# 2. 炫酷的欢迎开场白
echo "========================================="
echo "        欢迎使用你的自定义一键脚本          "
echo "        正在为您的系统安装 Sing-box...     "
echo "========================================="

# 3. 创建临时工作目录并进入
mkdir -p /tmp/sb-install && cd /tmp/sb-install

# 4. 开始下载
echo "[1/4] 正在从 GitHub 下载官方核心..."
wget -O sing-box.tar.gz "${DOWNLOAD_URL}"

# 判断上一步下载是否成功，不成功就报错退出
if [ $? -ne 0 ]; then
    echo "❌ 错误：下载失败，请检查网络或 GitHub 连通性！"
    exit 1
fi

# 5. 解压并安装
echo "[2/4] 下载完成，正在解压..."
tar -zxvf sing-box.tar.gz

echo "[3/4] 正在安装到系统目录 (/usr/local/bin)..."
mv sing-box-${VERSION}-linux-amd64/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box

# 6. 清理垃圾
echo "[4/4] 正在清理安装产生的临时文件..."
cd / && rm -rf /tmp/sb-install

# 7. 大功告成
echo "========================================="
echo "🎉 恭喜！Sing-box 安装成功！"
echo "目前安装的版本信息如下："
sing-box version
echo "========================================="
