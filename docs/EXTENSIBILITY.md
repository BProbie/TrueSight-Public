# 扩展指南：为二期加能力而不破坏现有边界

> 这篇文档回答「下一期要加一个检测能力 / 数据源 / 任务 / 接口 / 设置，应该改哪里、
> 为什么这样改、怎么验证」。目标是让扩展**可预测**：新代码落在正确的层，
> 不把引擎耦合到 Web，也不把降级变成静默跳过。

## 一、先认清六个扩展点

| 扩展点 | 现有协议 / 入口 | 典型二期需求 |
| --- | --- | --- |
| 检测能力 | `Capability` + `PROTECTION_PLAN` + `SiteAssessor` | 新增 WHOIS、DNS、视觉比对、沙箱 |
| 外部数据源 | `ThreatIntelProvider` / `IcpProvider` / `DomainFeed` | 接真实情报、备案、注册局 feed |
| 大模型 | `LlmProvider` + 供应商注册表 | 接新厂商、私有化模型、多模态 |
| 后台任务 | `TaskKind` + `TaskRunner` + `JOB_INTERVALS` | 定期复检、批量取证、情报刷新 |
| 接口 | `app/api/public` / `app/api/local` + Pydantic schema | 新查询、回调、Webhook |
| 可调设置 | `Settings` + `MUTABLE_SETTINGS` | 新增阈值、开关、成本上限 |

所有扩展都应遵守同一套铁律：

1. **新能力必须结算**：计划内能力最终落在 `executed` ∪ `skipped`；
2. **失败必须可见**：中文说明 + `skipped`，不允许静默少做一步；
3. **外部依赖通过协议注入**：引擎层不认识 FastAPI / SQLAlchemy；
4. **测试离线可复现**：网络、时间、随机全部可注入；
5. **接口变化同步文档**：`API.md` + `CHANGELOG.md`。

## 二、加一个检测能力（以「DNS 解析」为例）

### 2.1 注册能力

[degradation.py](../server/app/core/degradation.py)：

```python
class Capability(enum.StrEnum):
    ...
    DNS_RESOLVE = "dns_resolve"
```

同时补 `CAPABILITY_LABELS`（中文名）与 `PROTECTION_PLAN`（哪些保护等级执行它）。
**为什么**：能力不是「代码里写个 if」就行，必须进入统一计划，才能被服务页展示、
被熔断管理、被 `_settle_plan` 结算。

### 2.2 在流水线里实现

[pipeline.py](../server/app/engine/pipeline.py) 的能力分支里返回
`AttemptOutcome`：

```python
async def _dns(self, url: UrlInfo) -> AttemptOutcome[DnsInfo]:
    try:
        records = await asyncio.to_thread(resolve_host, url.host)
    except TrueSightError as exc:
        return AttemptOutcome(ok=False, note=f"DNS 解析失败：{exc.public_message}")
    return AttemptOutcome(ok=True, value=DnsInfo(records=records))
```

**关键**：失败返回 `ok=False` + 中文说明，而不是抛到顶层；只有
`CancelledError` 必须向上抛，避免吞掉超时。

### 2.3 评分与结论

如果新能力参与评分，在 [scoring](../server/app/engine/scoring/) 里增加因子，
并遵守：

- 权重写清标定依据；
- 「分数 = 各因子权重之和」不变式不能被破坏；
- 只升不降 / 策略下限等既有规则不能被新因子绕过。

### 2.4 测试

至少覆盖：

1. 正常路径（注入假解析器）；
2. 解析失败 → `skipped` + 中文说明；
3. 超时/取消传播；
4. 计划结算：能力必然落在 `executed` ∪ `skipped`。

参考 [test_pipeline.py](../server/tests/engine/test_pipeline.py)。

## 三、接一个外部数据源

所有数据源都是**结构化协议**，不需要继承基类。以威胁情报为例
（[pipeline.py](../server/app/engine/pipeline.py)）：

```python
@runtime_checkable
class ThreatIntelProvider(Protocol):
    name: str

    async def check(self, host: str) -> bool: ...
```

实现时只需：

```python
class MyIntelProvider:
    name = "my-intel"

    async def check(self, host: str) -> bool:
        response = await self._client.get(f"https://intel.example/api/check?host={host}")
        response.raise_for_status()
        return bool(response.json().get("malicious"))
```

然后在 `build_context` 装配处注入。**注意**：

- 网络异常必须归一化为 `UpstreamError`，不要向上抛 httpx 异常；
- 「查不到」返回 `False`，「查不了」抛异常 —— 两者语义不同；
- 未配置时保持 `None`，流水线会明确记为 `skipped`。

其他协议位置：

| 协议 | 文件 | 方法 |
| --- | --- | --- |
| `IcpProvider` | [ssl_icp.py](../server/app/engine/analyzers/ssl_icp.py) | `lookup(domain)` |
| `DomainFeed` | [watcher.py](../server/app/engine/dga/watcher.py) | `fetch(since)` |
| `TlsInspector` | [ssl_icp.py](../server/app/engine/analyzers/ssl_icp.py) | `inspect(host, port)` |
| `AbuseChannel` | [abuse.py](../server/app/services/abuse.py) | 提交举报 |
| `ReportGenerator` | [reporting](../server/app/engine/reporting/__init__.py) | `generate(...)` |

## 四、接一个大模型供应商

[base.py](../server/app/llm/providers/base.py)：

```python
@runtime_checkable
class LlmProvider(Protocol):
    name: str

    async def chat(
        self,
        messages: Sequence[LlmMessage],
        *,
        model: str,
        temperature: float = 0.2,
        max_tokens: int | None = None,
    ) -> LlmResponse: ...
```

步骤：

1. 在 `app/llm/providers/` 新增实现；
2. 在注册表/装配处注册（`app/llm/registry.py`、`assembly.py`）；
3. 管理后台「模型」页填写名称、Base URL、模型与密钥；
4. 密钥必须走 `SecretBox` 加密，接口只回遮蔽值；
5. 测试用假客户端，不访问真实网络。

**分工回落**：`TEXT → GENERAL → REPORT`，只配一个模型也能工作；
「未配置/未接入」不计入熔断（见 `assembly.py` 的 `SkippedProvider`）。

## 五、加一个后台任务

### 5.1 枚举与排期

[enums.py](../server/app/db/enums.py) 增加 `TaskKind`；
[service.py](../server/app/scheduler/service.py) 的 `JOB_INTERVALS` 增加间隔字段。

**为什么**：显式列出间隔，避免「新增任务忘记排期」的静默缺陷。

### 5.2 执行器

[runner.py](../server/app/scheduler/runner.py) 的 `handlers` 字典增加分支：

```python
handlers: dict[TaskKind, Callable[[], Awaitable[TaskReport]]] = {
    TaskKind.TYPOSQUAT_SCAN: lambda: self._typosquat_scan(payload),
    ...
    TaskKind.MY_TASK: lambda: self._my_task(payload),
}
```

任务实现返回 `TaskReport`，其中：

- `executed`：实际跑过的步骤；
- `skipped`：跳过的步骤 + 原因；
- `notes`：中文说明；
- `degraded`：有任何跳过即为真。

### 5.3 设置与界面

- 在 `ScheduleSettings` 增加间隔与单轮上限；
- 在 `MUTABLE_SETTINGS` 注册，前端「设置」页才会出现；
- 前端服务页的任务类型下拉需要同步（`frontend/packages/shared` 的中文映射）。

### 5.4 测试

参考 [test_runner.py](../server/tests/scheduler/test_runner.py)：

- 正常执行；
- 上限截断；
- 数据源缺失 → `skipped`；
- 任务异常 → 状态失败但进程不崩。

## 六、加一个接口

### 6.1 选 public 还是 local

| 问题 | 答案 |
| --- | --- |
| 需要管理权限 / 改配置 / 看原始数据？ | `app/api/local/` |
| 公网用户可调用、只读脱敏？ | `app/api/public/` |

`public` 模式的 local 路由**不会挂载**，这是物理隔离，不是开关。

### 6.2 定义 schema

请求模型放在 `app/schemas/`，管理接口统一继承
`app.schemas.admin._Request`（`extra="forbid"`）；公共写接口也应显式禁止多余字段。

### 6.3 路由与错误

- 业务错误抛 `app.core.errors` 里的类型，由统一异常处理器转成错误信封；
- 不要在路由里捕获第三方异常；
- 限流/人机验证复用 `ClientKeyDep` / `ClientSubjectDep`；
- 新接口需要写 [API.md](API.md) 与 [CHANGELOG](../CHANGELOG.md)。

### 6.4 测试

- 成功路径；
- 参数非法 → 400/422；
- 功能关闭 → 403 `feature_disabled`；
- 公网模式 → 404；
- 限流/人机验证路径。

## 七、加一个可调设置

[settings_store.py](../server/app/services/settings_store.py) 的
`MUTABLE_SETTINGS` 是**唯一可信来源**：

```python
MUTABLE_SETTINGS = (
    ...
    SettingSpec(
        key="goto.decision_timeout_ms",
        path=("goto", "decision_timeout_ms"),
        label="判定时间预算",
        kind="int",
        scope="basic",
        minimum=500,
        maximum=10_000,
        unit="毫秒",
    ),
)
```

要点：

- `path` 必须与 `Settings` 字段一致；
- 类型、范围、单位、是否重启生效都要写清；
- 凭证类设置 `secret=True`，日志与审计自动遮蔽；
- 构造期参数（如 HTTP 客户端超时）标 `restart_required=True`，不假装热生效。

## 八、数据库演进

`Database.create_all()` 会：

1. 建缺失的表；
2. 给已存在的表**幂等补齐新增的可空列**与索引；
3. 非空列不自动补，输出警告。

因此二期加字段的规则：

- 新字段优先**可空**或带默认值；
- 需要非空时写 Alembic 迁移，并在 `CHANGELOG` 说明；
- 不要在 ORM 里做破坏性重命名，先加新列、迁数据、再删旧列。

## 九、脚本与构建链

脚本不是「一次性胶水」，而是项目的可复现入口。新增/修改脚本时按下表找落点：

| 脚本 | 职责 | 扩展时注意 |
| --- | --- | --- |
| `scripts/bootstrap.ps1` | 幂等建 venv、装依赖、生成 `.env` | 不要覆盖已有 `.env` 与主密钥 |
| `scripts/venv.ps1` | 判断 venv 是否属于当前平台 | 新增判断必须同时覆盖 Windows/WSL |
| `scripts/frontend-deps.ps1/.sh` | 检测并重建平台原生包 | 改完在两端各跑一次构建 |
| `scripts/launch.ps1` / `launch.sh` | 启动编排（环境→前端→服务） | 失败要可见，不要静默跳过 |
| `scripts/run.ps1` | 直接启动后端 | 保持与 launch 的参数语义一致 |
| `scripts/verify.ps1` | 质量门禁 | 新门禁步骤失败必须 `exit` 非零 |
| `scripts/build-exe.ps1` / `build-elf.sh` | 打包独立可执行文件 | 不能跨平台交叉编译；产物在 `dist/` |

### 给门禁加一步

```powershell
Step "额外的静态检查"
& $python -m my_checker app tests
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
```

**为什么必须 `exit`**：CI 只看进程退出码；脚本打印了错误但退出 0，等于门禁失效。

### 脚本的硬约束

- `*.ps1` 必须保留 UTF-8 BOM（Windows PowerShell 5.1 否则按 ANSI 解码）；
- `*.sh` 使用 LF，改完用 `bash -n` 检查语法；
- 调用 `npm install` 前先调用 `ensure_frontend_deps` / `Test-FrontendDepsForWindows`；
- 构建脚本不要静默吞掉失败：前端构建失败要明确说明「页面不可用，接口不受影响」；
- 不要修改 `package-lock.json` 的跨平台元数据（npm 版本差异会删 `libc` 字段）。

### 验证脚本改动

```powershell
powershell -File scripts/verify.ps1
wsl bash -n scripts/build-elf.sh
wsl bash -n launch.sh
```

## 十、前端扩展

| 想加 | 位置 |
| --- | --- |
| 公网页面 | `frontend/apps/web-client/src/views/` + `App.vue` 菜单 |
| 管理页面 | `frontend/apps/admin-console/src/views/` + `App.vue` 菜单 |
| API 类型 | `frontend/packages/shared/src/types.ts` |
| 中文标签 | `frontend/packages/shared/src/format.ts`（如 `riskLabel`） |

约束：

- 不使用 `v-html` 渲染后端/模型文本；
- 所有可配置输入写入 `localStorage`（用户偏好）；
- 页面切换用 `KeepAlive`，但数据页重新进入要刷新；
- 管理接口只在 local 存在，前端不要假设公网可用。

## 十一、二期能力路线与落点

| 二期方向 | 现有落点 | 主要工作 |
| --- | --- | --- |
| 真实情报/备案/新域源 | `ThreatIntelProvider` / `IcpProvider` / `DomainFeed` | 实现适配器 + 装配 + 降级测试 |
| 视觉相似度 | `Capability.VISUAL_SIMILARITY` | 实现截图与感知哈希；当前明确未接入 |
| 真实人机验证 | `HumanVerifier` | 替换 challenge 签发/校验，保留主体绑定 |
| 多实例 | `TokenBucketRateLimiter` / `TicketSigner` | Redis 限流与 nonce 消费 |
| RBAC | `app/api/local` | 登录、角色、审计告警 |
| PostgreSQL | `Database` / `Settings.database_url` | 迁移脚本、连接池、备份策略 |
| 对象存储证据 | `EvidenceStore` | 抽象存储协议，保留 SHA-256 清单 |

**判断标准**：新增能力是否仍然满足「计划结算、降级可见、离线测试、文档同步」。
只要这四条不变，架构就不会因为二期功能变多而失控。
