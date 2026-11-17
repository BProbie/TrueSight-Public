# 贡献指南

> 这个项目的铁律只有一条：**每个模块先有全部通过的测试，才允许进入下一个模块**。
> 下面的流程都是为这条铁律服务的。

## 一、开始之前

```powershell
git clone <repo-url> && cd TrueSight
powershell -File scripts/bootstrap.ps1     # 建环境、装依赖、生成 .env
powershell -File scripts/verify.ps1        # 确认门禁在本地全绿（约 30 秒）
```

`verify.ps1` 就是 CI 跑的东西：`ruff check` + `ruff format --check` + `pytest` + 前端构建。
**本地不全绿就不要开始改**——否则你分不清是环境问题还是自己的问题。

## 二、开发流程

1. **先想清「为什么」**：这个改动解决什么真实问题？属于哪一层（core / engine / services / api / frontend）？
2. **先写测试**：至少覆盖「正常路径 + 失败降级路径 + 边界值」；
3. **再写实现**：遵守 [代码约定](docs/DEVELOPMENT.md#六代码约定)；
4. **跑门禁**：`powershell -File scripts/verify.ps1`；
5. **更新文档**：行为变了就改 [CHANGELOG.md](CHANGELOG.md)；接口变了就改 [docs/API.md](docs/API.md)；
6. **提交**：一次提交只做一件事；提交信息说清**为什么**。

## 三、提交信息规范

采用「类型: 说明（为什么）」的形式，中文说明：

```
feat: 新增 DNS 解析能力（L0 层在等级 1 即可用，失败时明确跳过）
fix: 目标站点失败不再计入熔断（否则三个打不开的站点会关掉整个抓取能力）
test: 补取证目录不可写时的降级用例（此前只覆盖了抓取失败）
docs: 澄清「同品牌名仅换 TLD」为何不单独触发预警
refactor: 把计划结算抽成 _settle_plan（降级不再可能被静默吞掉）
chore: 升级 ruff 到 0.8（仅格式化与规则集调整）
```

类型：`feat` / `fix` / `test` / `docs` / `refactor` / `perf` / `chore`。

## 四、硬性要求（会被评审打回的情况）

| 要求 | 原因 |
| --- | --- |
| 新增行为必须带测试 | 没有测试的降级路径等于没有降级 |
| 测试不得访问真实网络 | 否则 CI 会因别人的站点抖动而红；用注入假实现或 `respx` |
| 外部失败必须归一化为项目错误类型 | 否则上层要认识 `httpx`/`sqlalchemy` 的异常，新增调用点极易漏处理 |
| 失败要么进 `skipped` 要么留中文说明 | 「静默少做一步」是本项目最不能接受的缺陷 |
| 密钥/明文不得出现在日志、异常、响应、`repr` | 隐私与安全的底线 |
| 不得提交 `.env`、`data/`、真实证据文件 | 见 [.gitignore](.gitignore) |
| 前端不得用 `v-html` 渲染后端或模型生成的文本 | 注入会直接升级为 XSS |

## 五、测试怎么写

```python
# 1) 纯逻辑：直接断言输入输出与边界
def test_domain_scale_turns_brand_swap_into_a_low_band_score() -> None:
    result = score(ScoreInput(domain_signals=signals_with(60)))
    assert result.score == 24
    assert result.risk_level is RiskLevel.LOW

# 2) 网络交互：注入假实现（首选）或 respx 打桩
async def test_fetch_failure_only_degrades(database, tmp_path) -> None:
    collector = make_collector(fetcher=FakeFetcher(error=UpstreamError("炸")))
    outcome = await collector.collect(finding_id=1, domain="fake.example", url="https://fake.example/")
    assert outcome.degraded is True
    assert NOTES["fetch_failed"] in outcome.notes

# 3) 时间相关：注入可控时钟，不要 sleep
limiter = TokenBucketRateLimiter(rate_per_minute=60, clock=clock)
clock.advance(1.0)  # 推进时间而不是等待
```

## 六、目录与命名

* 后端：`app/<layer>/<module>.py`，测试镜像到 `tests/<layer>/test_<module>.py`；
* 前端：`frontend/apps/<app>/src/views/<Name>View.vue`，共享逻辑进 `frontend/packages/shared/src/`；
* 文档：面向使用者的放 `docs/`，面向贡献者的放仓库根目录；
* 提交前请勿改动无关文件的格式（**不要对全仓库跑 `ruff format`**，只格式化你改过的文件）。

## 七、评审关注点

1. 降级是否显式可见（`skipped` + 说明）；
2. 隐私与密钥是否零外泄；
3. 测试是否离线可复现、是否覆盖失败路径；
4. 是否引入「为一个场景过度设计」的抽象（宁可三行重复，不要过早抽象）；
5. 文档与 CHANGELOG 是否同步。

## 八、沟通方式

* 缺陷与建议：开 Issue，写清**复现步骤 + 预期 + 实际 + 相关日志**（日志已脱敏，可直接贴）；
* 安全相关问题：**不要开公开 Issue**，按 [SECURITY.md](SECURITY.md) 的私密渠道上报；
* 行为规范：参与本项目即视为同意 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
