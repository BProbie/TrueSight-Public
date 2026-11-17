# 部署说明（文档版）

完整的可执行步骤在 [deploy/README.md](../deploy/README.md)。这一篇讲**怎么选、为什么这么选**，
以及接入自有站点时的注意事项。

## 一、四种形态怎么选

| 形态 | 适用 | 优点 | 代价 |
| --- | --- | --- | --- |
| 单进程 | 演示 / 答辩 / 单机试用 | 一个进程一个端口，零额外依赖 | 公网端与本地端同机同库（不满足「脱敏隔离」） |
| 独立可执行文件 | 分发给最终用户 / 离线演示 | 目标机零环境依赖，单文件即可运行 | 需在对应平台构建，体积较大 |
| 容器编排 | 一台服务器长期运行 | 公网端与本地端**物理隔离**（独立数据卷）；一键重启 | 需要 Docker |
| 反向代理接入 | 已有站点要接入中转 | 不用改后端，接入成本最低 | 需要能改站点模板或 nginx |

**演示场景建议单进程**：`scripts/run.ps1 -BuildFrontend` 一条命令即可，页面与接口都在 8000 端口。
**交给非开发人员试用建议独立可执行文件**：目标机不需要任何环境。
**长期运行建议容器编排**：这是方案里「旁路式 + 数据隔离」最直接的体现。

## 二、单进程

```powershell
launch.bat                  # 一键：准备环境 + 按需构建前端 + 启动 + 打开浏览器
# 或分步：
powershell -File scripts/run.ps1 -BuildFrontend
# 公网侧  http://127.0.0.1:8000/
# 管理后台 http://127.0.0.1:8000/admin/
```

手动等价命令：

```powershell
cd server
.\.venv\Scripts\python.exe -m uvicorn app.main:create_app --factory --host 127.0.0.1 --port 8000
```

启动时发生的事情顺序（都在 lifespan 内，导入期零副作用）：

1. 建表（`local` 模式，单机场景）→ 2. 创建数据目录 → 3. 应用库内保存的设置覆盖
→ 4. 用数据库里的供应商记录装配模型注册表 → 5. 若 `schedule.enabled=true` 则启动周期任务
→ 6. 挂载前端静态产物（若有）。

## 三、独立可执行文件（便携分发）

适合把项目交给**没有开发环境**的人试用：目标机不需要 Python、Node、数据库或任何运行库。

构建（Windows）：

```powershell
powershell -File scripts/build-exe.ps1
# -Edition business|internal  交付给企业（不含 /root）/ 自留 B+A（默认 internal）
# -Clean         清理后重建
# -SkipFrontend  已构建过前端时跳过 npm run build
# -OutputDir release  自定义输出目录
```

产物是 `dist/TrueSight.exe`（约 27 MB），已内置 Python 运行时、全部依赖与前端页面。
`business` 产物只包含 `/` 与 `/admin`，平台模块会被 PyInstaller 排除；`internal`
额外包含 `/root` 平台控制台。版本写在产物内部的 `edition.txt`，目标机改写环境变量
也无法打开平台入口。构建脚本会复用 `server/.venv`，首次构建自动安装 PyInstaller；
**构建阶段**仍需要 Python 3.12 + Node 20 与网络。

运行：

```powershell
.\dist\TrueSight.exe                         # local 模式，127.0.0.1:8000，自动打开浏览器
.\dist\TrueSight.exe --port 8010 --no-browser
.\dist\TrueSight.exe --mode public           # 只读脱敏模式
.\dist\TrueSight.exe --data-dir D:\TrueSightData
```

目录与配置：

* 首次运行会在 **exe 旁边**创建 `data/`；数据库、证据、日志都写在这里，重启不丢；
* 可在 exe 旁放置 `.env`（参考 `server/.env.example`）配置端口、主密钥等；
* `truesight.config.json` 会被复制到 exe 旁，用于 Logo/Favicon、公网地址、允许 Host；
* 项目根目录的 `img/` 会一并复制到产物旁（相对路径 Logo 才能正常显示）；
* 若项目根目录存在 `img/logo.ico`，构建时自动作为 exe 图标；
* 升级时替换 exe 即可，`data/`、`.env` 与 `truesight.config.json` 保留。

**Linux 自包含 ELF**（在 Linux / WSL2 中构建）：

```bash
bash scripts/build-elf.sh                  # 构建前端 + dist/linux/TrueSight（B+A，默认）
bash scripts/build-elf.sh --edition business  # 仅 B 端（对外交付）
bash scripts/build-elf.sh --skip-frontend  # 复用已构建前端
# 默认使用 Linux 专用 server/.venv-linux，不会碰 Windows 的 server/.venv；
# 也可显式指定其他构建环境：
TRUESIGHT_BUILD_VENV=/tmp/truesight-build-venv bash scripts/build-elf.sh --skip-frontend
```

产物是 `dist/linux/TrueSight`（约 35 MB，ELF 64-bit），目标机不需要 Python / Node。
运行：

```bash
cd dist/linux
./TrueSight --no-browser             # local 模式，127.0.0.1:8000
./TrueSight --port 8010 --mode public
```

注意：PyInstaller **不能从 Windows/macOS 交叉编译 Linux ELF**；脚本会先检查
`uname -s`，在非 Linux 环境直接给出错误提示。WSL2 是最省事的 Windows 构建方式。

其他注意事项：

* PyInstaller **不能跨平台编译**：Windows 产出 `.exe`，Linux / macOS 需在对应系统上构建；
* onefile 每次启动会解压到临时目录，首次启动略慢；个别杀毒软件可能误报，需加白名单；
* 体积较大，`dist/` 已写入 `.gitignore`，不要提交到仓库；
* 若放在只读目录（如 `Program Files`），数据目录创建会失败，请放到用户可写目录。

## 四、容器编排

```powershell
Copy-Item deploy\.env.example deploy\.env     # 填写 TRUESIGHT_SECRET_KEY
docker compose -f deploy/docker-compose.yml up -d --build
```

三个容器：`truesight-local`（全功能，仅发布到 `127.0.0.1:8000`）、
`truesight-public`（只读脱敏，独立数据卷，`127.0.0.1:8001`）、
`gateway`（nginx，对外唯一入口 `127.0.0.1:8080`）。

nginx 配置里 `location /admin/` 与 `/api/v1/admin/` 只放行内网网段
（`127.0.0.1` / `10.0.0.0/8` / `172.16.0.0/12` / `192.168.0.0/16`），
这是「管理后台绝不暴露公网」的最后一道闸门 —— 即使编排层误把本地端发布出去，这一层也不放行。

编排已为两个服务设置 `TRUESIGHT_ABUSE__TRUSTED_PROXIES=127.0.0.1,::1,172.16.0.0/12`，
使 nginx 后面的客户端 IP 仍可区分；若你改了容器网络网段，需要同步调整。
nginx 同时限制了 `client_max_body_size 1m`，超大请求体在网关层就被拒绝。
详见 [HARDENING](HARDENING.md)。

## 五、接入已有站点（关键一步）

把站点模板里的**出站**外链改写成中转地址：

```
https://<中转站>/api/v1/goto?from=<来源页地址>&to=<目的地址>
```

推荐做法（按可行性排序）：

1. **改模板 / 中间件**：能拿到「来源页」上下文，判定更准，也最可靠；
2. **网关响应体重写**（nginx `sub_filter`）：无需改源码，但只能处理文本响应，
   且要注意不要对搜索引擎爬虫启用（否则中转链接会被收录成外链）。

注意事项：

* 只改**出站**链接，站内链接不要动；
* 放行时是 302 直接跳转，用户无感；只有达到当前保护等级的处理范围才进风险页
  （2 级及以上为中等及以上，1 级为高危及以上），5 级直接拦截 ——
  **不要把「每次跳转都弹确认页」当成演示效果**，那会直接毁掉可用性（方案里也是这么要求的）；
* 需要机器可读结论时加 `?format=json`（脚本化联调时很有用）；
* 若站点已启用 HSTS / CSP，确认中转域名在允许列表内。

## 六、周期性检测（默认关闭）

`TRUESIGHT_SCHEDULE__ENABLED=false` 是默认值：**「装完就在别人站点上跑扫描」是不可接受的默认行为**。
开启前请确认：

1. 受保护资产已登记（否则扫描没有基准，只会明确跳过）；
2. 抓取遵循 robots（`TRUESIGHT_CRAWLER__RESPECT_ROBOTS=true`），不要为了拿数据关掉；
3. 认可以下成本上限：单次候选数 50、单次落库命中数 20、单次重扫数 30、单任务超时 900s；
4. 想先看效果 → 到管理后台「服务」页点「立即执行」（与定时触发同一条路径，同样落任务记录）。

五个任务及其语义：

| 任务 | 做什么 | 缺依赖时的行为 |
| --- | --- | --- |
| `typosquat_scan` | 由受保护资产生成形近候选并探测 | 无资产 → 明确跳过 |
| `new_domain_watch` | 从情报源拉新注册域名做三重过滤 | 无情报源 → 明确跳过 |
| `content_check` | 重扫历史命中、刷新结论（只升不降，不改首次来源） | 无待处理命中 → 明确跳过 |
| `forensics` | 给「尚无证据」的命中补取证 | 无取证能力 → 明确跳过 |
| `abuse_report` | 给「人工已确认」的命中生成举报留痕（**仅演练**） | 无举报服务 → 明确跳过 |

`goto_check` / `report_check` 由请求路径实时触发，不参与周期调度；
`intel_refresh` 因未接入威胁情报源而明确跳过（而不是假装跑过）。

## 七、对外举报：默认只演练

`TRUESIGHT_ABUSE__CHANNEL_MODE=dry_run`（默认）→ 只生成提交内容并落库留痕，**零网络调用**。

要向真实渠道发送，需要三件事同时满足：

1. 管理后台开启「对外举报通道」开关（`features.abuse_channel_enabled`）；
2. 配置 `webhook` 形态与端点（`channel_mode=webhook` + `channel_endpoint`，端点会过 SSRF 裁决）；
3. **人工确认**（管理后台对某条留痕点「确认提交」）。

为什么这么保守：向注册商/反诈平台提交举报是**对外产生法律与声誉后果**的动作，
一旦提交错误目标就是诬告。默认演练 + 人工确认是这条约束的代码实现。

## 八、上线检查清单

1. `TRUESIGHT_SECRET_KEY` 已替换（占位值会在启动日志与管理后台自检里持续告警）；
2. 管理后台只经内网/反代访问；公网侧跑 `public` 模式；
3. 周期任务与对外举报**保持关闭**，直到确认合规依据；
4. 备份 `data/`（数据库 + 证据链）并单独保管主密钥；
5. 用 `/healthz` 做探活；用管理后台「服务」页看能力健康与降级情况；
6. 先用「立即执行」跑一轮任务，确认产出的命中与报告符合预期，再开定时。
