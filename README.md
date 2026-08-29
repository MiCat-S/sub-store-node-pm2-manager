# Sub-Store Node.js + PM2 一键管理脚本

这是一个给 Debian、Ubuntu 和 Raspberry Pi ARM64 使用的 Sub-Store 管理脚本。

不熟悉 Node.js、PM2 或 systemd 也没关系。运行脚本后按照中文菜单选择，就可以完成：

- 安装 Sub-Store 前端和后端
- 自定义安装目录、端口、前端目录和数据目录
- 使用 PM2 后台运行并配置开机启动
- 手动更新或定时自动更新前端和后端
- 管理 Sub-Store 官方支持的环境变量
- 管理多个互相独立的 Sub-Store 实例
- 更新前自动备份，失败时自动回滚
- 安全卸载，不删除系统 Node.js、PM2 或其他项目

项目地址：[Autlin/sub-store-node-pm2-manager](https://github.com/Autlin/sub-store-node-pm2-manager)

## 开始前需要什么

服务器需要满足：

| 项目 | 要求 |
| --- | --- |
| 系统 | Debian 或 Ubuntu |
| 架构 | `amd64` 或 `arm64` |
| 权限 | `root`，或者可以使用 `sudo` |
| 网络 | 可以访问 GitHub、NodeSource 和系统软件源 |

支持 Raspberry Pi ARM64，但系统必须是 Debian/Ubuntu ARM64。

## 一行命令安装

使用普通用户登录服务器时执行：

```bash
curl -fsSL https://raw.githubusercontent.com/Autlin/sub-store-node-pm2-manager/main/substore.sh -o /tmp/substore.sh && chmod +x /tmp/substore.sh && sudo /tmp/substore.sh
```

如果当前已经是 `root`，可以去掉 `sudo`：

```bash
curl -fsSL https://raw.githubusercontent.com/Autlin/sub-store-node-pm2-manager/main/substore.sh -o /tmp/substore.sh && chmod +x /tmp/substore.sh && /tmp/substore.sh
```

Raw 脚本地址：[substore.sh](https://raw.githubusercontent.com/Autlin/sub-store-node-pm2-manager/main/substore.sh)

进入菜单后选择：

```text
1. 安装 Sub-Store
```

部署成功后，管理命令会安装到：

```text
/usr/local/sbin/substore
```

以后只需要运行：

```bash
sudo substore
```

## 第一次安装怎么填写

安装时会依次询问下面这些内容。不确定时可以直接按 Enter 使用默认值。

### 1. 部署目录

```text
部署目录 [/opt/sub-store]:
```

这里保存后端程序、`.env`、PM2 配置和更新备份。

小白建议直接按 Enter：

```text
/opt/sub-store
```

### 2. 监听端口

```text
监听端口 [3000]:
```

这是 Sub-Store 提供网页和 API 的端口。没有被其他程序占用时，建议直接使用 `3000`。

### 3. PM2 进程名称

```text
PM2 进程名称 [sub-store]:
```

这是在 `pm2 status` 中显示的名称。单实例安装建议保持 `sub-store`。

### 4. 监听地址

```text
监听地址（127.0.0.1 仅本机；:: 监听全部） [127.0.0.1]:
```

推荐使用 `127.0.0.1`。这表示只能由服务器本机访问，适合配合 Nginx、Caddy 或宝塔反向代理，更安全。

需要通过服务器 IP 或局域网直接访问时，可以填写 `::`。使用前请确认防火墙和访问控制配置正确。

### 5. 持久化数据目录

```text
持久化数据目录 [/opt/sub-store/data]:
```

这是最重要的目录，保存订阅、组合订阅和设置等数据。

默认使用 `/opt/sub-store/data`。需要把数据单独放在大硬盘时，可以填写 `/data/sub-store-data`。

### 6. 前端文件目录

```text
前端文件目录（更新后的 dist 解压位置） [/opt/sub-store/frontend]:
```

这里保存网页前端的 `index.html` 和静态文件。

使用反向代理把整个域名转发到 Sub-Store 时，直接使用默认值最简单。

如果希望把前端更新到宝塔网站目录，可以填写：

```text
/www/wwwroot/sub-store.example.com
```

以后自动更新前端时，新的官方 `dist.zip` 会继续解压到这个目录，不会改回默认路径。安装时不会覆盖已经存在且非空的目录。

### 7. 后端路径前缀

```text
后端路径前缀（SUB_STORE_FRONTEND_BACKEND_PATH） [/一串随机字符]:
```

这是前端访问后端 API 使用的路径。脚本会自动生成一个 64 位随机值，建议直接按 Enter。

示例：

```text
/84f6c212ecc93553b9c00874efc889e362f36b58251a119c1dacbfc197cbda32
```

它必须以 `/` 开头。Sub-Store 当前只支持一个路径前缀，不支持同时填写多个入口。

这个路径不是登录密码，公网部署仍然建议使用 HTTPS、访问控制或 VPN。

### 8. 自动更新

```text
是否启用定时自动检查并更新前端和后端 [Y/n]:
```

建议输入 `Y` 或直接按 Enter。

随后填写：

```text
检查间隔（分钟，最小 5） [60]:
```

小白建议保持每 60 分钟检查一次。

## 安装完成后会看到什么

成功后脚本会显示类似：

```text
Sub-Store 安装完成
管理实例：default
部署目录：/opt/sub-store
数据目录：/opt/sub-store/data
PM2 名称：sub-store
后端版本：2.x.x
前端版本：2.x.x
本机健康检查：http://127.0.0.1:3000/随机路径/api/utils/env
```

检查 PM2：

```bash
pm2 status
```

正常状态应该显示：

```text
sub-store    online
```

## 怎么打开网页

### 使用 IP 直接访问

只有监听地址设置为 `::` 或其他可访问地址时，才能从其他电脑直接打开：

```text
http://服务器IP:3000/?api=http://服务器IP:3000/随机路径
```

### 使用域名和反向代理

推荐让 Nginx、Caddy 或宝塔把整个域名反向代理到：

```text
http://127.0.0.1:3000
```

Nginx 基础示例：

```nginx
server {
    listen 80;
    server_name sub-store.example.com;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

配置 HTTPS 后，第一次可以打开：

```text
https://sub-store.example.com/?api=https://sub-store.example.com/随机路径
```

## 日常使用

打开中文管理菜单：

```bash
sudo substore
```

菜单如下：

```text
========== Sub-Store Manager ==========

1. 安装 Sub-Store
2. 更新 Sub-Store
3. 启动 Sub-Store
4. 停止 Sub-Store
5. 重启 Sub-Store
6. 查看运行状态
7. 查看 PM2 日志
8. 修改监听端口
9. 管理 Env
10. 查看当前配置
11. 查看当前版本
12. 卸载 Sub-Store
13. 自动更新设置
14. 查看全部管理实例
0. 退出
```

常用命令：

| 操作 | 命令 |
| --- | --- |
| 启动 | `sudo substore start` |
| 停止 | `sudo substore stop` |
| 重启 | `sudo substore restart` |
| 查看状态 | `sudo substore status` |
| 查看日志 | `sudo substore logs` |
| 手动更新 | `sudo substore update` |
| 修改端口 | `sudo substore port 3100` |
| Env 管理 | `sudo substore env` |
| 自动更新设置 | `sudo substore auto` |
| 查看配置 | `sudo substore config` |
| 查看版本 | `sudo substore version` |
| 卸载 | `sudo substore uninstall` |

## 自动更新

安装时没有启用，或者需要修改间隔时运行：

```bash
sudo substore auto
```

菜单：

```text
1. 启用或修改检查间隔
2. 停用自动更新
3. 查看状态与下次执行时间
4. 查看自动更新日志
5. 立即检查更新
0. 返回
```

自动更新会同时检查后端官方 `sub-store.bundle.js` 和前端官方 `dist.zip`。

没有新版本时不会重启 Sub-Store。有新版本时会先备份，再更新前端和后端；更新或健康检查失败时会自动恢复旧版本。

自动更新由 systemd timer 调度，不会再创建一个一直运行的 PM2 updater。

查看下次执行时间：

```bash
systemctl list-timers substore-manager-update.timer
```

查看状态：

```bash
systemctl status substore-manager-update.timer
```

查看自动更新日志：

```bash
journalctl -u substore-manager-update.service -n 100 --no-pager
```

默认行为：

- 开机约 10 分钟后检查
- 默认每 60 分钟检查
- 加入最多 5 分钟随机延迟
- 手动更新和定时更新不会同时执行

## 手动更新

运行：

```bash
sudo substore update
```

脚本会：

1. 检查当前前端和后端版本。
2. 查询两个官方 GitHub Release。
3. 没有更新时直接退出，不重启服务。
4. 有更新时下载并校验文件大小和 SHA-256。
5. 停止当前实例并备份程序、前端、Env、PM2 配置和数据。
6. 替换需要更新的文件。
7. 重启 PM2，检查端口和 API。
8. 检查失败时恢复更新前版本。

备份位置：

```text
<部署目录>/backups/<时间>-<版本>/
```

更新不会改变自定义端口、PM2 名称、`.env`、数据目录、前端目录或后端随机路径。

## 修改前端目录

首次安装时可以直接填写前端目录。

安装后需要修改时运行：

```bash
sudo substore env
```

依次选择：

```text
2. 修改 Env
SUB_STORE_FRONTEND_PATH
```

输入新目录，例如：

```text
/www/wwwroot/sub-store.example.com
```

新目录必须已经存在 `index.html`。如果没有，可以先把当前前端文件复制过去，或者重新安装时直接指定该目录。

如果老部署的 `SUB_STORE_FRONTEND_BACKEND_PATH` 只存在于 PM2 环境而没有写入 `.env`，管理器会尝试自动读取并补全；仍然找不到时才会提示输入当前路径。

## 修改端口

运行：

```bash
sudo substore port 3100
```

脚本修改的是 Sub-Store 官方变量：

```env
SUB_STORE_BACKEND_API_PORT="3100"
```

修改前会检查端口是否被占用。重启或健康检查失败时会自动恢复旧端口。

## 管理多个 Sub-Store

原来的实例叫做 `default`。不带 `--instance` 时，所有命令都操作它：

```bash
sudo substore update
```

安装第二个实例：

```bash
sudo substore --instance second install
```

管理第二个实例：

```bash
sudo substore --instance second update
sudo substore --instance second restart
sudo substore --instance second env
sudo substore --instance second auto
sudo substore --instance second uninstall
```

查看全部实例：

```bash
sudo substore instances
```

每个实例必须使用不同的监听端口、PM2 进程名称、部署目录、数据目录和前端目录。

命名实例会自动得到建议值。例如 `second`：

```text
建议部署目录：/opt/sub-store-second
建议 PM2 名称：sub-store-second
```

状态文件分别保存在：

```text
default：/etc/substore-manager/instance.conf
second： /etc/substore-manager/instances/second/instance.conf
```

自动更新 timer 也互相独立：

```text
default：substore-manager-update.timer
second： substore-manager-update-second.timer
```

更新、重启或卸载一个实例不会操作其他实例。

## 导入已有的 Node.js + PM2 部署

如果服务器已经通过 PM2 运行 `sub-store.bundle.js`，但没有管理器状态文件，选择安装时会提示是否导入。

导入会读取 PM2 进程名称、程序路径、工作目录、现有 `.env`、数据目录和前端目录，不会覆盖现有程序、Env 和数据。

如果服务器有多个未管理的 Sub-Store PM2 进程，脚本会列出来供选择。已经被其他管理实例记录的 PM2 进程不会重复导入。

## Env 是什么

Env 是 Sub-Store 的环境变量配置，保存在：

```text
<部署目录>/.env
```

权限为 `600`，只有 root 可以读取。

管理 Env：

```bash
sudo substore env
```

菜单：

```text
1. 查看当前 Env
2. 修改 Env
3. 新增自定义 Env
4. 删除 Env
5. 恢复默认值
0. 返回
```

管理器只内置 Sub-Store 官方源码和部署文档实际支持的变量，例如：

```text
SUB_STORE_BACKEND_API_PORT
SUB_STORE_BACKEND_API_HOST
SUB_STORE_DATA_BASE_PATH
SUB_STORE_FRONTEND_PATH
SUB_STORE_BACKEND_MERGE
SUB_STORE_FRONTEND_BACKEND_PATH
SUB_STORE_CORS_ALLOWED_ORIGINS
SUB_STORE_BACKEND_DEFAULT_PROXY
SUB_STORE_BACKEND_SYNC_CRON
SUB_STORE_MMDB_*
```

不会使用虚假的通用变量 `PORT`、`HOST` 或 `DATA_DIR`。完整示例见 [`.env.example`](.env.example)。

涉及路径、端口、URL、代理、CORS 和 cron 的值会做基本格式检查。敏感值只显示部分内容。修改后启动失败会恢复旧 `.env`。

## 文件放在哪里

默认目录：

```text
/opt/sub-store/
├── sub-store.bundle.js       后端程序
├── frontend/                 官方前端文件
│   └── index.html
├── data/                     重要持久化数据
│   ├── root.json
│   └── sub-store.json
├── backups/                  更新前自动备份
├── .env                      Sub-Store 环境变量
├── ecosystem.config.cjs      PM2 配置
└── .substore-manager-instance
```

管理器状态：

```text
/etc/substore-manager/instance.conf
```

当前 Sub-Store Node 源码没有独立的通用 cache/config 目录变量。核心设置和缓存状态随 `root.json`、`sub-store.json` 保存在 `SUB_STORE_DATA_BASE_PATH`。

可选 MMDB 文件由 `SUB_STORE_MMDB_COUNTRY_PATH` 和 `SUB_STORE_MMDB_ASN_PATH` 指定。

## Node.js 和 PM2 怎么安装

脚本读取 Sub-Store 官方 `.node-version`，只使用其中的主版本选择 NodeSource 安装通道。

例如官方文件是 `24.15.0`，脚本会选择 `setup_24.x`，不会强制安装 `24.15.0`。APT 最终安装 NodeSource 当前提供的 Node 24 版本。

同主版本的现有 Node.js 会直接使用。需要安装时，脚本会：

1. 下载 NodeSource 一键配置脚本。
2. 使用 `bash -n` 做语法检查。
3. 执行 NodeSource 配置脚本。
4. 通过 APT 安装 `nodejs`。
5. 检查 `node` 和 `npm` 是否可用。

PM2 不存在时使用：

```bash
npm install -g pm2@latest
```

安装后会执行 `pm2 save` 并配置 `pm2-root.service` 开机启动。

## 为什么不用 pnpm install

官方 Release 已经提供构建完成的 `sub-store.bundle.js`，后端运行依赖已经由官方构建流程打包进去。

因此服务器不需要克隆后端源码，也不需要执行 `pnpm install`。前端 `dist.zip` 同样是构建完成的静态文件，下载并解压即可。

## 卸载

卸载默认实例：

```bash
sudo substore uninstall
```

卸载命名实例：

```bash
sudo substore --instance second uninstall
```

脚本只删除当前管理实例，不会删除系统 Node.js、全局 PM2、其他 PM2 项目、其他 Sub-Store 实例或其他 Node.js 项目。

数据默认保留。选择删除数据时，需要输入带实例 ID 的二次确认。只有由管理器新建的数据目录才允许自动删除；安装前已经存在或从旧实例导入的数据目录不会自动删除。

## 非交互安装

高级用户可以直接传入参数：

```bash
sudo env \
  SUBSTORE_NON_INTERACTIVE=1 \
  SUBSTORE_INSTALL_DIR=/opt/sub-store \
  SUBSTORE_DATA_DIR=/data/sub-store-data \
  SUBSTORE_FRONTEND_DIR=/www/wwwroot/sub-store.example.com \
  SUBSTORE_PORT=3000 \
  SUBSTORE_PM2_NAME=sub-store \
  SUBSTORE_HOST=127.0.0.1 \
  SUBSTORE_MAGIC_PATH=/my-private-path \
  SUBSTORE_AUTO_UPDATE=1 \
  SUBSTORE_AUTO_UPDATE_MINUTES=60 \
  /tmp/substore.sh install
```

安装命名实例时可以使用：

```bash
sudo env \
  SUBSTORE_INSTANCE=second \
  SUBSTORE_NON_INTERACTIVE=1 \
  SUBSTORE_PORT=3002 \
  /tmp/substore.sh install
```

这些 `SUBSTORE_*` 变量只控制管理器安装过程。真正传递给 Sub-Store 的变量仍然是 `.env` 中的 `SUB_STORE_*`。

## 常见问题

### 提示端口已被占用

换一个端口，例如 `3001`，或者检查占用程序：

```bash
ss -ltnp | grep ':3000'
```

### PM2 显示 online，但网页打不开

先运行：

```bash
sudo substore status
sudo substore logs
```

如果监听地址是 `127.0.0.1`，外部设备不能直接访问，必须配置反向代理。

### 修改前端目录时报 BACKEND_PATH 错误

更新管理器：

```bash
curl -fsSL https://raw.githubusercontent.com/Autlin/sub-store-node-pm2-manager/main/substore.sh -o /tmp/substore.sh
bash -n /tmp/substore.sh
sudo install -m 755 /tmp/substore.sh /usr/local/sbin/substore
```

新版会尝试从 PM2 当前进程恢复 `SUB_STORE_FRONTEND_BACKEND_PATH`。仍然找不到时，请输入当前使用且以 `/` 开头的后端路径。

### 修改 `.env` 后没有生效

执行：

```bash
sudo substore restart
```

### 自动更新是否正常

运行 `sudo substore auto`，然后选择：

```text
3. 查看状态与下次执行时间
4. 查看自动更新日志
```

### GitHub 下载失败

确认服务器能够访问：

```text
github.com
api.github.com
raw.githubusercontent.com
```

低频更新通常不需要 GitHub Token。需要 Token 时只在当前 Shell 环境中导出，不要写入仓库或日志。

## 实现依据

本管理器不是把 Sub-Store 当作普通 Node.js 项目套模板。实现依据包括：

- [Sub-Store 后端仓库](https://github.com/sub-store-org/Sub-Store)
- [Sub-Store 前端仓库](https://github.com/sub-store-org/Sub-Store-Front-End)
- [Sub-Store Wiki](https://github.com/sub-store-org/Sub-Store/wiki)
- [Xream Sub-Store 自建教程](https://xream.notion.site/Sub-Store-Docker-8efc1aea40fa431b9a562b78994e7fb8)
- [xream/sub-store Docker 文档](https://hub.docker.com/r/xream/sub-store)

当前审计基线日期为 2026-08-29：后端 `2.36.40`、前端 `2.29.10`、官方 `.node-version` 为 `24.15.0`。脚本运行时会查询最新 Release，不会固定下载这些版本。

## 测试

项目包含：

- Shell 语法检查和 ShellCheck
- 官方 Env 清单对账
- Env 读写和格式校验
- PM2 ecosystem 配置测试
- systemd service/timer 语法验证
- 真实官方 Release 下载
- 自定义端口和前端目录测试
- 前后端成功更新测试
- 更新失败回滚测试
- 数据和 Env 保留测试
- 双实例同时运行和隔离测试
- 安全卸载测试

运行基础测试：

```bash
bash -n substore.sh
shellcheck substore.sh tests/*.sh
bash tests/test.sh
./tests/check-official-env.sh
```

运行 Docker 集成测试：

```bash
./tests/docker-integration.sh
```

测试 NodeSource 一键安装：

```bash
TEST_NODE_INSTALL=1 ./tests/docker-integration.sh
```

在 ARM64 Docker daemon 上测试：

```bash
TEST_PLATFORM=linux/arm64 ./tests/docker-integration.sh
```
