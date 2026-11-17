# 开发指南

## 一、环境准备（一条命令）

```powershell
launch.bat                                  # 一键启动：首次运行会自动准备好一切
# 或分步执行：
powershell -File scripts/bootstrap.ps1     # 建 venv、装依赖、生成 .env、装前端依赖
powershell -File scripts/verify.ps1        # 静态检查 + 全量测试 + 前端构建
powershell -File scripts/run.ps1           # 启动服务（可选 -BuildFrontend / -Reload）
```

脚本都是幂等的：已存在的虚拟环境、依赖、`.env` 都不会被覆盖（主密钥不会被自动改写）。
`launch.bat` / `launch.sh` 只是 `bootstrap` + `run` 的组合（按需构建前端），适合演示与首次上手。

打包（构建阶段仍需要 Python 3.12 + Node 20）：

```powershell
powershell -File scripts/build-exe.ps1      # Windows：dist/TrueSight.exe（可选 img/logo.ico 图标）
```

```bash
bash scripts/build-elf.sh                   # Linux / WSL2：dist/linux/TrueSight（ELF）
```

两边使用独立的虚拟环境：Windows 是 `server/.venv`，Linux 默认 `server/.venv-linux`，
交替构建不会互相破坏。手动方式与依赖版本见 [server/README.md](../server/README.md)。
项目现状、算法、全流程与创新点见 [STATUS](STATUS.md)、[ALGORITHMS](ALGORITHMS.md)、
[FLOWS](FLOWS.md)、[INNOVATIONS](INNOVATIONS.md)。
安全设计与加固见 [SECURITY-ARCHITECTURE](SECURITY-ARCHITECTURE.md)、
[ANTI-BYPASS](ANTI-BYPASS.md)、[HARDENING](HARDENING.md)；
新增能力/任务/接口的落点见 [EXTENSIBILITY](EXTENSIBILITY.md)。

## 二、铁律（改动前请先读）

1. **每个模块先有全部通过的测试**，才允许进入下一个模块；
2. **测试绝不访问真实网络**：注入假实现，或用 `respx` 打桩 `httpx`；
3. **外部失败一律归一化为项目错误类型**（`app/core/errors.py`），上层不认识 `httpx` / `sqlalchemy` 的异常；
4. **降级必须可见**：不允许「静默少做一步」——失败要么进 `skipped`，要么落一条中文说明；
5. **密钥零外泄**：任何日志、异常 `message/detail`、`repr`、API 响应都不得含明文或密文；
6. **公网模式不落原始数据**。

这些不是口号，第 3～5 条有自动化守门：

| 约定 | 守门方式 |
| --- | --- |
| 日志不得误用标准库关键字（`logger.warning("x", host="y")` 会直接抛 `TypeError`） | `tests/test_conventions.py` 用 AST 扫描 `app/` |
| 应用代码禁止 `print` | 同上 |
| 关键模块必须走 `log_event`（保证脱敏） | 同上 |
| 业务错误不被包装成 `StorageError`（否则 API 无法映射 409/404） | `tests/db/test_session.py` |

## 三、测试策略

```
tests/
├── core/        配置 · 日志 · 错误 · 安全组件 · 分级降级
├── utils/       URL 规范化 · 域名 · 熵 · SSRF 判定
├── db/          模型 · 会话 · Alembic 迁移
├── engine/      生成/筛查/评分/抓取/文本/证书/报告/取证/流水线
├── llm/         适配器与注册表装配
├── scheduler/   任务编排与调度接线
├── services/    名单 · 判定 · 举报 · 处置 · 取证 · 后台 · 设置存储
├── api/         公网接口与管理后台接口（TestClient + 注入假评估器）
├── test_web.py        前端静态挂载
└── test_conventions.py 架构约定
```

常用命令：

```powershell
cd server
.\.venv\Scripts\python.exe -m pytest tests/engine -q          # 只跑某一块
.\.venv\Scripts\python.exe -m pytest -k "grading or fallback" # 按名字过滤
.\.venv\Scripts\python.exe -m pytest -m network                # 标记为「真实联网」的用例（默认不跑）
.\.venv\Scripts\python.exe -m ruff check app tests
.\.venv\Scripts\python.exe -m ruff format app tests          # 只格式化改动过的文件，别全仓跑
```

测试中可用的夹具（`tests/conftest.py`）：`settings`（内存库 + 临时目录）、
`database`（已建表）、`session`；API 测试另有 `build_client` 工厂
（可注入脚本化评估器与假 DNS 解析器）。

## 四、怎么加一个新检测能力

以「加一个 DNS 解析能力」为例，完整路径如下（每一步都能单独测试）：

1. **声明能力**：在 `app/core/degradation.py` 的 `Capability` 里加枚举，并在
   `CAPABILITY_TIER`、`PROTECTION_PLAN` 里登记层级与生效等级；
2. **写实现**：新建 `app/engine/analyzers/dns.py`，用协议（`Protocol`）描述依赖，
   把网络失败归一化为 `UpstreamError`/`CapabilityUnavailableError`；
3. **接入流水线**：在 `app/engine/pipeline.py` 的 `assess()` 里按需调用，
   **失败路径必须调 `self._mark(...)`**（这样它才会落进 `skipped_capabilities`）；
4. **参与评分**：在 `app/engine/scoring` 的 `ScoreInput/score` 里加一层与权重 ——
   权重写在模块顶部并注明标定依据；
5. **补测试**：`tests/engine/test_dns.py`（离线：注入假解析器）+ 在
   `tests/engine/test_pipeline.py` 补一条「该能力失败时判定仍完成」的用例；
6. **跑门禁**：`powershell -File scripts/verify.ps1`。

> 关键点：**能力失败不能抛到 `assess()` 之外**。流水线只有「名单不可用」才返回
> `INDETERMINATE`，其余一切失败都降级继续 —— 这条不变式有测试守着。

## 五、怎么加一个管理后台页面

1. 后端：在 `app/services/admin.py` 加查询/动作方法（写操作记得调 `self._audit(...)`）；
2. 路由：在 `app/api/local/` 对应模块加端点（用 `AdminServiceDep` 与 `ClientKeyDep`）；
3. 契约：在 `frontend/packages/shared/src/types.ts` 加视图类型（字段与方法返回一一对应）；
4. 前端：在 `frontend/apps/admin-console/src/views/` 加视图，并在 `App.vue` 的页签里登记；
5. 测试：`tests/services/test_admin.py`（服务层语义）+ `tests/api/test_admin_api.py`
   （状态码、错误信封、审计留痕）；
6. 文档：更新 [API.md](API.md) 的对应小节。

## 六、代码约定

* **全中文** docstring 与注释；文件名、函数名、变量名用英文；
* `from __future__ import annotations` 一律加上；
* 值对象优先用 `frozen dataclass(slots=True)`；跨边界校验用 Pydantic；
* 依赖注入而非全局单例：所有外部依赖（抓取器、证书检查器、备案查询、情报源、
  模型注册表、HTTP 客户端工厂）都从构造函数进，测试与离线环境可整体替换；
* 错误只在**边界**处理：API 层把 `TrueSightError` 转成 JSON 信封，
  业务层把上游异常归一化，引擎层把单点失败降级；
* 日志用 `log_event(logger, level, "中文消息", field=value)`（结构化、可脱敏），
  不要用 `%` 拼字符串。

## 七、提交与评审

* 提交前跑 `scripts/verify.ps1`（与 CI 同款门禁）；
* 提交信息用祈使句、说明**为什么**：`fix: 目标站点失败不再计入熔断（避免三个打不开的站点关掉抓取能力）`；
* 一次提交只做一件事；纯格式化与逻辑改动分开；
* 新增行为必须带测试；修改既有行为必须**同时改测试并在提交信息里说明原因**；
* 评审关注点：降级是否可见、密钥是否外泄、测试是否离线可复现、文档是否同步更新。

详见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

## 八、常见坑（都是踩过的）

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 测试里「未捕获异常」被包装成 `StorageError` | 在 `session_scope` 里抛业务错误 | 已修复：`TrueSightError` 原样抛出（见 `tests/db/test_session.py`） |
| 超时设置形同虚设 | 兜底链吞掉了 `CancelledError` | 任何兜底链先 `except asyncio.CancelledError: raise` |
| 某能力被静默跳过 | 只 `except` 没记 `skipped` | 每个失败分支都要标记降级 |
| 前端页面 404 但接口正常 | 没构建前端产物 | `npm run build`，或忽略（接口不受影响） |
| `/admin` 挂载后接口 404 | 根路径挂载顺序写反 | 先挂 `/admin` 再挂 `/`（`app/web.py` 已注明） |
| `npm install` 报 EPERM | 默认 npm 缓存目录不可写 | `$env:npm_config_cache="<仓库内路径>"`（脚本已处理） |
| Windows 下 `No pyvenv.cfg file` / `No Python at '/usr/bin\python.exe'` | WSL 把共用的 `server/.venv` 改写成了 Linux 布局 | Windows 脚本会检测并自动重建；Linux 侧改用 `server/.venv-linux`，不再删除 Windows venv |
| WSL/Windows 构建报缺少 `@rollup/rollup-*-gnu` 或 `win32-x64-msvc` | 两端共用 `node_modules`，原生包只属于安装平台 | `launch.sh` / `launch.ps1` / `build-elf.sh` / `build-exe.ps1` / `verify.ps1` 会自动检测并重建 |
| 反向代理后限流/人机验证把所有人当成同一人 | 未配置受信代理，直连对端都是代理 IP | 设置 `TRUESIGHT_ABUSE__TRUSTED_PROXIES`（见 [HARDENING](HARDENING.md)） |
| `vite build` 报 `Unexpected token '' ... is not valid JSON` | 某个 `package.json` 被写入了 UTF-8 BOM | JSON 文件必须**不带 BOM**（用编辑器「UTF-8 无 BOM」保存） |
| `.ps1` 脚本报「字符串缺少终止符」/ 中文变乱码 | Windows PowerShell 5.1 读取无 BOM 的 UTF-8 会按 ANSI 解码 | `scripts/*.ps1` 必须**保留 UTF-8 BOM**；改完用 `powershell -File scripts/verify.ps1` 复跑确认 |
| `launch.bat` 里出现中文变乱码 | `.bat` 由 cmd.exe 按控制台代码页解析 | **`.bat` 只写 ASCII**，所有中文提示放在 `scripts/launch.ps1`（UTF-8 BOM）里 |
| 双击 `launch.bat` 窗口一闪而过 | 启动失败后窗口关闭 | 脚本已在失败时 `pause`；仍闪退就在终端里执行以看到输出 |
| 判定结果经常是 `indeterminate` | 时间预算（默认 2500ms）内没跑完「robots + 抓页 + TLS」 | 属设计内降级；网络差时调大 `goto.decision_timeout_ms` |
| 联调判定接口得到 `blocked_ssrf` | 目标域名不可解析或指向内网（fail-closed） | 用可解析的公网域名联调；这不是判定结果而是安全拒绝 |
