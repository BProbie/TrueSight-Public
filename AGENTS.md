# AGENTS.md

给在此仓库中工作的 **AI 编码代理**（以及任何自动化工具）的说明。
人类贡献者的流程见 [CONTRIBUTING.md](CONTRIBUTING.md)，架构与检测细节见 [docs/](docs/README.md)。

## 一、项目是什么

仿冒检测防护系统：三条入口（**外链拦截** `/api/v1/goto`、**周期扫描**、
**人工举报** `/api/v1/report`）把线索送进同一套检测引擎，完成
「发现 → 研判 → 取证 → 处置 → 态势」的可解释、可降级、隐私最小化本地流水线。
外链拦截是最低延迟的旁路入口（不改被保护站点源码），但不是唯一入口。

仓库三块：`server/`（FastAPI + 检测引擎）、`frontend/`（Vue 3 三前端：公网 / 企业 / 平台）、`deploy/`（部署编排）。

## 二、命令速查（照抄即可）

```powershell
# 环境（幂等；首次会自动建 venv、装依赖、生成 .env）
powershell -File scripts/bootstrap.ps1

# 一键启动（含按需构建前端）
launch.bat                       # Windows：双击即可；等价于 scripts/launch.ps1
powershell -File scripts/run.ps1 -BuildFrontend

# 打包为独立可执行文件（目标机零环境；产物在 dist/，已在 .gitignore 忽略）
powershell -File scripts/build-exe.ps1      # Windows：dist/TrueSight.exe（img/logo.ico 自动作图标）
bash scripts/build-elf.sh                   # Linux / WSL2：dist/linux/TrueSight（ELF）

# 质量门禁（与 CI 完全一致：ruff check + ruff format --check + pytest + 前端构建）
powershell -File scripts/verify.ps1

# 只跑后端
cd server
.\.venv\Scripts\python.exe -m pytest -p no:cacheprovider
.\.venv\Scripts\python.exe -m ruff check app tests
.\.venv\Scripts\python.exe -m ruff format --check app tests

# uv 依赖同步（二期；需先安装 uv）
powershell -File scripts/uv-sync.ps1            # 开发依赖
powershell -File scripts/uv-sync.ps1 -Frozen    # 严格按 uv.lock（CI/交付）

# 只跑某一块 / 按名字过滤
.\.venv\Scripts\python.exe -m pytest tests/engine -q
.\.venv\Scripts\python.exe -m pytest -k "grading or fallback"

# 前端
cd frontend
npm install --no-audit --no-fund
npm run build          # 产出 apps/*/dist，由后端挂载在 / 与 /admin
npm run dev:admin      # 开发服务 5174（/api 代理到 8000）
```

## 三、铁律（违反即视为缺陷，即使功能"能跑"）

1. **先测试后实现**：每个模块先有全部通过的测试，才进入下一个模块；新增行为必须带测试。
   修改既有行为必须**同时改测试**并在提交信息里说明原因。
2. **测试绝不访问真实网络**：注入假实现（fetcher / tls / icp / intel / feed / 假 LLM 客户端）
   或用 `respx` 打桩；时间相关注入可控时钟（不要 `sleep`）；随机相关注入固定种子。
3. **错误只在边界归一化**：外部异常（httpx/sqlalchemy/…）统一转成 `app/core/errors.py` 里的
   项目错误类型；上层不得直接捕获第三方异常。
4. **降级必须可见**：任何失败要么进 `skipped_capabilities`（或等价结构），要么留一条中文说明。
   **禁止"静默少做一步"** —— 这是本项目最不能接受的缺陷。
5. **密钥零外泄**：日志、异常 `message`/`detail`、`repr`、API 响应都不得含明文或密文；
   密钥只可写入不可读回。
6. **公网模式不落原始数据**：`public` 模式下只消费脱敏投影表；管理接口只在 `local` 模式挂载。
7. **不要吞掉取消**：任何兜底链先 `except asyncio.CancelledError: raise`（否则上层超时形同虚设）。

## 四、结构地图（改哪里）

| 想改… | 去 |
| --- | --- |
| 打包入口 / 命令行参数 | `server/run_server.py`（目标机零环境运行；`scripts/build-exe.ps1` 是构建脚本） |
| 运行期路径（可写数据 / 打包资源） | `server/app/core/runtime.py`（`is_frozen()` 分流 exe 旁 `data/` 与 `_MEIPASS`） |
| 配置项 / 开关 | `app/core/config.py`（新增字段后同步 `.env.example` 与文档） |
| Logo / 端口 / 公网 / 允许 Host | 仓库根 `truesight.config.json`（解析见 `app/core/site_config.py`；优先级：命令行 > 环境变量 > 根配置 > 内置默认） |
| 日志与错误 | `app/core/logging.py`（用 `log_event`）、`app/core/errors.py` |
| 安全响应头 / 客户端 IP | `app/core/http_security.py`、`app/utils/net.py`（XFF 只在受信代理后采信） |
| 安全设计与加固文档 | `docs/SECURITY-ARCHITECTURE.md`、`ANTI-BYPASS.md`、`HARDENING.md`、`EXTENSIBILITY.md` |
| 界面操作说明 / 使用教程 | `docs/USAGE.md`（改页面按钮、文案或流程时同步） |
| 层级降级 / 熔断 | `app/core/degradation.py`（`Capability` → 保护等级计划） |
| 域名层检测 | `app/engine/dga/`（生成 / 筛查 / 新域监控） |
| 抓取与合规 | `app/engine/crawler/`（robots、逐跳 SSRF、体积上限） |
| 文本 / 证书 / 备案 | `app/engine/analyzers/` |
| 评分与阈值 | `app/engine/scoring/`（改权重必须写清标定依据） |
| 报告生成 | `app/engine/reporting/`（大模型优先，模板兜底） |
| 证据链 | `app/engine/forensics/` |
| 评估编排 | `app/engine/pipeline.py`（唯一出口；新能力务必结算 executed/skipped） |
| 判定 / 举报 / 取证 / 处置 / 后台 | `app/services/` |
| 租户 / 账号 / 登录 / 会话 / CSRF | `app/services/accounts.py`、`app/services/tenancy.py`、`app/core/auth_guard.py`、`app/api/local/auth.py` |
| 注册 / 验证码找回 / 个人资料 / 头像 | `app/services/accounts.py`（`register_tenant` / `recover_password` / `update_profile`）、`app/services/verification.py` |
| 套餐 / 订阅 / 权益版本 / 资产配额 | `app/services/plans.py`、`app/api/local/subscription.py` |
| 测试模式 / 正式服务 / 验证码收紧 | `app/services/test_mode.py`、`app/api/platform/root.py`（A 端设置页） |
| A 端平台控制台 / 公告 | `app/services/platform.py`、`app/api/platform/root.py`（仅 internal 构建） |
| 构建版本隔离（B 端 / B+A） | `app/core/build_info.py`、`scripts/build-exe.ps1`、`scripts/build-elf.sh` |
| 后台任务与调度 | `app/scheduler/` |
| 接口 | `app/api/public/`（公网）、`app/api/local/`（管理后台） |
| 前端契约与客户端 | `frontend/packages/shared/src/` |
| 前端页面 | `frontend/apps/*/src/views/` |
| 公告横幅 / 公告页 | `frontend/apps/admin-console/src/App.vue`、`views/AnnouncementView.vue` |

## 五、改动的标准路径

1. 想清属于哪一层与**为什么**（真实问题是什么、失败时怎么降级）；
2. 写测试（正常路径 + 失败降级路径 + 边界）；
3. 实现（遵守下面的约定）；
4. `powershell -File scripts/verify.ps1` 全绿；
5. 行为变化 → 更新 [CHANGELOG.md](CHANGELOG.md) 的「未发布」段；
   接口变化 → 更新 [docs/API.md](docs/API.md)；
   新增能力/阈值 → 更新 [docs/DETECTION.md](docs/DETECTION.md)。

## 六、代码与文档约定

* **全中文** docstring 与注释；标识符用英文；`from __future__ import annotations` 一律加上。
* 值对象优先 `frozen dataclass(slots=True)`；跨边界校验用 Pydantic；依赖从构造函数注入。
* 日志一律 `log_event(logger, level, "中文消息", field=value)`，不要用 `%` 拼接。
* **不要对全仓库跑 `ruff format`**（只格式化你改过的文件），线宽 100，规则集见 `pyproject.toml`。
* 文档写作要求：写清「**为什么**」而不只是「是什么」；明确区分「已实现」与「明确降级」。

## 七、禁区 / 已知坑

| 禁止 / 注意 | 原因 |
| --- | --- |
| 全仓库 `ruff format` | 会产生大量与本次改动无关的 diff，评审无法进行 |
| `print`、`logger.warning("x", host="y")` | 有 AST 架构测试守着；标准库会直接抛 `TypeError` |
| 提交 `.env`、`data/`、真实证据文件、真实密钥 | 见 [.gitignore](.gitignore) 与 [SECURITY.md](SECURITY.md) |
| 前端用 `v-html` 渲染后端或模型生成的文本 | 提示词注入会直接升级成 XSS |
| 关闭 `robots` 遵从或绕过 SSRF 去"让演示好看" | 合规底线，见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md) |
| 给 `*.ps1` 去掉 UTF-8 BOM | Windows PowerShell 5.1 会按 ANSI 解码中文，直接语法错 |
| 给 `*.json` 加 UTF-8 BOM | `vite build` 会报 `Unexpected token '' is not valid JSON` |
| 在 `session_scope` 里抛业务错误后自行包装 | 该上下文原样抛出 `TrueSightError`；包装会丢掉 409/404 语义 |
| Windows 与 WSL 共用 `server/.venv` | Windows 脚本会检查 `pyvenv.cfg` 并自动重建；Linux 侧（`launch.sh` / `build-elf.sh`）改用 `server/.venv-linux`，不再删除 Windows venv |
| 直接采信 `X-Forwarded-For` | 客户端可伪造；只有配置 `abuse.trusted_proxies` 后才解析（`app/utils/net.py`） |
| 给页面加 CSP 时放行内联脚本 | 会抵消 XSS 防护；统一在 `app/core/http_security.py` 维护 |
| 把企业成员直接建成 OWNER，或绕过 B 端最小权限 | 企业租户必须遵循最小权限，写权限由现有 OWNER 显式授予；A 端内部运营控制台是例外，平台账号统一拥有完整权限 |
| 把验证码明文写入日志、列表接口或 `repr` | 验证码等价于临时改密凭证；日志只记录脱敏目标与渠道 |
| 在 `stub` 模式下对外宣称「验证码已发送」 | 该模式不会真正发送，界面必须明确提示任意验证码可通过 |
| 让设置页参与 `KeepAlive` 缓存 | 未保存的草稿会跨菜单残留，用户会误以为参数已生效；`App.vue` 的 `exclude` 必须保留 `SettingsView` |
| 「清空命中」连带删除确认/上报/解决记录 | 这些是已定性结论而非待办；清空只允许删除待处理状态，撤回确认走 `findings/exclude-confirmed` |
| 大改后不跑 `verify.ps1` 就宣称完成 | 门禁包含全部测试 + 静态检查 + 前端构建 |

## 八、完成标准（代理自检清单）

- [ ] `powershell -File scripts/verify.ps1` 通过（或已明确说明只跑了哪一部分及原因）；
- [ ] 新行为有测试，且测试**离线可复现**；
- [ ] 失败路径**降级可见**；
- [ ] 没有新增密钥/明文外泄点；
- [ ] 受影响的文档与 CHANGELOG 已同步更新；
- [ ] 改动范围与用户请求一致（没有顺手重构无关代码）。
