# 天天健康 · DayDayHealth

在 iPhone 上查看自己的健康近况，把 Apple 健康记录、训练和饮食放在一起看。你可以在手机上看趋势、问 AI「我最近怎么样」，也可以把授权的健康记录同步到自己部署的服务。

[功能](#功能) · [快速开始](#快速开始) · [部署后端](#部署后端) · [连接手机](#连接手机) · [接入 openGym](#接入-opengym) · [备份与恢复](#备份与恢复)

当前文档对应 **iOS 1.0.2** 和实现 `/api/v1/healthkit-archive` 的 **配套后端**。

## 功能

| 功能 | 可以做什么 |
| --- | --- |
| Apple 健康与趋势 | 在手机上查看可读取的健康指标和历史趋势。首次打开时请求 Apple 健康权限，可按类别授权。 |
| 健康记录归档 | 登录自己的服务器后，上传已授权的历史和后续记录。归档支持批量上传、大记录分片续传和按账号隔离。 |
| 训练与饮食 | 拉取映射到当前账号的 openGym 训练记录，并在手机上记录饮食、查看热量和营养信息。 |
| AI 健康问答 | 使用自己配置的模型服务。允许 AI 读取哪些健康、训练或饮食记录，由用户单独设置。聊天带上设备本地时间和时区，可选共享近似城市。 |
| AI 健康日报 | 手动生成或重新生成昨日日报，结合可用的近期记录分析变化。开启环境数据共享后，可参考天气与空气质量，有明显影响时才在日报里提及。 |
| 本地通知与备份 | 日报生成后可安排 iOS 本地通知。App 也提供「备份与恢复」入口，可将快照保存到已登录的服务器。 |

Apple 健康的归档范围由设备、HealthKit 接口和授权共同决定。临床记录、医疗文件、眼镜处方和用药记录在「Apple 健康权限」中分别申请。iOS 26 起，在「Apple 健康权限」中逐项授权用药记录。

开启「每日通知」后，日报默认从 **07:30** 起尝试准备，目标通知时间为 **08:00**。实际时间取决于 iOS 后台唤醒和生成进度，通知由手机本地安排。

## 快速开始

1. 准备一台 **iOS 17 或更新版本**的 iPhone。用源码安装时，Mac 上可使用 Xcode 27。
2. 只在手机上查看 Apple 健康、记录饮食或使用 AI 时，可以先安装客户端，直接使用手机端功能。要同步到自己的服务器，再完成下文的部署和登录。
3. 要在手机上看到已有的 openGym 训练，部署后端后接入自己的 openGym 数据卷，并把对应的用户 ID 映射到登录账号。
4. 要用 AI，到「设置 → AI 模型」配置模型地址、模型 ID 和 API Key。AI 由手机直连服务商，自托管后端无需配置模型密钥。

iOS 工程位于 `iOS/`，后端位于 `backend/`。已有服务器可先看[后端切换步骤](backend/MIGRATION.md)。

### 安装 iPhone 客户端

**用 Xcode 自行签名。** 打开 `iOS/DayDayHealth.xcodeproj`，选择 `DayDayHealth` target，在 *Signing & Capabilities* 中选自己的 Team。需要时改为该 Team 可签发的 Bundle Identifier，确认 HealthKit 已启用。要使用后台健康数据交付或临床记录，还需确保签名的描述文件包含相应能力。选择已配对的 iPhone 运行。 [Apple 的 HealthKit 配置说明](https://developer.apple.com/documentation/xcode/configuring-healthkit-access)

**用 Sideloadly 安装。** 下载 [DayDayHealth-1.0.2.ipa](https://github.com/812147495lz-max/daydayhealth/releases/download/v1.0.2/DayDayHealth-1.0.2.ipa)。在 Mac 或 Windows 上将它拖入 [Sideloadly](https://sideloadly.io/)，选择目标 iPhone 和自己的 Apple Account，按提示重签并安装。重签后的签名与描述文件必须支持 HealthKit。成功装上 App 后，在首次打开时检查是否弹出了 Apple 健康权限窗口。第三方账号用 Sideloadly 从零安装并完成全程同步，仍待真机验收。

**验证首次启动。** 可用独立 Bundle ID 签一份测试版，与原 App 同时安装。首次打开时检查普通 Apple 健康授权弹窗，处理弹窗后确认能进入首页。独立标识有自己的数据容器，登录和模型配置需要重新填写。

## 部署后端

1. 在服务器装好 Docker 和 Docker Compose，把仓库里的整个 `backend/` 目录复制到服务器，例如 `/srv/daydayhealth/backend/`。
2. 进入刚复制的目录，创建运行目录并复制账号模板。

   ```sh
   cd /srv/daydayhealth/backend
   mkdir -p runtime config
   cp -n yonghu.example.csv config/yonghu.csv
   ```

3. 打开 `config/yonghu.csv`，把第二行的 `myuser` 改成你的登录用户名。设置目录权限。

   ```sh
   sudo chown 984:978 runtime config config/yonghu.csv
   sudo chmod 750 runtime config
   sudo chmod 640 config/yonghu.csv
   ```

4. 用目录里自带的 [compose.yaml](backend/compose.yaml) 启动 API。

   ```sh
   docker compose -f compose.yaml up -d --build api
   curl -fsS http://127.0.0.1:18090/healthz
   ```

5. 把两条命令中的 `myuser` 换成第 3 步填写的用户名，创建账号并按提示设置密码。

   ```sh
   docker compose -f compose.yaml exec api python -m daydayhealth.cli create-user --username myuser
   docker compose -f compose.yaml exec api python -m daydayhealth.cli set-password --username myuser
   ```

6. 将域名指向服务器。在同一台服务器的反向代理中添加该域名，将上游设为 `http://127.0.0.1:18090`，启用可信 HTTPS 证书，保留 `Authorization` 请求头。使用 App 备份时，将代理的请求体上限设为至少 64 MiB。
7. 把 `health.example.com` 换成你的域名，检查 HTTPS 入口。

   ```sh
   curl -fsS https://health.example.com/healthz
   ```

## 连接手机

1. 首次打开 App 时，在系统弹窗里选择要授权的 Apple 健康类别。
2. 打开「设置 → 服务器 → 配置后端」，填入第 7 步验证过的 HTTPS 地址，点「保存后端」。单域名部署时，关闭「使用独立登录地址」和「使用 Cloudflare Access」。
3. 输入部署时创建的用户名和密码，点「登录」。
4. 在服务器上检查 `backend/runtime/healthkit/records.sqlite3` 是否写入健康记录。

## 接入 openGym

1. 找到 openGym 使用的 Docker 数据卷，并从自己的 `state-<用户ID>.json` 文件名里记下用户 ID。确认容器的 UID 984 能读取该文件。
2. 在服务器的 `backend/compose.opengym.yaml` 底部，把 `sport_opengym_data` 改成自己的数据卷名。
3. 在服务器的 `backend/` 目录执行。把 `YOUR_OPENGYM_USER_ID` 和 `myuser` 换成自己的值。

   ```sh
   docker compose -f compose.yaml exec api python -m daydayhealth.cli map --opengym-user-id YOUR_OPENGYM_USER_ID --username myuser
   docker compose -f compose.yaml -f compose.opengym.yaml up -d --build worker
   docker compose -f compose.yaml -f compose.opengym.yaml logs --tail=80 worker
   ```

4. 在手机打开「训练与饮食」，核对训练记录。

## 配置 AI 和日报

1. 到「设置 → AI 模型」选择服务商，或填入兼容 Chat Completions 的 HTTPS API 地址。输入服务商给出的模型 ID 和 API Key，点「测试连接」，再点「保存并使用」。
2. 在「设置 → AI 数据共享」选择可用于模型请求的数据类别。可以分别授权健康、训练、饮食等记录。要让 AI 知道所在城市或参考天气，分别开启相应选项并允许 iOS 使用近似位置。
3. 打开「管家 → AI 健康日报」，点「生成昨日日报」。已经生成时可点「重新生成昨日日报」。需要本地通知时，在设置的「AI 健康日报通知」中开启「每日通知」，并选择时间。
4. 环境功能开启后，App 以近似坐标查询 Open-Meteo，向模型提供天气和空气质量摘要。日报用当前近似位置查询昨天的环境，旅行时该位置可能与昨天所在地点不同。 [Open-Meteo 天气](https://open-meteo.com/en/docs) · [空气质量](https://open-meteo.com/en/docs/air-quality-api)

Apple 健康读取由 iOS 授权控制。归档写入已登录的自部署服务器。向模型服务商提供个人记录、城市或天气数据，由「AI 数据共享」中的相应选项控制。

## 备份与恢复

1. 用自己的服务器账号登录，打开「设置 → 备份与恢复」，点「立即完整备份」。
2. 等待「备份成功」，在「远端备份」列表核对时间和大小。卸载或换机前，先确认后端可以读取该快照并校验 SHA-256。
3. 重装后连接同一服务器、登录同一账号，在「远端备份」选择原快照，点「备份现有数据并恢复」。App 会先下载并校验快照，再备份当前本机记录，最后执行替换。
