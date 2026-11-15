# 已有后端如何切换到 DayDayHealth

新部署直接使用[项目说明](../README.md#部署后端)。这份步骤适用于已经运行 `/api/v1/healthkit-archive` 归档接口的服务器。此次改名可沿用原业务数据库、训练记录、账号、健康归档和 API 路径。

## 需要改的地方

| 配置项 | 新值或操作 |
| --- | --- |
| 源码目录 | 把这份 `backend/` 上传到服务器的新源码目录。 |
| 镜像 | API 和 worker 都使用新源码重建，镜像可命名为 `daydayhealth-backend:local`。 |
| Python 模块 | API 使用 `daydayhealth.main:app`，worker 使用 `python -m daydayhealth.worker_main`，管理命令使用 `python -m daydayhealth.cli`。新 Dockerfile 已配置 API 入口。 |
| 环境变量 | 将旧项目大写前缀换成 `DAYDAYHEALTH_`，保留后缀和实际配置值。 |
| 稳定的服务入口 | 继续使用当前 HTTPS 域名、反向代理端口和 Cloudflare Access 设置。若代理按服务名寻址，保持原服务名，或让代理指向新的服务名。 |

## 服务器上实际要做的步骤

1. 记录当前 Compose 项目名、镜像、端口、各挂载（包括 openGym 的只读数据卷）和环境变量来源。停止 API 和 worker 写入，从同一个时点备份业务 SQLite、独立健康归档目录、账号白名单、profiles、archive、签名密钥以及当前 Compose 配置。保留当前源码和镜像用于回退。
2. 在原 Compose 项目中复制一份生产配置，将 API 和 worker 的 `build.context` 指向上传的新 `backend/`。将镜像名和 worker 的启动命令换成上表的新值。如果现网给 API 写了显式启动命令，也更新模块名。保留此前的项目名、服务键、端口和挂载目标。
3. 在新配置和它读取的 `.env` 中改变量名。如下变量的**值**应继续指向当前实例的路径或配置。若原来靠默认值，请现在显式填写旧实例的实际值。

   | 变量 | 值填什么 |
   | --- | --- |
   | `DAYDAYHEALTH_DB` | 现有业务库在容器内的绝对路径，保留原文件名。归档库由同一目录下的 `healthkit/records.sqlite3` 定位。 |
   | `DAYDAYHEALTH_CURSOR_SECRET_FILE` | 现有游标签名密钥文件。使用环境变量提供密钥的部署则改为 `DAYDAYHEALTH_CURSOR_SECRET`。 |
   | `DAYDAYHEALTH_PASSWORD_PEPPER_FILE` | 现有密码 pepper 文件。使用环境变量提供的部署则改为 `DAYDAYHEALTH_PASSWORD_PEPPER`，并让原先依赖该文件的 worker 保持能读取同一份值。 |
   | `DAYDAYHEALTH_USER_CSV` | 现有账号白名单文件。API 和需要对账的 worker 指向同一份白名单。 |
   | `DAYDAYHEALTH_PROFILES_DIR`、`DAYDAYHEALTH_ARCHIVE_DIR` | 现有资料与归档目录。保留原容器内路径，已有账号的数据库记录可能包含这些路径。 |
   | `DAYDAYHEALTH_OPENGYM_USERS`、`OPENGYM_DATA_DIR` | 现有 openGym 映射快照文件和数据卷挂载点。 |
   | `DAYDAYHEALTH_LOGIN_HOSTS`、`DAYDAYHEALTH_CF_ACCESS_FILE` | 沿用原来的登录域名和 Access 凭证文件。单域名部署可把登录域名项留空。 |
   | `DAYDAYHEALTH_CATALOG` | 若使用镜像自带词表，删掉覆盖配置，或改为 `/app/daydayhealth/data/exercise_catalog.json`。自定义词表继续用已有挂载。 |

4. 在原部署目录执行下列命令。命令假定新生产配置名为 `compose.production.yaml` 且原 Compose 项目的服务键为 `api` 和 `worker`。只部署 API 的实例可省略 `worker`。

   ```sh
   docker compose -f compose.production.yaml config --quiet
   docker compose -f compose.production.yaml build api worker
   docker compose -f compose.production.yaml up -d api worker
   docker compose -f compose.production.yaml logs --tail=80 api worker
   ```

5. 通过原 HTTPS 地址访问 `/healthz`。如果监控检查响应中的服务名，将预期值更新为 `daydayhealth`。用原有账号登录，检查健康归档 `/identity` 返回原实例 UUID，并确认手机能拉到原训练记录。最后上传一条测试记录并验证可以按 UUID 下载。
6. 如需回退，先停止新容器，再用原配置和原镜像启动。若还原升级前的运行目录快照，升级后新写入的数据也会随快照回退。

现有 API token、账号 ID、公开 API 路径、表结构和数据字段仍按原协议读取。公开项目使用新的文件与服务名称。部署历史实例时可以继续指向已有的数据文件，服务品牌与实际数据文件名可以分别配置。

新 iOS 工程的 Bundle ID 为 `org.daydayhealth.app`，用于公开项目源码签名。使用这个标识安装时，iOS 会把它视为另一款 App，需要重新授权和登录。旧版的本机数据和钥匙串留在各自的 App 容器中。若需要在原 App 容器上覆盖升级，应先单独验证原签名、备份恢复和本机数据迁移。
