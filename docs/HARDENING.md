# 部署与运维加固清单

> 这篇文档面向**要把它放到真实网络里**的人。每条都给出「为什么、怎么做、怎么验证」。
> 代码层面的攻击面见 [SECURITY-ARCHITECTURE](SECURITY-ARCHITECTURE.md) 与
> [ANTI-BYPASS](ANTI-BYPASS.md)；这里只讲部署、配置与运维。

## 一、先决定信任边界

| 形态 | 适用 | 必须做的事 |
| --- | --- | --- |
| 单机演示 | 本机/答辩 | 保持默认 `127.0.0.1`，不要改 `--host 0.0.0.0` |
| 反向代理 | 对外提供服务 | TLS、Host 白名单、受信代理、管理面 ACL |
| 双容器 | 公网/本地分离 | 公网端只跑 `public`，本地端只发布到内网 |

**默认值就是安全值**：服务只监听 `127.0.0.1`，调度器默认关闭，举报通道默认
`dry_run`，公网模式不挂载管理路由。不要为了「方便演示」把这些默认值改掉。

## 二、主密钥

### 为什么

主密钥用于：

- 票据 HMAC 签名（`goto` 确认、人机验证）；
- 模型 API Key 的 Fernet 加密（`SecretBox`）。

泄露主密钥 = 票据可伪造、已存密钥可解密。

### 怎么做

```bash
python -c "import secrets; print(secrets.token_urlsafe(48))"
```

写入 `.env`（不要提交）：

```dotenv
TRUESIGHT_SECRET_KEY=<生成值>
```

- 文件权限：Linux `chmod 600 server/.env`，属主为运行用户；
- 容器：从 `deploy/.env` 注入，不写进镜像；
- 轮换：主密钥变更后，旧票据立即失效，已加密的模型密钥**无法解密**，
  需要重新录入（这是刻意的安全取舍）。

### 怎么验证

```bash
curl -s http://127.0.0.1:8000/api/v1/admin/updates
# 安全告警里不应再出现「主密钥仍为占位值」
```

## 三、模式隔离与网络暴露

### 3.1 公网端只跑 public

```bash
TRUESIGHT_MODE=public ./TrueSight --host 127.0.0.1 --port 8000
```

`public` 模式下 `/api/v1/admin/*` **路由不存在**（404），不是仅返回 403。
验证：

```bash
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:8000/api/v1/admin/assets
# 期望 404
```

### 3.2 管理后台只允许内网

nginx 示例已给出网段 ACL（[truesight.conf](../deploy/nginx/truesight.conf)）：

```nginx
location /admin/ {
    allow 127.0.0.1;
    allow 10.0.0.0/8;
    allow 172.16.0.0/12;
    allow 192.168.0.0/16;
    deny all;
    proxy_pass http://truesight-local:8000/admin/;
}
```

### 3.3 绑定地址

| 场景 | 参数 |
| --- | --- |
| 本机 | `--host 127.0.0.1`（默认） |
| 容器内 | `TRUESIGHT_HOST=127.0.0.1`，由 gateway 访问 |
| 直接对外（不推荐） | 至少加防火墙 + TLS + 认证代理 |

## 四、反向代理与受信代理

### 为什么必须配置

反代后，后端看到的直连对端是 nginx 的地址。若不配置受信代理：

- 所有用户共享一个限流桶；
- 所有人机验证主体相同，票据可能被同 UA 用户复用；
- 审计里的客户端标识失去区分度。

### 配置

```dotenv
# 只信任真正由你控制的代理地址/网段
TRUESIGHT_ABUSE__TRUSTED_PROXIES=127.0.0.1,::1,172.16.0.0/12
```

nginx 需要同时传：

```nginx
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
```

**禁止**配置 `0.0.0.0/0`：那等于重新信任客户端伪造的 `X-Forwarded-For`。

### 验证

```bash
# 直连伪造 XFF 不应改变身份（未配置受信代理时）
curl -s -H 'X-Forwarded-For: 1.2.3.4' http://127.0.0.1:8000/healthz
# 具体身份只能从审计/限流行为间接观察；单测见 tests/utils/test_net.py
```

## 五、TLS 与安全响应头

- 对外必须 HTTPS；`TRUESIGHT_PUBLIC_BASE_URL=https://...` 后服务会自动发送 HSTS；
- 应用已统一发送 CSP、`X-Content-Type-Options`、`X-Frame-Options`、
  `Referrer-Policy`、`Permissions-Policy`（[http_security.py](../server/app/core/http_security.py)）；
- 反代侧再补一层：

```nginx
server_tokens off;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header Referrer-Policy no-referrer always;
```

验证：

```bash
curl -sI https://protect.example.com/healthz | grep -Ei 'strict-transport|content-security|x-frame'
```

## 六、Host 与请求体限制

### Host 白名单

`truesight.config.json`：

```json
{
  "public": {
    "allowed_hosts": ["protect.example.com", "*.example.com"]
  }
}
```

未配置时 `TrustedHostMiddleware` 不启用（单机默认）；对外部署必须配置，
否则伪造 Host 可能污染日志与展示层。

### 请求体上限

应用层对关键字段有长度校验，但没有统一 Body 上限。nginx 侧必须设置：

```nginx
client_max_body_size 1m;
client_body_timeout 10s;
```

## 七、限流与反滥用

| 参数 | 默认 | 调整建议 |
| --- | --- | --- |
| `abuse.rate_per_minute` | 60 | 按真实业务峰值设置，不要为压测临时放大后忘记改回 |
| `abuse.burst` | 20 | 留出页面并发余量 |
| `abuse.trusted_proxies` | 空 | 反代后必须配置 |
| `goto.decision_timeout_ms` | 2500 | 网络差时适度调大；过大会拖慢用户 |

限流是**单进程**的；多实例部署必须在网关层做全局限流，否则每个实例各有一份额度。

## 八、数据与证据

### 备份

```bash
# SQLite（WAL 模式）：先 checkpoint 再拷贝，避免漏掉 WAL
sqlite3 server/data/truesight.db "PRAGMA wal_checkpoint(TRUNCATE);"
cp server/data/truesight.db /backup/truesight-$(date +%F).db
tar -czf /backup/evidence-$(date +%F).tar.gz server/data/evidence
```

- 数据库与证据目录必须一起备份，否则命中记录会指向不存在的文件；
- 备份文件含原始证据，按敏感数据保管；
- 恢复后可用「存储」页的校验功能确认证据哈希。

### 权限

```bash
chmod 700 server/data
chmod 600 server/data/truesight.db server/.env
```

### 清理

- 管理后台「存储」页可清理证据与日志；
- 清空命中属于破坏性操作，接口要求显式 `confirm=true`；
- 生产环境建议先把备份做好，再执行清理。

## 九、容器加固（docker compose）

现有编排已经把两个模式拆成两个容器，并只发布到 `127.0.0.1`。建议再加：

```yaml
services:
  truesight-local:
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    volumes:
      - truesight-data:/app/server/data   # 唯一可写目录
```

注意：`read_only` 需要确保 `data/` 是挂载卷；否则服务无法建库与写证据。

## 十、日志与监控

| 项目 | 做法 |
| --- | --- |
| 日志脱敏 | 统一走 `log_event`；密钥/明文 IP 不落日志 |
| 日志轮转 | 由 systemd / Docker / 外部采集负责，避免磁盘打满 |
| 健康检查 | `GET /healthz` 返回 mode / protection_level / version |
| 能力健康 | 管理后台「服务」页显示可用/降级/熔断 |
| 备份监控 | 定期检查备份文件大小与可恢复性 |
| 异常告警 | 关注 5xx、`rate_limited` 激增、`ticket_invalid` 激增、调度任务连续失败 |

## 十一、调度与对外动作

- 周期扫描默认关闭；开启前确认受保护资产已登记、扫描范围合规；
- 对外举报默认 `dry_run`；切换到 `webhook` 前必须确认接收方与法律合规；
- 高风险动作（清空命中、删除资产、真实举报）都要求人工确认。

## 十二、高可用与横向扩展

### 当前形态（单实例）

- 单进程 Uvicorn + SQLite（WAL）：部署简单、数据一致，但**不支持多实例共享状态**；
- 限流、票据 nonce、调度器都在进程内；
- `lifespan` 已实现优雅关闭：释放 HTTP 客户端、调度器与数据库连接（`AppContext.aclose`）；
- `/healthz` 可用于探活与编排层重启判断。

### 多实例前必须解决

| 问题 | 现状 | 解决方向 |
| --- | --- | --- |
| 限流各自计数 | 进程内令牌桶 | Redis 令牌桶 / 网关限流 |
| 票据重放窗口 | 无状态票据 | Redis nonce 消费表 |
| 调度器重复执行 | 每个实例都会启动 | 选主 / 分布式锁 / 只在一台启用 |
| SQLite 并发写 | WAL 单写者 | PostgreSQL + 连接池 |
| 主密钥一致性 | 每个实例读同一 `.env` | 密钥管理服务 / 同一 Secret |
| 会话/管理登录（二期） | 无 | 共享会话存储 |

### 推荐的扩展顺序

1. 先做**无状态水平扩展**：所有实例共享主密钥与 PostgreSQL，调度只在一台开启；
2. 再把限流与 ticket nonce 迁到 Redis；
3. 最后考虑多租户与 RBAC。

> 单实例不是缺陷：本项目的默认场景是「单机旁路组件」。把边界写清楚，
> 比在不具备条件时强行多实例更安全。

## 十三、上线检查清单

| 检查项 | 命令/位置 | 通过标准 |
| --- | --- | --- |
| 主密钥已替换 | 管理后台「检查」页 | 无占位密钥告警 |
| 模式正确 | `/healthz` | 公网端 `public` |
| 管理面不可公网访问 | nginx ACL / 直接请求 | 404 或 403 |
| Host 白名单 | `truesight.config.json` | 伪造 Host 被拒 |
| 受信代理 | `.env` + `tests/utils/test_net.py` | 反代后身份可区分 |
| TLS/HSTS | `curl -I` | HSTS 存在 |
| 安全响应头 | `curl -I` | CSP/nosniff/frame 存在 |
| 请求体上限 | nginx | 超大 Body 返回 413 |
| 备份 | 手工恢复演练 | 数据库 + 证据一致 |
| 日志脱敏 | 抽查日志 | 无密钥、无明文 IP |
| 调度开关 | 管理后台「服务」页 | 符合合规预期 |
| 举报通道 | 管理后台「设置」页 | 仍为 `dry_run` 或已确认接收方 |
