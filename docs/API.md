# 接口手册

统一约定：

* 前缀 `/api/v1`；管理后台为 `/api/v1/admin/*`，**只在 `local` 模式存在**；
* 所有错误统一信封：`{"error": {"code": "...", "message": "...", "detail": {...}}}`；
* `detail` 只在 `TRUESIGHT_DEBUG=true` 时返回（避免向攻击者回显内部信息）；
* 时间统一为「无时区的 UTC」，JSON 里以 `...Z` 结尾；
* 接口被管理员关闭时返回 **403 `feature_disabled`**（而不是 404 —— 便于排查接入错误）；
* 所有响应带安全头（CSP、`X-Content-Type-Options`、`X-Frame-Options`、
  `Referrer-Policy`、`Permissions-Policy`；HTTPS 对外地址额外带 HSTS）；
* 公共写接口与管理接口一致：**未声明的字段返回校验错误**，不做静默忽略。

## 错误码速查

| code | HTTP | 含义 | 应对 |
| --- | --- | --- | --- |
| `invalid_input` | 400 / 422 | 参数不合法（含未声明的多余字段；Pydantic 校验失败为 422） | 检查请求体字段名与取值 |
| `missing_parameter` | 400 | 缺少必填参数（例如 `/goto` 缺 `to`） | 补参数；不要静默调用 |
| `feature_disabled` | 403 | 该接口被管理员关闭 | 到管理后台「服务」页开启 |
| `human_verify_required` | 403 | 需人机验证（保护等级 ≥ 阈值） | 先取挑战票据再带 `human` 重试 |
| `rate_limited` | 429 | 触发限流（带 `Retry-After`） | 退避重试 |
| `ssrf_blocked` | 403 | 目标命中 SSRF 规则（内网/元数据/非法端口） | 正常业务不应出现；出现即说明输入可疑 |
| `crawl_denied` | 502 | 目标站点 robots 禁止抓取 | 本次不抓取（属合规行为，不是故障） |
| `not_found` | 404 | 资源不存在（或公网模式访问了管理接口） | 检查 id / 运行模式 |
| `conflict` | 409 | 重复项（同名供应商、重复资产、重复举报） | 改为更新或忽略 |
| `upstream_unavailable` | 502 | 上游（站点 / 模型 / 情报源 / 举报通道）不可用 | 可重试；判定侧已按降级处理 |
| `secret_unavailable` | 500 | 密钥不可用（主密钥变更或密文损坏） | 用原主密钥，或重新录入密钥 |
| `storage_error` | 500 | 存储层故障 | 可重试；检查磁盘与数据库 |
| `auth_failed` | 401 | 未登录或账号密码不正确 | 先登录；错误信息不区分用户是否存在 |
| `account_locked` | 429 | 连续失败导致账号临时锁定 | 等待 `retry_after_seconds` 后再试 |
| `csrf_invalid` | 403 | 写操作缺少/携带错误的 CSRF 令牌 | 用登录返回的 `csrf_token` 设置 `X-CSRF-Token` |
| `forbidden` | 403 | 已登录但角色不足（或非平台租户访问 A 端） | 使用具备相应角色的账号 |
| `tenant_suspended` | 403 | 所属租户被停用 | 联系服务方 |
| `quota_exceeded` | 403 | 套餐配额已用完（如受保护资产达上限） | 升级套餐或联系服务方 |

`invalid_input` / `conflict` 的 `message` 会给出具体中文原因（例如
`账号已被注册`、`邮箱已被绑定`、`手机号已被绑定`、`密码长度不足`），前端可直接展示；
其余错误仍使用保守文案，避免泄露内部路径或主机信息。

---

## 一、公网接口

### 1. 出站跳转中转 `GET /api/v1/goto`

把受保护站点的出站外链改写成这个地址（见 [deployment 的接入示例](DEPLOYMENT.md)）。

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `to` | 是 | 目的地址（必须是 http/https） |
| `from` | 否 | 来源地址（用于日志与票据绑定） |
| `format` | 否 | 传 `json` 返回判定结果而不跳转 |

响应：

* 默认 **302**：放行 → 跳目标；需确认 → 跳 `/gate?ticket=…`；拦截 → 不跳转；
* `?format=json` → 判定 JSON：

```json
{
  "action": "confirm",
  "level": 2,
  "target_host": "example-bank-login.top",
  "source_host": "portal.example-bank.com",
  "reason_code": "suspicious",
  "reason": "域名与品牌域高度形近，且页面存在仿冒登录表单",
  "needs_gate": true,
  "ticket": "eyJ…",
  "risk_level": "medium",
  "confirmations_required": 1,
  "assessment": {
    "domain": "example-bank-login.top",
    "verdict": "suspicious",
    "score": 58,
    "risk_level": "medium",
    "intent": "phishing",
    "reasons": ["域名包含品牌词但换用 .top 顶级域", "页面要求输入密码"],
    "degraded": true,
    "skipped_capabilities": ["rdap_whois", "dns_resolve"]
  }
}
```

```bash
# 判定「自家域名」的外链（先把它登记为受保护资产）
curl -s "http://127.0.0.1:8000/api/v1/goto?to=https%3A%2F%2Fexample.com%2Fnews&format=json"
# {"action":"allow","level":2,"reason_code":"whitelisted","needs_gate":false,…}

# 判定一个内网地址 → 被 SSRF 防护拦下（fail-closed）
curl -s "http://127.0.0.1:8000/api/v1/goto?to=http%3A%2F%2F127.0.0.1%2F&format=json"
# {"error":{"code":"blocked_ssrf","message":"目标地址不被允许访问。"}}
```

> **注意**：`to` 必须能解析到公网地址。域名解析失败时按 fail-closed 拒绝
> （`blocked_ssrf`）——所以不要用不存在的域名做联调，那会看到 SSRF 拦截而不是判定结果。
> 未登记的域名会走真实检测（robots + 抓取 + TLS），受 `goto.decision_timeout_ms` 预算约束。

**风险处理范围**（按风险等级，而不是只看结论字符串）：

| 保护等级 | 触发范围 | 动作 | 确认次数 |
| ---: | --- | --- | ---: |
| 0 | 不处理 | 直接放行 | 0 |
| 1 | **高危 / 极高** | 风险提示，可继续 | 1 |
| 2 | **中等及以上** | 展示明细后确认 | 1 |
| 3 | **中等及以上** | 展示明细后多次确认 | 2 |
| 4 | **中等及以上** | 展示明细后多次确认 | 3 |
| 5 | **中等及以上** | 直接拦截，不可继续 | 0 |

> 「无法判定」（超时 / 能力不可用）仍按从严路径处理：1 级提示、2 级确认、3 级及以上拦截；
> 它与「已知风险等级」是两条不同的策略线。

### 2. 用户确认继续 `POST /api/v1/goto/confirm`

| 字段 | 说明 |
| --- | --- |
| `ticket` | 由 `/goto` 签发的一次性票据（默认 300s 有效） |
| `human_token` | 可选，人机验证挑战票据（保护等级 ≥ 3 时必需） |
| `confirmations` | 已完成的确认次数；3 / 4 级分别要求 2 / 3 次 |

返回 `{action, allowed, target, reason, extra}`。`allowed=true` 时前端跳 `target`。
确认次数不足时返回 **403 `human_verify_required`**，并在 `detail` 中给出 `required / received`。

### 3. 人机验证挑战 `GET /api/v1/goto/challenge`

返回 `{challenge, ttl_seconds}`。**演示实现**：直接签发一枚与人机验证主体绑定的票据；
生产环境应在此接入真实人机验证（滑块 / 短信），后端校验逻辑无需改动。

> 人机验证主体只由 **IP + User-Agent** 派生，不含请求路径 —— 否则「挑战」与「确认」
> 两个路径会得到不同主体，用户永远无法通过验证。

### 4. 风险票据明细 `GET /api/v1/goto/inspect`

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `ticket` | 是 | 由 `/goto` 签发的票据 |

返回签名票据里的展示信息，**不会重新评估**：

```json
{
  "level": 3,
  "action": "confirm",
  "target_host": "example-bank-login.top",
  "verdict": "suspicious",
  "risk_level": "medium",
  "score": 49,
  "reasons": ["与品牌域名完全同名，仅顶级域不同", "页面标题直接使用了品牌名称"],
  "confirmations_required": 2
}
```

前端「拦截提示」页用它展示风险明细与剩余确认次数；票据无效/过期返回 **401 `ticket_invalid`**。

### 5. 人工举报 `GET /api/v1/report`

| 参数 | 必填 | 说明 |
| --- | --- | --- |
| `target` | 是（缺省时 302 到举报页） | 被举报网址 |
| `note` | 否 | 补充说明（≤2000 字） |
| `human` | 否 | 人机验证票据（高等级必需） |
| `format` | 否 | 传 `json` 返回受理结果（**程序调用请务必带上**，否则会 302） |

```bash
curl -s "http://127.0.0.1:8000/api/v1/report?target=example-bank-login.top&format=json"
# {"submission_id":1,"status":"pending_review","target_domain":"example-bank-login.top",
#  "reason":"自动初筛未能确认，已转入人工审核队列。","description":"…","finding_id":null,
#  "duplicate_of":null}
```

受理状态：`received`（新投稿，等待初筛）· `auto_verified`（初筛确认，已落命中记录）·
`pending_review`（转人工）· `accepted` · `rejected`（举报自家资产或白名单站点）·
`duplicate`（同域 30 分钟内重复提交，已合并）。

### 6. 态势看板 `GET /api/v1/dashboard`

| 参数 | 说明 |
| --- | --- |
| `days` | 统计窗口 1–365 天，默认 30 |

返回计数、风险/意图/状态分布、地区分布与按天趋势；数据来自脱敏投影表，
`meta.desensitized = true` 明确告知前端这是脱敏数据。

### 7. 站点外观配置 `GET /api/v1/site-config`

返回前端启动所需的公开展示参数，由仓库根目录 `truesight.config.json` 驱动：

```json
{
  "logo_url": "/api/v1/site-logo",
  "logo_fallback_glyph": "👀",
  "logo_fallback_letter": "T",
  "dashboard_days": 30,
  "public_base_url": "https://protect.example.com"
}
```

* `logo_url`：图片 Logo 地址；空串表示前端使用字形回退；
* `dashboard_days`：仿冒态势默认统计窗口（只支持 7 / 30 / 90）；
* `public_base_url`：`goto` 中转与举报结果页使用的对外地址；
* 配置缺失或损坏时返回内置默认值，不影响页面渲染。

### 8. 站点 Logo `GET /api/v1/site-logo`

返回根配置指定的本地图片（PNG/JPG/JPEG/WEBP/GIF），带 1 小时缓存；
未配置本地图片时返回 **404 `not_found`**，前端据此回退到字形 / 字母。
支持相对路径（锚定配置文件目录，`../` 越界会被忽略）与绝对路径
（包括 Windows 的 `D:\...`；JSON 中反斜杠需写成 `\\`，或直接使用 `/`）。

### 9. 健康检查 `GET /healthz`

返回 `{status, mode, protection_level, version}`。用于探活与编排层重启判断。

### 10. 开放情报接口（API Key）

供政企 / 监管机构拉取已确认或已处理的仿冒目标，**只读**，不暴露租户、举报人、
证据路径或内部自增 id。请求头使用 `X-API-Key`（也兼容 `Authorization: Bearer`）。

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/open/findings/confirmed` | 已确认仿冒；默认不含已处理，`include_processed=true` 可包含 |
| GET | `/api/v1/open/findings/processed` | 已确定处理的记录 |

参数：`limit`（1–200，默认 100）、`cursor`（上一页的 `next_cursor`）、
`since`（ISO-8601，只看该时间之后发现的记录）。

响应示例：

```json
{
  "schema_version": "1.0",
  "feed": "confirmed",
  "generated_at": "2026-11-10T08:00:00Z",
  "pagination": { "limit": 100, "next_cursor": "eyJzZWVuX2F0...", "has_more": true },
  "items": [
    {
      "public_id": "f_3a7c1d9e5b2f4a6c8d0e1f2a",
      "domain": "example-login.top",
      "url": "https://example-login.top/login",
      "brand_asset": "example-bank.com",
      "status": "confirmed",
      "risk_level": "high",
      "score": 88,
      "intent": "phishing",
      "reason_codes": ["human_confirmed"],
      "confirmed_at": "2026-11-10T07:30:00Z",
      "first_seen_at": "2026-11-09T12:00:00Z",
      "last_seen_at": "2026-11-10T07:00:00Z",
      "processed": false,
      "processed_at": null,
      "actions": [],
      "evidence_digest": "sha256:9f2c..."
    }
  ]
}
```

安全约束：

* 每个 Key 只授予 `intel.confirmed` / `intel.processed` 两个作用域之一或全部；
* 每个 Key 独立限流（1–600 次/分钟），超限返回 `429 rate_limited`；
* 每次调用写 `intel.fetch` 审计（客户端名、条数、是否带游标），不记录密钥；
* 响应带 `ETag`，可用 `If-None-Match` 命中 **304** 做增量轮询；
* `public_id` 由命中指纹派生，稳定且不可枚举；换主密钥不会改变。

管理端（仅 `local` 模式）：

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/intel/clients` | 客户端列表（只回前缀，不回密钥） |
| POST | `/api/v1/admin/intel/clients` | 创建；响应中的 `api_key` **只出现一次** |
| DELETE | `/api/v1/admin/intel/clients/{id}?confirm=true` | 停用（软删除，密钥立即失效） |

---

## 二、管理后台接口（仅 `local` 模式）

所有写操作都会落一条审计（`audit_logs`，含动作、目标、操作者与**客户端标识哈希**）。
`actor` 固定为 `local-admin`（单机部署下没有多用户体系，这是刻意的简化）。

### 总览（页面菜单名称为「总览」，接口路径保持 `/home`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/home` | 计数、风险/状态/意图分布、任务健康度、证据占用、`sequence`（页面顺序） |

### 服务

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/services` | 功能开关、能力健康（可用/降级/熔断 + 连续失败数）、调度器状态、LLM/举报/处置装配情况、安全告警。`services.llm` 含 `available / report_ready / missing_purposes / degradation`，缺 AI 时直接说明哪些能力会降级 |
| POST | `/api/v1/admin/services/toggle` | `{key, enabled}`；`key` ∈ `goto_enabled / report_enabled / dashboard_enabled / abuse_channel_enabled / schedule_enabled`（后者会联动启停调度器） |
| POST | `/api/v1/admin/tasks/run` | `{kind, payload?, target_value?}`，同步执行一次任务并返回执行结果 |

### 模型

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/models` | 供应商列表（**密钥只回遮蔽值**）、当前装配结果与路由、`purpose_guide`（分工说明）与 `guidance`（未配置/缺分工时的引导与降级说明） |
| POST | `/api/v1/admin/models` | 新增：`{name, base_url, api_key, purpose_models?, enabled?, priority?, notes?}` |
| PUT | `/api/v1/admin/models/{name}` | 更新；`api_key` 留空表示**不轮换密钥** |
| DELETE | `/api/v1/admin/models/{name}` | 删除供应商配置 |
| POST | `/api/v1/admin/models/reload` | 按数据库记录重新装配并热切换到报告生成链（无可用供应商时保持现状） |

`purpose_models` 的键是分工名：`VISION / SOURCE / TEXT / REPORT / GENERAL`，例如
`{"REPORT": "Qwen/Qwen2.5-7B-Instruct"}`。未知键会被**丢弃**而不是存进去制造脏路由。

`purpose_guide` 说明每个分工**做什么**（例如 REPORT 负责撰写研判报告、GENERAL 是所有
未显式配置分工的兜底）；`guidance` 给出 `configured / available / report_ready /
missing_purposes / features / fallbacks / steps`，让前端可以直接引导用户完成配置。

### 名单

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/assets` | 受保护资产清单 |
| POST | `/api/v1/admin/assets` | 新增资产（自动成为白名单成员，立即生效） |
| PUT | `/api/v1/admin/assets/{id}` | 改域名/品牌名/关键词/启停/备注；改域名会做唯一性校验并同步白名单身份 |
| POST | `/api/v1/admin/assets/{id}/disable` | 停用资产（保留在册，随时可恢复） |
| DELETE | `/api/v1/admin/assets/{id}?confirm=true` | 删除资产。**必须显式 `confirm=true`**，否则返回 400；删除会同时移除白名单身份，审计保留删除前快照 |
| GET | `/api/v1/admin/lists` | 名单条目，可按 `list_type` 过滤（`whitelist/blacklist/dictionary`）；白名单视图额外包含 `source=protected_asset` 的只读合成行（受保护资产自动成为白名单成员） |
| POST | `/api/v1/admin/lists` | 新增条目 |
| PUT | `/api/v1/admin/lists/{id}` | 改值/启停/理由/过期时间（改值会做同类别唯一性校验） |
| DELETE | `/api/v1/admin/lists/{id}` | 删除条目 |
| POST | `/api/v1/admin/lists/batch` | `{list_type, kind?, values[], reason?, expires_at?}` 批量新增；同批与库内重复自动跳过，返回 `added/skipped/invalid/total` |
| POST | `/api/v1/admin/lists/batch-delete?confirm=true` | `{ids[]}` 批量删除（只删名单条目，不影响受保护资产）；必须显式确认 |
| POST | `/api/v1/admin/lists/import` | multipart 上传 `.txt/.csv/.json`（≤1MB、≤5000 条），`list_type`、`kind?`、`reason?`、`dry_run`；先预览再导入 |

### 设置

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/settings` | 可调设置项（含 `scope/scope_label/unit/restart_required`、`secret` 与 `source`：进程默认 / 界面覆盖）。`secret=true` 表示凭证类值：前端用密码框展示、审计只记录「已更新」，但本机管理员仍可在响应中读到当前值以便核对 |
| PUT | `/api/v1/admin/settings` | `{values: {key: value}}`，**先全量校验再落库**，任一项非法则整批拒绝 |
| POST | `/api/v1/admin/settings/reset?confirm=true` | 恢复全部可调设置到部署基线（启动时的 `.env` / 代码默认值）。必须显式 `confirm=true`；只清除参数覆盖，**不删除**资产、名单、模型供应商与日志；写 `settings.reset` 审计 |

可改的键是白名单（共 34 项，按 `scope` 分组）：

* `basic`：`protection_level`、`goto.decision_timeout_ms`、`goto.max_redirect_hops`、
  `goto.ticket_ttl_seconds`、`goto.human_verify_from_level`；
* `service`：四个功能开关与 `schedule.enabled`；
* `crawler`：`crawler.respect_robots`、`crawler.max_body_bytes`、`crawler.timeout_seconds`；
* `schedule`：五个任务间隔（**单位秒，10–604800**）、`schedule.task_timeout_seconds` 与三个单轮上限
  （`max_probe_per_scan / max_findings_per_run / max_assessments_per_run`）。
  旧版 `schedule.*_minutes` 覆盖值会在启动时自动 ×60 迁移为 `schedule.*_seconds`，
  旧环境变量不再读取并会给出兼容性告警；
* `abuse`：`rate_per_minute`、`burst`、`suspicious_delay_ms_min/max`；
* `report`：`report.human_verify_ttl_seconds`（举报人机验证票据有效期，30–3600 秒）。
  与 `goto.ticket_ttl_seconds` 相互独立；每次签发时读取当前值，保存后立即生效。
  另含 `report.standing_ticket_enabled` 与 `report.standing_ticket`（常驻验证票据，
  默认关闭；启用后可用固定票据跳过举报人机验证，仅建议受控渠道使用）。
  `report.standing_ticket` 长度 8–128 字符、不允许控制字符，传空串表示清除；
  响应中 `secret=true`，前端用密码框展示并可就地生成随机票据。
* `ai`：`ai.detection_enabled`（是否启用可疑灰区 AI 复核）、
  `ai.judgement_timeout_seconds`（1–60 秒）、`ai.max_text_chars`（500–8000 字符）。
  关闭后检测立即回到纯规则路径，不产生任何模型调用。
* `ui`：`ui.findings_page_size`、`ui.log_page_size`（列表每页条数，5–200，默认 10）。
  日志页在加载时读取；保存后回到日志页点「刷新」即按新条数分页。

保存 `schedule.*` 后：`schedule.enabled` 负责启停调度器，其余键在调度器运行时**立即按新间隔重建任务**。
`crawler.timeout_seconds / abuse.rate_per_minute / abuse.burst` 由客户端在构造时固定，
视图里会标记 `restart_required=true`，界面显示「重启后生效」。
数据库地址、主密钥、SSRF 策略等部署期参数**界面改不了**（这是有意的边界）。

### 日志 / 命中 / 处置

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/logs/{kind}` | `kind` ∈ `tasks / audit / abuse / submissions`；支持 `limit/offset` 分页与 `status/action/channel/keyword/days` 过滤；举报投稿额外支持 `open_only=true`（只看 `received / auto_verified / pending_review`）并返回 `note` 补充说明；`total` 为过滤后总数 |
| GET | `/api/v1/admin/logs/{kind}/export` | 导出日志：`format=csv｜json`（默认 csv）、`limit` ≤ 10000（默认 1000），并支持与查询相同的 `status/action/channel/keyword/days` 过滤。响应为附件下载 |
| GET | `/api/v1/admin/findings` | 命中列表：`limit/offset/status/risk_level/source/accessible/keyword/days/sort_by/sort_order/ids/exclude_status`；`accessible` ∈ `true｜false`（`null` 表示未尝试抓取），`sort_by` ∈ `last_seen_at / first_seen_at / score / risk_level / domain`，`sort_order` ∈ `asc｜desc`（风险等级升序 = 低→高，降序 = 高→低）；`ids` 为逗号分隔的命中 id（展示单次任务成果）；`exclude_status=confirmed` 把已确认仿冒从主列表移出（「确认仿冒」视图改用 `status=confirmed`）；**不含报告正文**，`total` 为过滤后总数 |
| GET | `/api/v1/admin/findings/export` | 导出命中记录：`format=csv｜json`、`limit` ≤ 10000，支持相同的筛选、排序与 `exclude_status` 参数 |
| DELETE | `/api/v1/admin/findings?confirm=true` | 清空**待处理**命中记录（`new/pending_review/dismissed`）、其证据索引与证据文件；`confirmed/reported/resolved` 一律保留（不可恢复，必须显式确认；投稿与举报留痕保留但解除关联）。响应含 `deleted` 与 `kept_confirmed`（只统计确认仿冒；`reported/resolved` 同样保留但不计入该字段），便于界面说明「保留了多少条已确认」 |
| POST | `/api/v1/admin/findings/exclude-confirmed?confirm=true` | 批量把「确认仿冒」且**尚未确定处理**的记录退回命中列表（状态改为 `dismissed` 并重算脱敏投影），响应 `moved`。必须显式确认；写一条 `finding.review` 审计（`target=confirmed:all`）。已处理的记录不会被批量撤回 |
| POST | `/api/v1/admin/findings/{id}/process?confirm=true` | 对已确认仿冒执行「确定处理」：生成研判报告 + 一条演练举报留痕（`dry_run`），并记录 `processed_at / processed_by / processing_state / processing_trace`。必须显式确认；重复调用幂等（`already_processed=true`）；未确认的命中返回 400 |
| GET | `/api/v1/admin/findings/{id}` | 详情：`report_markdown`、评分因子、证据索引行 |
| POST | `/api/v1/admin/findings/{id}/review` | `{decision: "confirmed"｜"dismissed", generate_abuse_trace?}` 人工审核。确认时默认同步生成一条举报留痕（演练通道，不对外发送）；响应额外包含 `disposition` 的 `degraded / skipped / notes` |
| POST | `/api/v1/admin/findings/{id}/dispose` | `{collect_evidence?, create_report?, submit_abuse?, confirm_abuse?}` 重新处置（`confirm_abuse` 默认 `false`）；界面上的「处置」只做取证与报告 |
| POST | `/api/v1/admin/submissions/{id}/review` | `{decision: "accepted"｜"rejected"}` 审核举报投稿。采纳时一定产生一条「确认仿冒」：已关联命中则确认该命中；没有关联命中则按举报域名补建一条（`source=report`，不伪造证据），并生成演练留痕。排除只更新投稿状态 |
| GET | `/api/v1/admin/abuse` | 举报留痕（默认是演练记录） |
| POST | `/api/v1/admin/abuse/{id}/confirm` | 人工确认后改用真实通道补发 |

**日志 / 命中导出的安全约束**：

* 只导出白名单列：任务 `payload`、举报 `request_body`、审计 `detail`、投稿 `auto_verdict`
  等可能含原始输入的字段**永不出现**；
* CSV 对以 `= + - @ TAB CR` 开头的单元格加 `'` 前缀，防止 Excel 公式注入；带 UTF-8 BOM；
* 单次最多 10000 行，响应带 `Content-Disposition: attachment`、`X-Content-Type-Options: nosniff`
  与 `Cache-Control: no-store`；
* 每次导出都会写一条 `log.export` 审计（类别、格式、行数、操作者、客户端指纹哈希）。

### 存储

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/storage` | 数据目录总量与分项占用（`db / evidence / logs / runtime`）、磁盘总量/已用/可用、主要表行数、可清理目录清单 |
| POST | `/api/v1/admin/storage/open` | `{target}`，`target` ∈ `data / db / evidence / logs / runtime`；用系统文件管理器打开。无图形界面时返回 `opened=false` 与中文说明（不抛 500） |
| POST | `/api/v1/admin/storage/clean` | `{target}`，**只允许** `logs / runtime`；返回 `deleted / bytes_freed / failed / errors`。数据库与证据目录不提供一键清理 |

打开与清理都写审计（`storage.open` / `storage.clean`）；被进程占用而无法删除的文件
会计入 `failed` 并回显文件名，不会静默忽略。

### 检查（原「更新」）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/updates` | 版本、发布阶段（当前 `stable`，界面显示「正式版」）、运行模式、数据库与证据存储占用、自检结论、升级说明。界面菜单名称为「检查」，接口路径为兼容保持不变 |

---

## 三、账号、订阅与 A 端平台（二期）

### 账号与登录（`/api/v1/auth`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/auth/status` | `auth_enabled / require_login / edition / setup_allowed / setup_required / registration_enabled / registration_requires_invite / verification_mode / authenticated / user` |
| POST | `/api/v1/auth/setup` | 受控初始化：`{username, password, tenant_name?}`；只允许默认租户无账号时执行一次；管理后台不再展示入口，企业构建默认禁用 |
| POST | `/api/v1/auth/register` | 自助注册：`{username, password, email, email_code, phone, phone_code, slug?, name?, invite_code?}`；邮箱/手机号必填，在 B 端账号空间内唯一（与 A 端独立），验证码必填；组织名称留空为「无组织」，组织标识留空由用户名派生 |
| POST | `/api/v1/auth/verification` | 发送邮箱/手机验证码（注册、找回密码、修改联系方式共用）：`{channel: "email"\|"phone", target}`；返回 `mode / target_masked / expires_in / delivered`；60 秒内重复请求返回 429 |
| POST | `/api/v1/auth/recover` | 忘记密码：`{username, channel, target, code, new_password, tenant?}`；`stub` 模式任意验证码通过，`strict` 校验哈希/有效期/次数 |
| PATCH | `/api/v1/auth/profile` | 修改昵称/头像/组织名称，或修改邮箱/手机号（改联系方式时必须带 `email_code` / `phone_code`）；需登录 + CSRF；组织名称仅所有者可改 |
| POST | `/api/v1/auth/login` | `{username, password, tenant?}`；`username` 可填用户名、邮箱或手机号；同名账号需带 `tenant`；成功后写 HttpOnly Cookie，返回 `user.csrf_token` |
| POST | `/api/v1/auth/logout` | 撤销当前会话并清 Cookie（幂等） |
| GET | `/api/v1/auth/me` | 当前主体（含租户、角色、CSRF 令牌） |
| POST | `/api/v1/auth/password` | `{current_password, new_password}`；需登录 + CSRF；成功后其他设备下线 |
| POST | `/api/v1/auth/account/delete` | `{password}`；需登录 + CSRF；校验密码后注销当前账号并撤销其全部会话、清除 Cookie；组织最后一名所有者需先转让所有权 |

`verification_mode` 返回**实际生效值**：测试模式关闭时，即使部署配置是 `stub`，
这里也会返回 `strict`，验证码按真实哈希校验。测试模式关闭时 `/auth/register`
不再赠送 365 天 SVIP 测试权益，新租户停在免费版。

### 成员管理（`/api/v1/admin/users`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/users` | 当前租户成员列表（不含任何密码材料） |
| POST | `/api/v1/admin/users` | 新增成员；只有所有者能创建管理员/所有者 |
| PATCH | `/api/v1/admin/users/{id}` | 修改角色/状态/资料或重置密码（重置后强制改密并踢下线） |

### 订阅与配额（`/api/v1/admin/subscription`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/subscription` | 当前权益、资产用量、套餐列表（含 `features.price_monthly` 月价与 `features.privileges` 特权清单）、可选时长、订阅历史 |
| GET | `/api/v1/admin/subscription/quote` | `?plan_code=svip&duration_hours=720`；返回原价、升级抵扣与应付金额（不执行开通） |
| POST | `/api/v1/admin/subscription` | `{plan_code, duration_hours}`；同名套餐续费在原记录上延长到期时间，切换套餐立即替换 |
| POST | `/api/v1/admin/subscription/cancel` | 取消当前未到期订阅 |

`quote` 字段：`months`（计费月数）、`list_price`（原价）、`credit`（旧套餐抵扣）、
`payable`（应付）、`upgrade`（是否升级）、`current_plan_*` / `new_monthly_price`
（对比信息）、`remaining_months` / `credit_months`（剩余与抵扣月数）。
仅升级时抵扣，规则见 [PLATFORM.md](PLATFORM.md#四订阅权益版本与配额)。

`GET /api/v1/admin/subscription` 额外返回 `test_mode: {enabled, default_enabled, source}`。
测试模式关闭（正式服务）时，`POST /api/v1/admin/subscription` 与
`/api/v1/admin/subscription/cancel` 返回 403 `feature_disabled`，提示联系平台运营；
A 端 `/root/.../tenants/{id}/subscription` 不受影响。

新增受保护资产时若超出套餐配额，返回 `quota_exceeded`（403），`detail` 含
`plan_code / limit / used`。

### 公告（`/api/v1/admin/announcements`）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/api/v1/admin/announcements` | 当前已发布且已生效的公告（全体 + 本租户） |

### A 端平台（`/root/api/v1/platform`，仅 internal 构建）

| 方法 | 路径 | 说明 |
| --- | --- | --- |
| GET | `/root/api/v1/platform/auth/status` | A 端是否可用、是否已登录、`registration_enabled / registration_requires_token / verification_mode` |
| POST | `/root/api/v1/platform/auth/login` | `{username, password}`；`username` 可填用户名/邮箱/手机号；只接受平台租户成员；Cookie `Path=/root` |
| POST | `/root/api/v1/platform/auth/register` | `{username, password, email, email_code, phone, phone_code, token?}`；默认开放，新账号创建为 `OWNER` 并拥有完整平台权限；联系方式在 A 端账号空间内唯一（与 B 端独立）；配置令牌后必须携带 |
| POST | `/root/api/v1/platform/auth/verification` | 发送平台账号邮箱/手机验证码（注册、找回、改联系方式共用）：`{channel, target}` |
| POST | `/root/api/v1/platform/auth/recover` | `{username, channel, target, code, new_password}`；平台账号找回密码 |
| PATCH | `/root/api/v1/platform/auth/profile` | 修改平台昵称/头像/组织名称，或修改邮箱/手机号（改联系方式时必须带验证码）；需平台 CSRF |
| POST | `/root/api/v1/platform/auth/password` | 修改平台账号密码；需平台 CSRF |
| POST | `/root/api/v1/platform/auth/logout` | 退出平台控制台 |
| POST | `/root/api/v1/platform/auth/account/delete` | `{password}`；注销当前平台账号并撤销会话；平台租户最后一名所有者需先转让所有权 |
| GET | `/root/api/v1/platform/auth/me` | 当前平台管理员 |
| GET | `/root/api/v1/platform/overview` | 租户/成员/订阅/公告聚合数字与套餐分布 |
| GET | `/root/api/v1/platform/tenants` | 租户列表（含权益与成员数） |
| GET | `/root/api/v1/platform/tenants/{id}` | 租户详情（成员/订阅/覆盖/当前权益） |
| POST | `/root/api/v1/platform/tenants` | 手工开通：`{slug, name, owner_username, owner_password}` |
| PATCH | `/root/api/v1/platform/tenants/{id}` | 修改名称/状态/会话上限/默认套餐 |
| POST | `/root/api/v1/platform/tenants/{id}/subscription` | `{plan_code, duration_hours}` |
| POST | `/root/api/v1/platform/tenants/{id}/subscription/cancel` | 取消订阅 |
| GET | `/root/api/v1/platform/settings/test-mode` | 当前服务形态、默认值、来源与实际验证码模式 |
| PATCH | `/root/api/v1/platform/settings/test-mode` | `{enabled?, default_enabled?}`；至少提供一个，正式服务为 `enabled=false` |
| POST | `/root/api/v1/platform/tenants/{id}/overrides` | `{key:"quota.assets", value, effective_from?, expires_at?}` |
| PATCH | `/root/api/v1/platform/tenants/{id}/users/{uid}` | 修改企业成员（角色/状态/资料/重置密码/会话上限） |
| GET | `/root/api/v1/platform/plans` | 套餐列表（含内部套餐与当前生效权益） |
| PATCH | `/root/api/v1/platform/plans/{code}` | `{quota_assets, effective_from?, features?, note?}`；追加权益版本；`features.price_monthly` 为非负整数（元/月），`features.privileges` 为字符串数组 |
| GET | `/root/api/v1/platform/announcements` | 全部公告（含草稿与未来生效） |
| POST | `/root/api/v1/platform/announcements` | 发布：`{title, body, kind, audience, tenant_id?, effective_from?, expires_at?, published}` |
| PATCH | `/root/api/v1/platform/announcements/{id}` | 修改公告 |
| DELETE | `/root/api/v1/platform/announcements/{id}` | 删除公告 |

A 端写操作要求平台登录 + 平台 CSRF；平台租户内所有账号均拥有完整权限
（启动时历史 `ANALYST` 会幂等提升为 `OWNER`）。时间参数接受带时区的 ISO 8601，
服务端统一转为 UTC 存储。

详见 [PLATFORM.md](PLATFORM.md)。

---

## 四、前端与静态页面

| 路径 | 内容 |
| --- | --- |
| `/` | 公网侧前端（仿冒态势 / 提交举报 / 拦截提示） |
| `/gate` | 拦截中间页（后端 302 会带 `?ticket=…` 到这里） |
| `/report` | 举报页（`/api/v1/report` 不带参数时会 302 到这里） |
| `/admin/` | 本地管理后台前端（仅 `local` 模式） |
| `/root/` | 平台控制台前端（仅 `internal` 构建；business 产物不存在） |
| `/docs` | OpenAPI 文档（仅 `TRUESIGHT_DEBUG=true`） |

未构建前端时这些路径返回 404，**不影响任何接口**。
