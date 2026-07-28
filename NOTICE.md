# NOTICE

## 上游来源

本项目 `xray-xhttp` 是 [Yulinanami/my-xhttp-cdn-config](https://github.com/Yulinanami/my-xhttp-cdn-config) 的**衍生作品**。

上游以 MIT 许可发布，版权归 Yulinanami 所有。本仓库沿用其许可证（见 [LICENSE](./LICENSE)），并在 LICENSE 中同时保留上游版权行。

**沿用自上游的部分**：

- `src/` 模块化安装流程与 `@@include` 模板拼装机制
- `templates/` 全部模板（Nginx / Xray / 客户端 / Mihomo）
- `extensions/` 三组扩展脚本（双 CDN、双 IP、QUIC）
- `docs/1.md` – `docs/9.md`、`docs/llms-full.md`、客户端模板文件
- `.github/scripts/build-*.sh` 与 release workflow

**本项目新增或改写的部分**：

- `src/06-net-tuning.sh`：内核 / 句柄流控调优与能力探测
- `src/13-manage-cli.sh`：管理命令 `xh`（状态、订阅、日志、内核更新与回滚、调优开关、保活、卸载）
- `src/04-input.sh`：非交互一键部署（环境变量 + `AUTO=1`）
- `src/09-server-config.sh`：节点状态文件 `/etc/xhttp-cdn/node.env`
- `templates/xray-config.json.tmpl`：`sockopt` 注入
- `templates/nginx.conf.tmpl`：句柄、连接数与 gRPC 长连接超时
- `docs/10.流控调优.md`、`docs/11.管理命令.md`、`README.md`

## 借鉴但未复制代码的项目

[yonggekkk/argosbx](https://github.com/yonggekkk/argosbx)（GPL-3.0）提供了本项目在**产品形态**上的参考：常驻管理命令、一键无交互部署、保活自愈、内核自动更新、内建卸载。

该项目采用 GPL 系许可证。本项目**未复制其任何源代码**，上述能力均为独立实现。

## 第三方组件

安装脚本在目标主机上下载并安装以下第三方软件，各自遵循其原有许可证：

- [XTLS/Xray-core](https://github.com/XTLS/Xray-core)（MPL-2.0）
- [nginx](https://nginx.org/)（2-clause BSD）
- [acmesh-official/acme.sh](https://github.com/acmesh-official/acme.sh)（GPL-3.0）
- [apernet/hysteria](https://github.com/apernet/hysteria)（MIT，仅 `add-quic.sh` 扩展会安装）
