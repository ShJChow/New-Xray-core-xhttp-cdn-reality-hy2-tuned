# Lessons

## 2026-07-26 · 生成 xray-xhttp

### L1 · `set -e` 下的调优模块必须 best-effort

**失败机制**：构建器给产物加了 `set -e`。`sysctl -w`、`modprobe tcp_bbr`、写 `limits.d` 在 OpenVZ / LXC / Alpine 上都可能失败，一旦失败会在 Xray 已安装但配置尚未生成的中间态整体中断，留下半成品系统。

**规则**：任何"锦上添花"的系统级写操作，一律先能力探测再逐项试写，失败只 `warn`，绝不让它成为 AND-OR 链的最后一条命令。

### L2 · 未加引号的 heredoc 渲染模板时，`$` 属于 shell 不属于目标配置

**失败机制**：`cat > /etc/nginx/nginx.conf << NGINXEOF` 会展开模板里所有 `$`。新增 `$request_time`、`$binary_remote_addr` 这类 nginx 变量若不写成 `\$`，渲染后直接变成空串，且**语法仍然合法**，故障只在运行时暴露。

**规则**：往这类模板加行前，先确认 heredoc 是否加引号；未加引号则所有目标语言的变量必须转义，改完立刻 `grep '\$' 模板 | grep -v '\\\$'` 复查。

### L3 · 配置字段名不凭记忆写

**失败机制**：`tcpcongestion` 与 `tcpCongestion` 大小写不同；`tcpNoDelay` 已被 Xray 移除；`scMaxEachPostBytes` 在服务端是上限而非目标值。凭印象写出的配置可能让 `xray -test` 直接失败，或产生反向优化。

**规则**：写第三方配置字段前查官方文档（`xtls.github.io/config/transports/sockopt.html` 等），并用离线渲染 + 解析器（`python -m json.tool`）在本地先验证一遍结构。

### L4 · 单位换算不能假定平台常量（页大小）

**失败机制**：`net.ipv4.tcp_mem` 的单位是"页"，而 `MemTotal` 是 kB。写 `$2/4` 等于硬编码 4 KB 页。RHEL 系的 aarch64 内核（Oracle Linux / UEK）常用 **64 KB 页**，页数会偏大 16 倍——24 GB 机器算出的 `tcp_mem` 上限超过物理内存，TCP 永远不进入内存压力状态，只会一直分配。方向恰好是最坏的那一侧。

**规则**：凡涉及"页/块/扇区"单位的换算，一律用 `getconf PAGESIZE` 之类的运行时查询，不写常量；并补一条**量纲断言**（如"`tcp_mem` 上限必须小于物理内存"）而不只是打印数值——这类 bug 靠肉眼看数字发现不了。

### L5 · 测试里手抄的函数副本 = 测不到漂移

**失败机制**：渲染测试里把 `render_policy_json` / `render_sockopt_kv` 手抄了一份。当时与源码一致，但源码一改，测试仍然测的是旧副本，还照样"全绿"。

**规则**：测试要执行**产物里的真实代码**（用 `awk` 从 `dist/*.sh` 抽取函数定义再 `source`），而不是复制一份等价实现。

### L6 · 交付时如实区分"已构建"与"已验证"

**规则**：本机无法运行的部分（VPS 上的证书签发、服务启动、链路连通性）必须在报告里单独列为未验证项，不能让"构建成功、语法检查通过"读起来像"功能可用"。
