# 算法与实现细节

> 这篇文档解释「分数是怎么来的、证据是怎么固定的、看板是怎么聚合的」。
> 面向需要改阈值、加能力或答辩解释的读者；实现位置都给了文件路径。

## 一、域名形近候选生成

实现：`server/app/engine/dga/generator.py`

以受保护品牌域名的**可注册域**（SLD + TLD）为基准，生成十类变体：

| 手法 | 说明 | 示例 |
| --- | --- | --- |
| `homoglyph` | Unicode 同形异义字替换 | `а`（西里尔）冒充 `a` |
| `ascii_lookalike` | ASCII 形近字符替换 | `0` ↔ `o`、`1` ↔ `l` |
| `multi_char` | 多字符组合替换 | `rn` ↔ `m` |
| `omission` | 少打一个字符 | `exmple` |
| `repetition` | 重复一个字符 | `exxample` |
| `transposition` | 相邻字符换位 | `exmaple` |
| `hyphenation` | 插入连字符 | `ex-ample` |
| `affix` | 加前后缀 | `example-login` |
| `tld_swap` | 换常见顶级域 | `example.net` |
| `subdomain` | 加常见子域前缀 | `login.example.com` |

工程约束：

* 同一候选被多种手法命中时保留**编辑距离更小**的那条；
* 中间候选最多 `limit × 4`，最终随机打乱后截断到 `limit`（默认值见模块常量），
  避免品牌词很短时组合爆炸；
* 与原始域名完全相同的候选会被丢弃。

## 二、域名可疑度筛查

实现：`server/app/engine/dga/screening.py`

输入：候选域名 + 受保护品牌域名 + 品牌/行业关键词。输出 `DomainSignals`：
编辑距离、相似度、归一化熵、数字/连字符占比、同形异义字、混合文字系统、
punycode、品牌词包含、可疑度与理由。

### 2.1 特征权重

| 特征 | 分值 | 触发条件 |
| --- | ---: | --- |
| `tld_impersonation` | 60 | SLD 与品牌完全相同，仅 TLD 不同 |
| `distance_1` | 45 | 编辑距离 = 1 |
| `distance_2` | 25 | 编辑距离 = 2 |
| `distance_3` | 12 | 编辑距离 = 3 |
| `homoglyph` | 45 | 含 Unicode 同形异义字 |
| `mixed_script` | 20 | 混用多种文字系统 |
| `punycode` | 10 | 域名以 `xn--` 形式出现 |
| `brand_in_label` | 35 | 域名包含品牌词但不完全一致 |
| `keyword_in_label` | 10 | 包含行业/品牌敏感关键词 |
| `high_entropy` | 15 | 长度 ≥ 10 且归一化熵 ≥ 0.90 |
| `digit_heavy` | 8 | 数字占比 > 15% |
| `hyphenated` | 6 | 含连字符 |

合成：

```text
suspicion = min(100, Σ weight)
```

注意：

* 编辑距离档位是 `if/elif` 关系，只取最接近的一档；
* 熵必须配合**最小长度**（10）使用：短品牌词的归一化熵天然很高（`example` 约 0.90），
  单独用熵会把正常品牌全部误报；
* 相似度定义为 `1 - levenshtein / max(len)`，仅用于展示与排序，不直接计分。

### 2.2 已注册域名监控

实现：`server/app/engine/dga/watcher.py`

`DomainWatcher.scan(feed)` 对数据源返回的记录做：

1. 可注册域归一化；非法域名计入 `skipped.invalid_domain`；
2. 注册时间超过 `max_age_days` → `too_old`；
3. 可选相关性过滤（是否包含品牌词/关键词）→ `irrelevant`；
4. 可疑度低于阈值 → `low_suspicion`；
5. 命中按 `(-suspicion, domain)` 排序并截断到 `max_hits`。

数据源是 `DomainFeed` 协议；仓库自带的 `StaticDomainFeed` 只用于演示/测试，
**没有内置真实注册局全量数据**。

## 三、内容语义分析

实现：`server/app/engine/analyzers/text_semantic.py`

用标准库 `HTMLParser` 抽取标题、描述、可见文本、链接、邮箱、电话、表单数量与密码框数量。
文本长度上限默认 20,000 字符（防止超长页面拖垮下游）。

| 信号 | 加分 |
| --- | ---: |
| 标题直接包含品牌名 | +20 |
| 正文提及品牌 ≥ 3 次 | `min(15, 提及次数 × 3)` |
| 命中凭证类关键词（登录/密码/验证码/银行卡…） | +25 |
| 页面存在密码输入框 | +20 |
| 命中投资诱导话术（收益/稳赚/充值/USDT…） | +25 |
| 联系方式域名与官方域名不一致 | +15 |

这些分数是该层的 **0–100 原始分**，最终只按 0.25 的权重进入总分。

## 四、TLS 证书与 ICP

实现：`server/app/engine/analyzers/ssl_icp.py`

| 证书信号 | 分值 |
| --- | ---: |
| 证书已过期 | 30 |
| 30 天内到期 | 8 |
| 自签名（非受信 CA） | 30 |
| 证书域名与品牌域名不匹配 | 25 |
| 免费/自动化 CA | 8（弱信号） |
| 缺少组织信息（OV/EV 缺失） | 8 |

ICP：只有**真的查过且没有记录**才计 20 分；未配置查询服务时明确标记
`checked=False`，不把「没查」当成「没备案」。

## 五、评分合成

实现：`server/app/engine/scoring/__init__.py`

```text
总分 = min(100,
    60 × 黑名单命中
  + 35 × 威胁情报命中
  + 0.40 × 域名层原始分
  + 0.25 × 文本层原始分
  + 0.20 × 证书层原始分
  + 0.15 × ICP 层原始分
)
```

不变式：**总分 = 各 `RiskFactor.weight` 之和**（封顶 100 时除外），
每个因子都带来源与中文理由，因此结论可逐条追溯。

### 5.1 风险分档

| 分数 | 风险等级 | 结论 |
| ---: | --- | --- |
| ≥ 80 | `critical` | `dangerous` |
| ≥ 60 | `high` | `dangerous` |
| 35–59 | `medium` | `suspicious` |
| 15–34 | `low` | `suspicious` |
| < 15 | `unknown` | `safe` |

`score ≥ 60` 的命中直接进入「待人工审核」；其余先记为「新增」。

### 5.2 策略下限（可解释的例外）

「与品牌同名、只换 TLD」的域名层原始分是 60，按 0.40 折算只剩 24，
会被判 `safe` 放行 —— 这是最典型的品牌仿冒形态之一，不能静默放过。

处理方式不是直接抬分，而是追加一个**补差因子** `tld_impersonation_floor`，
把总分补到「可疑」下限 35，并在因子列表里写明「按策略抬至可疑档」。
这样可解释性不变式仍然成立。

### 5.3 意图分类

优先级：**投资诈骗 > 钓鱼诈骗 > 品牌侵权**。

* 有投资诱导话术 → `investment_fraud`；
* 有凭证表单/凭证关键词 → `phishing`；
* 否则有域名证据且总分 > 0 → `brand_infringement`；
* 都没有 → `unknown`。

## 六、AI 可疑灰区复核

实现：`server/app/engine/judgement.py`

只对 **35–59 分**的灰区、且已取得页面文本的样本调用文本模型：

1. 输入截断到 `MAX_TEXT_CHARS = 2000`，输出上限 400 token；
2. 要求严格 JSON：结论、意图、置信度、证据；
3. **只升不降**：`dangerous` 最多 +20，`suspicious` 最多 +10；
4. 置信度 `< 0.6` 不加分，只记录依据；模型认为安全时也不扣分；
5. 同一 `domain + text` 的 SHA-256 作为缓存键，最多缓存 256 条；
6. 解析失败、超时、未配置模型都记明确降级，不阻塞主判定。

页面文本是不可信输入：模型只能「加分」，不能把高危结论洗白。

## 七、命中去重与脱敏投影

实现：`server/app/services/findings.py`

* 去重键：`fingerprint = sha256("domain:" + 可注册域)`；
* 同一仿冒域名被 DGA、举报、goto、情报多个来源发现时，只保留一条命中，
  更新分数、风险、最近发现时间与来源语义；
* 每次写入/审核后同步 `DashboardEvent`（以 fingerprint 查找，存在则更新，否则插入）；
* 启动时 `backfill_dashboard_projection()` 为历史命中补齐投影，操作幂等；
* 公网看板只读投影表，不接触原始证据、注册人、精确 IP。

## 八、证据完整性

实现：`server/app/engine/forensics/__init__.py`

* 每个证据文件写入后计算 **SHA-256**，文件名包含时间戳与短哈希前缀；
* `verify(artifact)` 重新读取文件并比对哈希，可发现篡改/损坏；
* `build_manifest()` 生成 `truesight.evidence.manifest/1` 清单：
  指纹、域名、生成时间、文件数、总字节、每个文件的路径/哈希/媒体类型/采集时间；
* 清单本身也作为证据落盘（`manifest.json`），实现「自证」；
* 边界：这是**哈希清单**，不是区块链，也没有第三方时间戳；法律效力取决于保管链。

## 九、看板聚合

实现：`server/app/services/dashboard.py`

* 窗口：最近 1–365 天（前端提供 7/30/90）；
* 过滤条件：`occurred_at >= now - window_days`；
* 聚合：
  * 总数 `COUNT(*)`、平均分 `AVG(score)`；
  * 按风险/意图/状态/地区分组计数，按计数降序；
  * 趋势按 `DATE(occurred_at)` 分组，返回每日数量与平均分；
* 所有字段来自投影表，天然脱敏。

## 十、复杂度与限制

| 环节 | 复杂度 / 上限 | 说明 |
| --- | --- | --- |
| 形近生成 | 候选上限 `limit × 4`，最终 `limit` | 防止短品牌词组合爆炸 |
| 编辑距离 | `O(len²)`，带 cutoff 提前返回 | 只关心近距离 |
| 域名筛查 | 每个候选 `O(品牌数 × len²)` | 品牌数量通常很小 |
| 页面文本 | 上限 20,000 字符 | 防止内存与下游成本失控 |
| AI | 灰区才调用，2000 字符 / 400 token | 成本可控 |
| 看板 | 单表聚合查询 | 十万级数据后需归档/索引优化 |

> 所有权重与阈值都是**可标定参数**，不是自然常数。真实部署应使用本地样本
> 重新计算 ROC/PR 并调整；当前值来自方案推演与小规模演示。
