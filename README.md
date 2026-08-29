# Sub-Store Node.js + PM2 Manager

面向 Debian、Ubuntu 和 Raspberry Pi ARM64 的 Sub-Store 原生 Node.js 部署、更新与管理脚本。

本项目不是通用 Node.js 模板。运行入口、Env、目录和更新资产均来自 Sub-Store 当前官方实现：

- 后端：`sub-store-org/Sub-Store` Release 的 `sub-store.bundle.js`
- 前端：`sub-store-org/Sub-Store-Front-End` Release 的 `dist.zip`
- Node 构建基线：两个官方仓库的 `.node-version`
- 持久化：后端源码读取的 `SUB_STORE_DATA_BASE_PATH`
- Env：后端源码 `process.env` 读取点、官方 Docker Hub 文档和官方前端读取点的交集

当前审计基线日期为 2026-08-29：后端 `2.36.40`、前端 `2.29.10`、Node `24.15.0`。脚本运行时会查询最新 Release，不固定下载这些旧值。

同时参考 Xream 的 [Sub-Store 自建教程](https://xream.notion.site/Sub-Store-Docker-8efc1aea40fa431b9a562b78994e7fb8) 中“自己部署前后端”章节。该章节给出的 Node 运行结构是：官方前端 `dist.zip`、官方后端 `sub-store.bundle.js`、`SUB_STORE_BACKEND_MERGE=true`、单个路径前缀、独立前端目录和数据目录。本管理器在此基础上增加 PM2、持久化状态、更新校验和回滚，不改变 Sub-Store 的运行入口。

## 为什么不执行 pnpm install

官方 GitHub Actions 使用 esbuild 将 Node 运行依赖打入 `sub-store.bundle.js` 并作为 Release 资产发布。因此部署 Release bundle 只需要 Node.js，不需要在服务器克隆源码或安装后端 `node_modules`。前端 `dist.zip` 已经是构建完成的静态文件。

官方 Node 部署没有单独的包管理器更新命令；管理器更新的是官方 workflow 实际发布的两个 Release 资产，并使用 GitHub 提供的摘要校验。

## 一键安装

直接下载并启动管理器：

```bash
curl -fsSL https://raw.githubusercontent.com/Autlin/sub-store-node-pm2-manager/main/substore.sh -o /tmp/substore.sh && chmod +x /tmp/substore.sh && sudo /tmp/substore.sh
```

Raw 脚本地址：[substore.sh](https://raw.githubusercontent.com/Autlin/sub-store-node-pm2-manager/main/substore.sh)

首次部署成功后，管理器会安装为：

```text
/usr/local/sbin/substore
```

以后直接运行：

```bash
sudo substore
```

也可以克隆仓库后运行：

```bash
git clone https://github.com/Autlin/sub-store-node-pm2-manager.git
cd sub-store-node-pm2-manager
chmod +x substore.sh
sudo ./substore.sh
```

选择 `1. 安装 Sub-Store`，按提示设置：

- 部署目录，默认 `/opt/sub-store`
- 监听端口，默认 `3000`
- PM2 进程名，默认 `sub-store`
- 监听地址，默认 `127.0.0.1`（仅本机）；输入 `::` 可监听全部地址
- 数据目录，默认 `<部署目录>/data`
- 后端路径前缀 `SUB_STORE_FRONTEND_BACKEND_PATH`，默认自动生成随机值，也可自定义

也可以执行：

```bash
sudo ./substore.sh install
```

非交互安装示例：

```bash
sudo env \
  SUBSTORE_NON_INTERACTIVE=1 \
  SUBSTORE_INSTALL_DIR=/data/sub-store \
  SUBSTORE_DATA_DIR=/data/sub-store-data \
  SUBSTORE_PORT=3000 \
  SUBSTORE_PM2_NAME=sub-store \
  SUBSTORE_HOST=127.0.0.1 \
  SUBSTORE_MAGIC_PATH=/my-private-path \
  ./substore.sh install
```

这些 `SUBSTORE_*` 变量仅是管理器的安装输入，不会传递给 Sub-Store。Sub-Store 自身只使用 `.env` 中真实支持的 `SUB_STORE_*` 变量。

## 目录结构

默认安装后：

```text
/opt/sub-store/
├── sub-store.bundle.js
├── frontend/
│   └── index.html
├── data/
│   ├── root.json
│   └── sub-store.json
├── backups/
├── .env
├── ecosystem.config.cjs
└── .substore-manager-instance
```

当前 Node 源码没有独立的配置目录或缓存目录 Env。核心配置和缓存状态随 `root.json`、`sub-store.json` 保存在 `SUB_STORE_DATA_BASE_PATH`；可选 MMDB 文件位置则由对应的 `SUB_STORE_MMDB_*_PATH` 控制。管理器不会虚构额外的 cache/config 路径。

管理器实例状态集中保存在：

```text
/etc/substore-manager/instance.conf
```

它记录部署目录、Env、数据路径、PM2 名称、端口、Node 路径和版本，不把实例参数散落在脚本中。

## Node.js 与 PM2

脚本读取官方 `.node-version`，只取其中的主版本来选择 NodeSource 安装通道，例如 `.node-version` 为 `24.15.0` 时使用 `setup_24.x`。它不会把补丁版本 `24.15.0` 固定成安装目标；APT 最终安装 NodeSource 仓库当前提供的 Node 24 版本。

缺少 Node.js，或者现有 Node 主版本与该通道不一致时，会下载并执行 NodeSource 官方 `setup_<主版本>.x` 一键配置脚本，再通过 APT 安装 `nodejs`；支持 `amd64` 和 `arm64`。NodeSource 脚本会先保存到临时文件并通过 `bash -n` 检查，不直接使用不可检查的管道执行。安装完成只验证 `node` 和 `npm` 可用，以 NodeSource/APT 实际安装结果为准。同主版本的现有 Node.js 会直接复用。

PM2 不存在时使用 npm 全局安装。PM2 配置固定：

- `script` 指向官方 `sub-store.bundle.js`
- `cwd` 指向部署目录，使 bundle 内置的 `dotenv.config()` 读取 `<部署目录>/.env`
- `interpreter` 指向实际 Node 可执行文件
- `watch: false`
- 单实例 fork 模式

安装完成会执行 `pm2 save` 并配置 `pm2-root.service` 开机启动。

## 前后端连接

默认使用官方支持的合并模式：

```env
SUB_STORE_BACKEND_MERGE="true"
SUB_STORE_FRONTEND_PATH="/opt/sub-store/frontend"
SUB_STORE_FRONTEND_BACKEND_PATH="/随机路径"
```

首次访问可使用：

```text
http://服务器:端口/?api=http://服务器:端口/随机路径
```

健康检查使用：

```text
http://127.0.0.1:端口/随机路径/api/utils/env
```

`SUB_STORE_FRONTEND_BACKEND_PATH` 是路径前缀，不是登录密码。公网部署仍应配合 HTTPS、访问控制或 VPN。

交互安装会显示一个 64 位十六进制随机默认路径，可以直接回车接受，也可以修改成自己的路径。官方实现只支持一个 `SUB_STORE_FRONTEND_BACKEND_PATH` 字符串，不支持用逗号等方式同时配置多个入口；以后可在 Env 管理中更换。

## 自定义端口

菜单选择 `8. 修改监听端口`，或执行：

```bash
sudo substore port 3100
```

脚本修改的是官方真实变量：

```env
SUB_STORE_BACKEND_API_PORT="3100"
```

它会检查端口占用、重启 PM2、检查监听状态和 `/api/utils/env`。失败时恢复旧端口。

## Env 管理

```bash
sudo substore env
```

菜单提供：

```text
1. 查看当前 Env
2. 修改 Env
3. 新增自定义 Env
4. 删除 Env
5. 恢复默认值
0. 返回
```

官方 Env 会显示名称、用途和源码默认值。端口、路径、布尔开关、CORS、代理、URL 和 cron 会进行基本格式检查。路径前缀、推送服务、远程数据 URL/处理表达式等按敏感值脱敏显示。Env 重启验证失败时会恢复修改前的 `.env`；数据目录必须保持绝对路径，管理器不会把它重置为源码默认的当前工作目录 `.`。

Env 独立保存为 `<部署目录>/.env`，权限为 `600`。更新只替换后端 bundle 和前端静态文件，不覆盖 Env。PM2 的工作目录固定为部署目录，因此 restart、PM2 resurrect 和系统重启都会重新加载它。

完整示例见 [`.env.example`](.env.example)。以下变量属于 Docker 的 HTTP-META，而不是 Node 后端，因此没有加入 Node 配置：

```text
HOST
PORT
META_DISABLE_AUTO_CLEAN
META_TEMP_FOLDER
```

旧变量 `SUB_STORE_BACKEND_CRON` 和 `SUB_STORE_CRON` 已被官方标记弃用，管理器使用 `SUB_STORE_BACKEND_SYNC_CRON`。

## 更新

```bash
sudo substore update
```

更新流程：

1. 读取当前 bundle 内嵌版本和管理器记录的前端版本。
2. 查询两个官方仓库的最新 Release。
3. 下载变更的资产并校验 GitHub 提供的大小与 SHA-256。
4. 停止当前 PM2 实例，备份 Env、PM2 配置、程序、前端和完整数据目录。
5. 仅替换后端 bundle 和前端静态文件。
6. 重启并检查 PM2、监听端口和 `/api/utils/env` 返回的 Node 后端版本。
7. 健康检查失败时恢复程序、前端、Env 和数据。

备份位于：

```text
<部署目录>/backups/<时间>-<版本>/
```

更新不会删除部署目录，不会覆盖 `.env`、数据目录、自定义端口或 PM2 名称。Release bundle 不使用服务器端 `node_modules`，因此没有需要重新安装的项目依赖；脚本仍会重新检查官方 Node 构建基线。

## PM2 管理

推荐通过菜单或管理器命令操作：

```bash
sudo substore start
sudo substore stop
sudo substore restart
sudo substore status
sudo substore logs
```

直接使用 PM2 也可以：

```bash
pm2 status
pm2 logs sub-store
pm2 restart sub-store
pm2 save
```

## 导入已有 Node + PM2 部署

状态文件不存在但 PM2 中存在以 `sub-store.bundle.js` 为入口的进程时，安装菜单会提示导入。导入会读取 PM2 的程序路径、工作目录和现有 `.env`，不会覆盖程序、数据或 Env。

## 卸载

```bash
sudo substore uninstall
```

脚本只删除状态文件中记录的 PM2 实例。它不会卸载系统 Node.js、全局 PM2、其他 PM2 项目或其他 Node.js 项目。

默认保留持久化数据。选择删除数据时必须输入带实例 ID 的二次确认，并且数据目录中的管理标记必须匹配。只有管理器首次创建的数据目录允许自动删除；安装前已经存在或从既有实例导入的数据目录始终保留。导入的既有实例默认保留原程序、Env、前端和数据。

## Raspberry Pi ARM64

脚本允许 Debian/Ubuntu `arm64`，NodeSource 提供对应架构的 Node.js。部署使用官方 JavaScript bundle 和静态前端，不在树莓派上编译 Sub-Store 源码或 npm 原生依赖。

## 常见问题

### PM2 在线但页面打不开

检查：

```bash
sudo substore status
sudo substore logs
```

确认监听地址。如果设为 `127.0.0.1`，只能从本机或反向代理访问；局域网直连可将官方变量 `SUB_STORE_BACKEND_API_HOST` 修改为 `0.0.0.0` 或 `::`，同时做好访问控制。

### 修改 `.env` 后没有生效

执行：

```bash
sudo substore restart
```

不要用通用 `PORT`、`HOST`、`DATA_DIR` 替代官方 `SUB_STORE_*` 变量。

### GitHub API 限额

低频手动更新通常无需 Token。需要时可在执行管理器前导出 `GITHUB_TOKEN`；不要把 Token 写入仓库或日志。

## 验证

仓库测试：

```bash
bash -n substore.sh
shellcheck substore.sh tests/*.sh
bash tests/test.sh
./tests/check-official-env.sh
./tests/docker-integration.sh
```

`docker-integration.sh` 默认使用 `linux/amd64`。在 ARM64 Docker daemon 上可执行：

```bash
TEST_PLATFORM=linux/arm64 ./tests/docker-integration.sh
```

它会验证实际 Release 下载、PM2 启动、Env 加载、自定义端口、成功更新、失败回滚、数据保留和安全卸载。

额外验证 NodeSource 一键安装流程：

```bash
TEST_NODE_INSTALL=1 ./tests/docker-integration.sh
```
