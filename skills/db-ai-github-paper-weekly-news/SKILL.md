---
name: db-ai-github-paper-weekly-news
description: 抓取并分析 PostgreSQL/DuckDB/AIbase/AI-bot/GitHub Trending/HuggingFace Papers 等 10 个权威源近 7 天的内容，按"PostgreSQL 生态 / 其他数据库 / AI 新闻 / GitHub 趋势项目 / AI 论文"五大主题分类去重总结，输出含 mermaid 图（分类饼图、时间线、思维导图、热度柱状图）的图文并茂 markdown 周报到调用项目的 markdown/ 目录。当用户提出"生成数据库AI周报"、"PostgreSQL/AI 一周资讯"、"近一周技术新闻汇总"、"db-ai 周报"、"跑一下周报"、"汇总本周数据库和AI动态"等需求时触发。不要把这个 skill 用于一次性的单一 URL 抓取或非新闻类内容总结。
---

# 数据库 / AI / GitHub / AI Paper 周报

## Overview

把 10 个公开源近 7 天内容拉下来，分类去重，写成一份含 mermaid 可视化的 markdown 周报，落到当前项目的 `markdown/` 目录。

## 工作流程

```
1. 准备阶段 → 验证:  确定输出目录、日期窗口
2. 抓取阶段 → 验证:  10 个源 WebFetch 完成，记录失败源
3. 分类阶段 → 验证:  每条条目归入 5 大类之一，去重
4. 生成阶段 → 验证:  按模板填充 markdown，mermaid 语法可渲染
5. 落盘阶段 → 验证:  文件写入 markdown/db-ai-weekly-YYYY-MM-DD.md
```

### 步骤 1：准备

- 用 `Bash` 跑 `date +%Y-%m-%d` 获取今日日期（不要相信训练记忆）
- 同时算出 7 天前的日期：`date -v-7d +%Y-%m-%d`（macOS）或 `date -d '7 days ago' +%Y-%m-%d`（Linux）
- 确认调用项目根目录下 `markdown/` 是否存在；不存在则 `mkdir -p markdown`
- 输出文件名固定：`markdown/db-ai-weekly-<今日 YYYY-MM-DD>.md`
- 若同名文件已存在，直接覆盖（周报按日期版本化已足够；不创建 `-v2` 之类副本）

### 步骤 2：抓取

用内置 `WebFetch`（**不是** `mcp__MiniMax__web_search`，那是搜索引擎；本任务是直拉已知 URL）。10 个源在同一条消息内并发 WebFetch 调用。

完整源清单见下方"数据源"小节。每个 URL 用同一个 prompt 模板：

```
列出本页面近 7 天（>= <7天前 YYYY-MM-DD>）发布或更新的条目。
每条输出：标题 | 发布日期 | 一句话摘要 | 原文链接。
忽略广告、订阅按钮、页脚导航。若无近 7 天内容，回答 "NO_RECENT_ITEMS"。
```

**抓取失败处理**：
- 单源失败（超时 / 403 / 跨域跳转）：记录到"失败源"列表，**不要重试超过 1 次**
- 全部失败：停止流程，告知用户哪些源失败，让用户决定是否继续
- 失败源会在最终报告底部 "数据源覆盖" 章节标灰

### 步骤 3：分类去重

**分类规则**（严格按源映射，避免误分类）：

| 类别 | 来源 |
|---|---|
| 🐘 PostgreSQL 生态 | postgresweekly.com, planet.postgresql.org, planet.postgis.net, postgresql.org/about/newsarchive/pwn, git.postgresql.org |
| 🦆 其他数据库 | duckdb.org/news |
| 🤖 AI 新闻 | aibase.com/zh, ai-bot.cn/daily-ai-news |
| ⭐ GitHub 趋势 | github.com/trending |
| 📄 AI 论文 | huggingface.co/papers/trending |

**去重启发式**：
- 同一标题（容忍中英文翻译差异）只保留一条，合并多个来源链接
- 同一 commit hash / paper arxiv id / repo full_name 视为同一条
- PostgreSQL 生态内 planet 聚合的博客若已被 postgresweekly 引用，以 postgresweekly 为主链接，planet 链接放"另见"

### 步骤 4：生成 markdown

读 `references/output-template.md` 拿到完整骨架。
读 `references/mermaid-patterns.md` 拿到 mermaid 图模板。

每份周报**至少**包含以下 mermaid 图：
1. **分类条目数饼图**（`pie`）—— 体现一周热度结构
2. **每日发布时间线**（`timeline` 或 `gantt`）—— 看哪天爆发
3. **重点项目/论文思维导图**（`mindmap`）—— 把 top 5 项目展开

可选：
- 技术栈出现频次柱状图（`xychart-beta`）

**写作风格**：
- 标题不夸张，不堆砌"震撼""革命性"等营销词
- 每条目附原文链接，禁止编造链接
- 论文条目附 arxiv id 或 HF papers id（若有）
- GitHub 趋势条目标注 star 数和主语言
- PG 提交记录只挑非 trivial 的（避免 typo fix），并把 commit hash 短链化为 `git.postgresql.org/...?h=<hash>`

### 步骤 5：落盘 + 自检

写入 `markdown/db-ai-weekly-YYYY-MM-DD.md` 后：
- 用 `Bash` 跑 `wc -l <文件>` 确认 > 100 行（少于此值说明抓取失败太多）
- 用 `Bash` 跑 `grep -c "\`\`\`mermaid" <文件>` 确认 mermaid 块数 >= 3
- 向用户汇报：文件路径 + 总条目数 + 各分类条目数 + 失败源列表（若有）

## 数据源（必拉 URL 列表）

| # | 类别 | URL |
|---|---|---|
| 1 | PostgreSQL 生态 | https://postgresweekly.com/ |
| 2 | PostgreSQL 生态 | https://planet.postgresql.org/ |
| 3 | PostgreSQL 生态 | https://planet.postgis.net/ |
| 4 | PostgreSQL 生态 | https://www.postgresql.org/about/newsarchive/pwn/ |
| 5 | PostgreSQL 生态 | https://git.postgresql.org/gitweb/?p=postgresql.git;a=shortlog |
| 6 | 其他数据库 | https://duckdb.org/news/ |
| 7 | AI 新闻 | https://www.aibase.com/zh |
| 8 | AI 新闻 | https://ai-bot.cn/daily-ai-news/ |
| 9 | GitHub 趋势 | https://github.com/trending?since=weekly&spoken_language_code= |
| 10 | AI 论文 | https://huggingface.co/papers/trending |

## 禁止行为

- ❌ 不要用 `mcp__MiniMax__web_search` 去"搜"这些站点 —— 直接 WebFetch 已知 URL
- ❌ 不要从训练记忆里编造"本周新闻" —— 任何条目必须有抓取证据
- ❌ 不要把 5 个 PG 源的同一篇博客重复列 5 次 —— 严格去重
- ❌ 不要把抓取失败的源静默吞掉 —— 必须在 "数据源覆盖" 章节标灰
- ❌ 不要在 markdown/ 之外的目录写文件
- ❌ 不要主动跑 `loop` 把周报变成自动任务（除非用户明确要求）

## 资源

- `references/output-template.md` —— 完整 markdown 输出模板（步骤 4 必读）
- `references/mermaid-patterns.md` —— 4 类 mermaid 图模板与坑点（步骤 4 必读）
