# TrueSight | 明鉴 | 仿冒检测防护系统

**仿冒检测防护系统** —— 从外链拦截、周期扫描与人工举报中发现仿冒站点，
用域名 / 内容 / 证书 / 备案与可选的 AI 灰区复核做**可解释的风险判定**，
再把取证、研判报告、处置留痕与脱敏态势串成一条**可降级、隐私最小化**的本地流水线。

外链拦截（`/api/v1/goto`）是延迟最低的入口，但不是唯一入口：后台周期扫描与人工举报
共用同一套检测引擎，三类来源最终汇入统一的命中记录、证据链与处置流程。

![version](https://img.shields.io/badge/version-1.1.5-blue)
![tests](https://img.shields.io/badge/tests-1352%20passed-brightgreen)
![lint](https://img.shields.io/badge/ruff-clean-brightgreen)
![python](https://img.shields.io/badge/python-3.12-blue)
![license](https://img.shields.io/badge/license-MIT-green)

> **版本说明**：当前为 **1.1.5**——修复拦截确认页在失败后「按钮点了没反应」的问题；
> 词典导入补齐会话凭据与 CSRF；A 端到期时间与公告生效时间改为本地可读格式；
> 项目定位统一为「仿冒检测防护系统」。

---

## 快速开始

> 前置：**Python 3.12**（必需）、**Node 20+**（可选，仅用于页面；不装也能用接口）。

**方式一：一键启动（推荐，首次运行会自动把环境准备好）**

```powershell
./launch.bat                 # Windows：双击本文件，或在终端执行
./launch.sh                  # Linux / macOS
```

它会自动：建虚拟环境并装依赖 → 生成 `server/.env` → 按需构建前端页面 → 启动服务 → 打开浏览器。
想换模式/端口：`launch.bat public 8010`（只读脱敏模式，端口 8010）。

**方式二：分步执行（想看清每一步时用）**

```powershell
powershell -File scripts/bootstrap.ps1            # ① 准备环境（幂等）
powershell -File scripts/run.ps1 -BuildFrontend   # ② 构建前端并启动
```

**根目录配置 `truesight.config.json`**（修改后重新启动生效）：

| 字段 | 作用 |
| --- | --- |
| `logo.image` | 图片 Logo 与 Favicon：http(s) 地址、相对路径，或绝对路径（含 Windows `D:\\Work\\...\\logo.jpg`；JSON 里反斜杠要写 `\\`）。仅支持 PNG/JPG/JPEG/WEBP/GIF；远程地址由访客浏览器直接加载 |
| `logo.fallback_glyph` / `fallback_letter` | 图片不可用时依次回退的字形与字母 |
| `server.mode` / `host` / `port` | 一键启动的默认模式、监听地址与端口 |
| `public.base_url` | 对外访问地址（goto 中转与举报结果页） |
| `public.allowed_hosts` | 允许的 Host 列表；留空不启用限制，支持 `*.example.com` |
| `public.dashboard_days` | 仿冒态势默认窗口（7 / 30 / 90） |
| `frontend.web_port` / `admin_port` | 前端开发服务端口 |

优先级：**命令行 > 环境变量 > 根配置 > 内置默认**。`launch.bat public 8010`
仍可临时覆盖配置；`server/.env` 中显式写过的公网地址不会被根配置覆盖。

启动后打开：

| 地址 | 内容 |
| --- | --- |
| <http://127.0.0.1:8000/> | 公网侧页面：仿冒态势 / 提交举报 / 拦截提示 |
| <http://127.0.0.1:8000/admin/> | 本地管理后台：总览 · 公告 · 名单 · 模型 · 服务 · 日志 · 设置 · 订阅 · 存储 · 检查；头像进入「我的」 |
| <http://127.0.0.1:8000/root/> | A 端平台控制台（默认账号 `root / 123456`，首次登录后请修改；「设置」页可切换测试/正式服务；仅 `internal` 构建；business 交付包不存在） |
| <http://127.0.0.1:8000/healthz> | 健康检查 |

首次打开 `/admin` 且系统还没有账号时，页面默认停在「注册」；登录、注册、找回密码在同一张
卡片内切换（不再提供初始化入口）。之后可用 **用户名、邮箱或手机号**配合密码登录
（同名账号可展开填写组织标识）。注册要求填写邮箱与手机号并分别验证，
组织名称/标识收在展开箭头后；找回密码同样走邮箱/手机验证码（测试模式下任意填写即可通过，
接入邮件/短信并切换 `strict` 后才会真实校验；A 端关闭测试模式后强制校验）。点击左上角头像进入「我的」，
点击资料卡头像即可更换头像，可修改昵称、组织名称、邮箱、手机号与密码；修改联系方式需要
对应验证码。默认一个账号只允许一台设备在线，连续失败会临时锁定。
企业交付包不展示网页初始化入口，可由部署者预置账号；注册开关仍由部署配置控制。
详见 [docs/PLATFORM.md](docs/PLATFORM.md)。

**1 分钟验证（无需任何外部账号，逐行复制即可）**：

```powershell
# ① 探活
curl.exe -s http://127.0.0.1:8000/healthz

# ② 把自己的资产登记为受保护资产（自动进入白名单，立即生效）
#    PowerShell 5.1 对 curl.exe 的引号转义不稳定，这里用原生 Invoke-RestMethod
Invoke-RestMethod -Method Post -Uri http://127.0.0.1:8000/api/v1/admin/assets `
  -ContentType 'application/json; charset=utf-8' `
  -Body '{"value":"example.com","label":"示例站点"}'

# ③ 判定「自家域名」的外链 → 应直接放行（action=allow，reason_code=whitelisted）
curl.exe -s "http://127.0.0.1:8000/api/v1/goto?to=https%3A%2F%2Fexample.com%2Fnews&format=json"

# ④ 判定一个内网地址 → 应被 SSRF 防护拦下（blocked_ssrf）
curl.exe -s "http://127.0.0.1:8000/api/v1/goto?to=http%3A%2F%2F127.0.0.1%2F&format=json"

# ⑤ 拉一次脱敏态势数据
curl.exe -s "http://127.0.0.1:8000/api/v1/dashboard?days=7"
```

> 验证完成后，可在管理后台「名单」页删除示例资产 `example.com`（删除需二次确认）。

> **两个必须知道的边界**（都是刻意设计，不是缺陷）：
> 1. **不可解析的域名会被 SSRF 策略拒绝**（fail-closed）——所以不要拿 `xxx-not-exist.top`
>    这类不存在的域名试判定，会得到 `blocked_ssrf`；
> 2. **未登记的域名会走真实检测**，需要外网可达且受 2500ms 预算约束；
>    超出预算时结论为 `indeterminate` 按保护等级降级（2 级下表现为确认页）。

**想离线看完整效果**（含命中详情、证据链、研判报告）：打开
<http://127.0.0.1:8000/admin/> → 「名单」加一个品牌资产 → 「服务」页点「立即执行」跑一轮扫描
→ 「日志」页看命中详情与报告。完整演示脚本见 [docs/FAQ.md 第十二节](docs/FAQ.md#十二怎么演示最省事)。

**跑一遍质量门禁**（与 CI 同款：静态检查 + 1352 项测试 + 前端构建）：

```powershell
powershell -File scripts/verify.ps1
```

不想用脚本？手动步骤见 [server/README.md](server/README.md)；
容器部署见 [deploy/README.md](deploy/README.md)。

---

## 零环境运行：独立可执行文件

最终用户不需要安装 Python 或 Node。按平台构建一次，分发一个文件：

```powershell
powershell -File scripts/build-exe.ps1
# 产物：dist/TrueSight.exe（已内置 Python 运行时与前端页面）
```

```bash
bash scripts/build-elf.sh
# 产物：dist/linux/TrueSight（ELF 64-bit；需在 Linux / WSL2 中构建）
```

* **构建机**需要 Python 3.12 + Node 20；Windows 复用 `server/.venv`，Linux 使用
  `server/.venv-linux`（两个平台互不覆盖），首次自动安装 PyInstaller；
* **目标机**不需要 Python、Node、数据库或任何运行库；Windows 双击即可，Linux 直接 `./TrueSight`；
* 首次运行会在可执行文件旁创建 `data/`（SQLite、证据、日志都写在这里），请放在可写目录；
* 根目录存在 `img/logo.ico` 时，Windows 构建会自动把它设为 exe 图标；
* 配置：可执行文件旁的 `truesight.config.json`（Logo/公网/Host）与 `.env`（密钥/开关），
  也可用 `--port 8010 --mode public --no-browser` 覆盖；
* 可执行文件按平台构建，体积较大，`dist/` 已在 `.gitignore` 中忽略；
* 升级只需替换可执行文件，`data/`、`.env` 与 `truesight.config.json` 会保留。

详细说明见 [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md#三独立可执行文件便携分发)。

---

## 它解决什么问题

品牌仿冒的生命周期远不止「用户点开链接」：域名先被注册、页面复制上线、证据需要固定、
举报需要留痕、处置结果需要复盘。TrueSight 覆盖整条链路，并用**三条入口**把线索送进同一套引擎：

| 入口 | 触发方式 | 适合场景 |
| --- | --- | --- |
| 外链拦截 `GET /api/v1/goto` | 用户点击外链时实时裁决 | 官网、邮件、短信、社交平台中的可疑链接 |
| 周期扫描（APScheduler） | 形近域名生成、新域情报源、历史命中重扫 | 主动发现尚未开始传播的仿冒站 |
| 人工举报 `GET /api/v1/report` | 用户 / 客服提交网址 | 已收到钓鱼线索，需要人工复核 |

三条入口共用同一条流水线：

```
发现（外链 / 扫描 / 举报）
  → 域名 / 内容 / 证书 / 备案检测（可选 AI 灰区复核）
  → 加权评分与风险分级
  → 命中落库（按可注册域去重）
  → 取证与研判报告
  → 人工确认 / 排除 / 投稿审核
  → 举报留痕（默认演练）
  → 脱敏态势看板与审计日志
```

**外链拦截路径（旁路式，延迟最低）**：

```
官网外链 ──改写──▶ /api/v1/goto?to=…  ──┬─ 放行 ──▶ 302 直达目标（用户无感）
                                        ├─ 中等及以上 ──▶ /gate 提示页
                                        │    （风险明细 + 1/2/3 次确认；5 级直接拦截）
                                        └─ 无法判定从严 ──▶ 按保护等级降级 / 拦截
```

> 「旁路式」描述的是外链拦截这一入口：不改被保护站点源码、可随时摘除。
> 周期扫描与人工举报不需要改写站点，也能独立发现仿冒。

三条设计主线决定了它的一切取舍：

| 主线 | 含义 | 体现 |
| --- | --- | --- |
| **多入口、一套引擎** | 外链 / 扫描 / 举报共用同一判定与处置 | 同一评估器、同一评分、同一命中记录与证据链 |
| **分级降级** | 单点失败绝不阻断判定 | 每层能力独立降级，降级**必须可见**（`skipped` + 中文说明） |
| **隐私最小化** | 数据不出本机、不留原文 | 公网端只拿脱敏投影；举报者标识只存带盐哈希；密钥只可写入不可读回 |

---

## 能力矩阵（已实现 vs 明确降级）

| 层 | 能力 | 状态 |
| --- | --- | --- |
| 入口 | 外链拦截 / 周期扫描 / 人工举报 | ✅ 三条来源共用同一评估器与命中记录 |
| L0 域名 | 形近域名生成（10 类手法）、可疑度筛查、新注册域名监控 | ✅ 已实现（新域监控需配情报源） |
| L0 域名 | RDAP/WHOIS、DNS 解析 | ⚠️ 流水线占位，明确跳过（不静默） |
| L0 域名 | 威胁情报源 | ⚠️ 未配置即明确跳过 |
| L1 内容 | 合规抓取（robots + 逐跳 SSRF + 体积上限）、文本语义 | ✅ 已实现 |
| L1 内容 | TLS 证书分析 | ✅ 已实现 |
| L1 内容 | ICP 备案核验 | ⚠️ 可插拔（默认明确「未核对」，不假装查过） |
| L2 多模态 | 研判报告（大模型优先 + 规则模板兜底） | ✅ 已实现（无模型也永远生得出来） |
| L2 多模态 | 视觉相似度比对 | ⚠️ 明确未接入（仅能力位与降级说明） |
| L3 处置 | 自动取证（原文 + SHA-256 + 时间戳 + 清单） | ✅ 已实现 |
| L3 处置 | 对外举报通道（默认只演练，人工确认后发送） | ✅ 已实现 |
| 运维 | 周期任务调度（5 个任务，默认关闭） | ✅ 已实现 |
| 运维 | 本地管理后台十页 + 审计日志 | ✅ 已实现 |
| 呈现 | 公网态势 / 举报受理 / 拦截提示 + 管理后台 | ✅ 公网只读脱敏投影，管理接口仅 local 模式 |

> 这张表本身就是「分级降级」的证据：每一项都能回答「为什么不做」或「缺什么才能做」。
> 详见 [docs/DETECTION.md](docs/DETECTION.md)。

---

## 项目结构

```
server/        FastAPI 服务端（单代码库双模式：local 全功能 / public 只读脱敏）
  app/core/      配置 · 日志 · 错误 · 安全 · 分级降级
  app/engine/    检测引擎（纯 Python，不依赖 FastAPI 与数据库）
  app/services/  业务服务：账号 · 租户 · 套餐订阅 · 名单 · 判定 · 举报 · 处置 · 取证 · 后台 · 设置
  app/api/       路由（public / local 管理后台 / platform A 端 / open 开放情报）
  app/scheduler/ 周期任务编排与调度接线
  app/web.py     前端静态产物挂载
  tests/         1352 项测试（与 app 结构镜像）
frontend/      Vue 3 三前端（npm workspaces + Vite + TS）
  apps/web-client/     公网侧：仿冒态势 / 提交举报 / 拦截提示
  apps/admin-console/  B 端管理后台（含登录、订阅、公告）
  apps/root-console/   A 端平台控制台（仅 internal 构建打包）
  packages/shared/     共用的 API 客户端、类型契约、中文标签映射
deploy/        Dockerfile（多阶段）· docker-compose · nginx 示例 · 部署清单
scripts/       bootstrap · launch · run · verify · build-exe · build-elf · uv-sync（含跨平台依赖自检）
docs/          使用教程 / 架构 / 检测 / 现状 / 算法 / 全流程 / 创新点 / 安全架构 / 防绕过 /
               加固 / 扩展 / 接口 / 数据与隐私 / 开发 / 部署 / FAQ
```

---

## 文档导航

| 我想… | 去看 |
| --- | --- |
| 5 分钟跑起来 | 本页「快速开始」 |
| 按界面逐页学会日常使用 | [docs/USAGE.md](docs/USAGE.md) |
| 账号登录、套餐订阅、A 端与构建隔离 | [docs/PLATFORM.md](docs/PLATFORM.md) |
| 看懂整体怎么运作 | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) |
| 搞清检测能力与评分怎么标定 | [docs/DETECTION.md](docs/DETECTION.md) |
| 知道现在有什么、哪些没做、边界在哪 | [docs/STATUS.md](docs/STATUS.md) |
| 看懂算法公式与标定逻辑 | [docs/ALGORITHMS.md](docs/ALGORITHMS.md) |
| 看清看得见与看不见的全流程 | [docs/FLOWS.md](docs/FLOWS.md) |
| 了解背景、创新点与不足 | [docs/INNOVATIONS.md](docs/INNOVATIONS.md) |
| 搞清信任边界、威胁模型与安全控制 | [docs/SECURITY-ARCHITECTURE.md](docs/SECURITY-ARCHITECTURE.md) |
| 看攻击者怎么绕、我们怎么防 | [docs/ANTI-BYPASS.md](docs/ANTI-BYPASS.md) |
| 把服务安全地放到真实网络 | [docs/HARDENING.md](docs/HARDENING.md) |
| 为二期加能力 / 数据源 / 接口 | [docs/EXTENSIBILITY.md](docs/EXTENSIBILITY.md) |
| 调用接口 / 联调前端 | [docs/API.md](docs/API.md) |
| 了解数据怎么存、隐私怎么保 | [docs/DATA-AND-PRIVACY.md](docs/DATA-AND-PRIVACY.md) |
| 上手改代码、加一个检测能力 | [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) |
| 部署到服务器 / 制作 Windows/Linux 可执行文件 | [docs/DEPLOYMENT.md](docs/DEPLOYMENT.md) |
| 准备**答辩**、回应追问 | [docs/FAQ.md](docs/FAQ.md) ← 建议先看这一篇 |
| 全部文档索引 | [docs/README.md](docs/README.md) |

---

## 工程约束（不是口号，有守门）

| 约束 | 守门方式 |
| --- | --- |
| 每个模块先有全绿测试才进下一个模块 | 1352 项测试；`scripts/verify.ps1` 一键复现 |
| 测试绝不访问真实网络 | 注入假抓取器 / 假证书检查器 / 假简历源，或用 `respx` 打桩 |
| 外部失败归一化为项目错误类型 | `app/core/errors.py`；上层不认识 httpx/sqlalchemy 异常 |
| 降级必须可见 | 计划内能力必然落在 executed ∪ skipped（有专门用例） |
| 日志不得误用标准库关键字、禁用 `print`、关键模块必须走脱敏日志 | `tests/test_conventions.py` 用 AST 扫描 `app/` |
| 业务错误不被误包装成存储错误 | `tests/db/test_session.py` |
| 密钥零外泄（日志/异常/响应/repr） | 脱敏工具 + 审查用例 |
| 前端不得用 `v-html` 渲染模型生成文本 | 报告一律按纯文本渲染 |

---

## 常用命令

```powershell
# 环境与运行
powershell -File scripts/bootstrap.ps1            # 一键准备环境（幂等）
powershell -File scripts/run.ps1                  # 启动（默认 local 模式，127.0.0.1:8000）
powershell -File scripts/run.ps1 -Mode public     # 只读脱敏模式（无管理后台）
powershell -File scripts/run.ps1 -Reload          # 开发热重载

# 质量门禁
powershell -File scripts/verify.ps1               # 静态检查 + 测试 + 前端构建
powershell -File scripts/verify.ps1 -SkipFrontend # 没装 Node 时只验后端

# 前端（可选）
cd frontend; npm run dev:admin                    # 管理后台开发服务 5174（/api 代理到 8000）
cd frontend; npm run build                        # 构建两个应用到 apps/*/dist
```

---

## 隐私与合规（重要）

1. **不外传**：模型 API 密钥本地加密存储且**只可写入不可读回**；对外举报默认只演练留痕，
   需「开关 + 通道配置 + 人工确认」三项同时满足才会真正发送；
2. **合规抓取**：遵循 `robots.txt`（取不到时保守拒绝）、逐跳 SSRF 校验、跳转与体积上限；
   周期扫描**默认关闭**；
3. **最小化**：举报者 IP 只存带盐哈希；证据文件存本地磁盘，库中只有「路径 + 哈希 + 脱敏上下文」；
4. **数据隔离**：公网端只消费单向脱敏投影表，物理上读不到原始证据与注册人信息。

最终合规责任在部署者，详见 [SECURITY.md](SECURITY.md) 与 [docs/DATA-AND-PRIVACY.md](docs/DATA-AND-PRIVACY.md)。

---

## 参与贡献

* 想改代码：[CONTRIBUTING.md](CONTRIBUTING.md)（铁律与流程）+ [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)（怎么加能力/加页面）
* 想报安全问题：**不要开公开 Issue**，见 [SECURITY.md](SECURITY.md)
* 行为准则：[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)
* 变更历史：[CHANGELOG.md](CHANGELOG.md) · 贡献者：[CONTRIBUTORS.md](CONTRIBUTORS.md) · 给 AI 编码代理的说明：[AGENTS.md](AGENTS.md)

## 许可证

[MIT](LICENSE) © 2026 TrueSight / 明鉴 / 仿冒检测防护系统 contributors.
