# 周报输出模板

按此模板生成最终 markdown。**占位符**用 `{{...}}` 包裹，生成时全部替换。
**示例条目**仅供格式参考，写入真实文件时删除示例、用实际抓取数据填充。

---

```markdown
# 数据库 / AI / GitHub / 论文 周报 · {{YYYY-MM-DD}}

> 📅 时间窗口：{{7天前 YYYY-MM-DD}} ~ {{今日 YYYY-MM-DD}}
> 🔗 数据源：10 个（成功 {{N}} / 失败 {{M}}）
> 📊 总条目：{{TOTAL}}

## 一、本周速览

{{2-3 句话总结本周最值得关注的 3 件事，给读者 30 秒决策"是否往下看"}}

### 分类条目分布

\`\`\`mermaid
pie showData
    title 本周条目分类占比
    "🐘 PostgreSQL 生态" : {{N1}}
    "🦆 其他数据库" : {{N2}}
    "🤖 AI 新闻" : {{N3}}
    "⭐ GitHub 趋势" : {{N4}}
    "📄 AI 论文" : {{N5}}
\`\`\`

### 每日热度时间线

\`\`\`mermaid
timeline
    title 近 7 天发布密度
    {{D1 YYYY-MM-DD}} : {{D1 关键词1}} : {{D1 关键词2}}
    {{D2 YYYY-MM-DD}} : {{D2 关键词1}}
    {{D3 YYYY-MM-DD}} : {{D3 关键词1}} : {{D3 关键词2}}
    ...
\`\`\`

---

## 二、🐘 PostgreSQL 生态

### 重点关注

\`\`\`mermaid
mindmap
  root((PG 本周))
    {{话题1}}
      {{要点1}}
      {{要点2}}
    {{话题2}}
      {{要点1}}
    {{话题3}}
      {{要点1}}
\`\`\`

### 内核提交摘要（git.postgresql.org）

| 时间 | Commit | 一句话 |
|---|---|---|
| {{YYYY-MM-DD}} | [`{{短 hash}}`]({{链接}}) | {{摘要}} |

### 社区文章 / 博客

#### {{文章标题}}
- 📅 {{YYYY-MM-DD}}
- 📍 来源：[{{来源名}}]({{链接}})  | 另见：[{{聚合源}}]({{链接}})
- 📝 {{2-3 句话摘要}}
- 🏷️ Tags: `{{标签1}}` `{{标签2}}`

#### {{下一篇标题}}
...

### 官方公告（postgresql.org PWN）

- {{YYYY-MM-DD}} · [{{公告标题}}]({{链接}}) —— {{一句话}}

---

## 三、🦆 其他数据库（DuckDB 等）

#### {{条目标题}}
- 📅 {{YYYY-MM-DD}}
- 📍 [{{链接}}]({{链接}})
- 📝 {{摘要}}

---

## 四、🤖 AI 新闻

### 热点速读

| 时间 | 标题 | 来源 |
|---|---|---|
| {{YYYY-MM-DD}} | [{{标题}}]({{链接}}) | aibase / ai-bot |

### 深度展开（top 3）

#### 1. {{标题}}
- 📅 {{YYYY-MM-DD}}
- 📍 [{{原文链接}}]({{链接}})
- 📝 {{3-5 句话摘要，含关键数字/模型/公司}}
- 🔍 影响面：{{对开发者/对企业/对消费者的影响}}

---

## 五、⭐ GitHub 趋势项目（weekly）

\`\`\`mermaid
xychart-beta
    title "Top 10 项目本周新增 stars"
    x-axis [{{repo1}}, {{repo2}}, {{repo3}}, {{repo4}}, {{repo5}}]
    y-axis "Stars (本周新增)" 0 --> {{MAX}}
    bar [{{s1}}, {{s2}}, {{s3}}, {{s4}}, {{s5}}]
\`\`\`

| # | 项目 | 语言 | ⭐ 本周新增 | 一句话 |
|---|---|---|---|---|
| 1 | [{{owner/repo}}](https://github.com/{{owner/repo}}) | {{Lang}} | +{{N}} | {{描述}} |

---

## 六、📄 AI 论文（HuggingFace Trending）

\`\`\`mermaid
mindmap
  root((本周论文主题))
    {{主题1：如 Agent / Reasoning}}
      {{论文1 标题简称}}
      {{论文2 标题简称}}
    {{主题2：如 Multimodal}}
      {{论文1 标题简称}}
    {{主题3：如 Efficient Inference}}
      {{论文1 标题简称}}
\`\`\`

#### {{论文标题}}
- 📄 [{{arxiv id 或 HF id}}]({{链接}})
- 👥 作者机构：{{机构 1, 机构 2}}
- 🎯 核心贡献：{{1-2 句话，重点是"它解决了什么 + 用了什么方法"}}
- 🔥 HF 热度：{{upvotes}} 👍

---

## 七、数据源覆盖

| # | 类别 | 源 | 状态 | 抓到条目数 |
|---|---|---|---|---|
| 1 | PG | postgresweekly.com | ✅ | {{N}} |
| 2 | PG | planet.postgresql.org | ✅ | {{N}} |
| 3 | PG | planet.postgis.net | {{✅/⚠️}} | {{N}} |
| 4 | PG | postgresql.org/about/newsarchive/pwn | ✅ | {{N}} |
| 5 | PG | git.postgresql.org/.../shortlog | ✅ | {{N}} |
| 6 | DB | duckdb.org/news | ✅ | {{N}} |
| 7 | AI | aibase.com/zh | ✅ | {{N}} |
| 8 | AI | ai-bot.cn/daily-ai-news | ✅ | {{N}} |
| 9 | GH | github.com/trending?since=weekly | ✅ | {{N}} |
| 10 | Paper | huggingface.co/papers/trending | ✅ | {{N}} |

{{失败源若有，用斜体单独列：}}
> ⚠️ 失败源：planet.postgis.net（超时）、ai-bot.cn（403）。建议人工核查或下次重跑。

---

*本周报由 `db-ai-github-paper-weekly-news` skill 于 {{今日 YYYY-MM-DD HH:MM}} 自动生成。条目均附原始来源链接，请以原文为准。*
```

---

## 模板使用注意

1. **空分类处理**：若某类（如"其他数据库"）本周无内容，章节标题保留，正文写 *"本周无新条目"*，**不要删除整个章节**（破坏目录一致性）
2. **mermaid 块内不能有反引号嵌套**：模板中显示的 `\`\`\`mermaid` 写入最终文件时是普通的 \`\`\`mermaid 三反引号
3. **link 必须可点击**：所有 `[xxx](url)` 的 url 必须是抓取阶段拿到的真实链接，禁止占位
4. **日期用 ISO 8601**：`YYYY-MM-DD`，不要 `2026/6/16` 或 `Jun 16, 2026`
5. **emoji 适度**：分类标题用就够了，正文每段不要超过 1 个 emoji
6. **去掉本文件中的 `{{...}}` 占位符与示例 #1/#2 这种残留**：交付前 `grep "{{" 文件` 应返回 0 行
