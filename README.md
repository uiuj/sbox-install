# 🚀 Sing-box 轻量双协议一键部署脚本

针对 **小内存服务器（如 Alpine Linux / NAT 小鸡）** 深度定制优化的 Sing-box 双协议一键部署脚本。

* ✅ **一键安装** 自动部署 Sing-box 最新服务端
* ✂️ **极致瘦身**：改用原生 Shell 变量处理。
* 🔒 **顶配安全**：同时部署 **VLESS Reality (Apple 伪装)** 与 **Hysteria 2** 两种目前最强防封锁协议。
* 📲 **自动化体验**：安装完成后直接在终端吐出一键导入客户端的 `vless://` 和 `hy2://` 节点链接。
* 🛠️ **轻量面板**：保留后台管理功能，输入 `sb` 即可召唤无 `jq` 依赖的超轻量安全管理面板。

---

## 💾 一键安装命令

请复制下方命令，在你的服务器终端中整行粘贴并回车执行：

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/uiuj/sbox-install/refs/heads/main/install.sh)"
