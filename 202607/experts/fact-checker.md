# 事实核查报告 — 五位专家稿件(PostgreSQL 优化/监控/故障诊断/问题分析/FAQ AI)

> 核查对象：
> - `markdown/experts/1-optimization.md`
> - `markdown/experts/2-monitoring.md`
> - `markdown/experts/3-fault-diagnosis.md`
> - `markdown/experts/4-problem-analysis.md`
> - `markdown/experts/5-faq-ai.md`
>
> 参考材料：`20260708_05.md`(德哥原稿)、`20181203_01.md`(PG11 参数模板)、PG 17 官方文档、PG 官方 wiki。
>
> **总体结论**：五位专家稿件 **基本可信**，主体内容来自德哥讲义消化，版本号、参数默认值、SQL 函数引入版本、视图字段含义大部分都对得上。**已发现 1 处明显矛盾、2 处专家稿件内部错误、若干处微小存疑**，均在下方列出。

---

## 一、矛盾清单(必须由终稿作者处理)

### M1. `checkpoint_completion_target` 推荐值 — 专家自相矛盾

| 稿件 | 推荐值 | 出处行 |
|---|---|---|
| 1-optimization.md | **0.2**(理由：SSD 设小,快速结束) | line 514 |
| 2-monitoring.md | **0.9**(ControlFileSync 频繁 → 提到 0.9) | line 354 |
| 3-fault-diagnosis.md | **0.9**(拉长 checkpoint,把集中写摊平) | line 776 |
| PG 17 官方默认值 | **0.9**(自 PG 14 起) | PG 官方文档 |

**建议**：以 PG 官方默认与 2/3 专家的 **0.9** 为准，把 1-optimization.md 的 0.2 改回 0.9。SSD 场景拉低到 0.2 没有官方依据，且会加剧 checkpoint IO 尖刺。建议改写为：

```ini
checkpoint_completion_target = 0.9   # PG 14+ 默认;拉长 checkpoint,把 IO 摊平
```

---

## 二、内部错误清单(单专家稿件自相矛盾 / 公式错误)

### E1. `synchronous_commit = off` 数据丢失公式 — 1-optimization.md 错

**原文**（line 524）：
> `off`:最多丢 `wal_writer_delay × wal_writer_flush_after` 的数据(通常几毫秒 ~ 几十毫秒)

**事实**：PG 17 官方文档明确写 **up to `3 × wal_writer_delay`**(默认 200ms,最坏约 600ms)。`wal_writer_flush_after` 是「累计多少字节后强制 flush」,与「最坏丢失时长」无关,二者维度不通,相乘无意义。

**建议改写**：
> `off`:最多丢失 `3 × wal_writer_delay`(默认 200ms → 最坏 ~600ms)的数据。

### E2. `pg_dump -j` 命令与注释自相矛盾 — 1-optimization.md

**原文**（line 1269）：
```bash
pg_dump -Fc -j 4 --no-acl --no-owner mydb > mydb.dump  # -j 并行(目录格式才支持)
```

**事实**：PG 自 9.3 起,`-j N` 只支持 `-Fd`(目录格式),配 `-Fc`(custom)会报 `cannot specify -j together with a non-directory format`。注释自写"目录格式才支持",但命令用了 `-Fc`。

**建议改写**：
```bash
pg_dump -Fd -j 4 --no-acl --no-owner -f mydb.dump.dir mydb  # -j 必须配 -Fd
# 恢复时: pg_restore -j 4 -d mydb mydb.dump.dir
```

### E3. B-Tree 改进版本号混淆 — 4-problem-analysis.md

**原文**（line 105）：
> PG 12 以后 B-Tree 有 bottom-up deletion、dedup 等改进

**事实**：
- bottom-up index deletion：PG 12 引入 ✓
- B-Tree deduplication：**PG 13 引入**(非 PG 12)

**建议改写**：
> PG 12 增加 bottom-up index deletion,PG 13 进一步引入 B-Tree deduplication。

---

## 三、未证实主张 / 出处可疑清单(可酌情补出处或弱化措辞)

### U1. `pg_blocking_pids()` "跨实例稳定" — 2-monitoring.md line 109 / 232

**原文**：
> `queryid` 在 PG 13+ 跨实例稳定(基于 parse tree 哈希)

**存疑**：`queryid` 在同一 major 版本 + 同一 SQL 文本(规范化后)稳定;但 PG 大版本升级(14→15、16→17)会因 `pg_stat_statements` 内部算法微调而变化,**不能简单说"跨实例"稳定**。建议弱化为"同一 major 版本内稳定"或删掉"跨实例"。

### U2. 5-faq-ai.md 中关于 `~/.claude/skills/digoal/` 现成 SKILL 的描述 — line 432~434

**原文**：
> `~/.claude/skills/digoal/SKILL.md`(注:这个 skill 路径已经存在,见 `~/.claude/skills/digoal/`,有现成的 SKILL.md / references/ / scripts/)

**存疑**：纯本地路径声明,无任何链接或截图可验证。作者自己也标了"诚实边界"。建议在终稿中明确这是"假设性描述 / 教学演示",避免读者误以为标准配置。

### U3. 5-faq-ai.md 中 `huashu-nuwa` skill 的描述 — line 430

**原文**：给出 GitHub `alchaincyf/nuwa-skill` 链接,称是"花叔(AlchainHust)"开源。

**建议**：作者已附 GitHub 链接,基本可追溯。但"花叔"这个昵称没有更可信的出处,可保留或弱化为"作者署名为 alchaincyf"。

### U4. 2-monitoring.md 中 `pgwatch2 ≥ 3.x 支持 PG 16 / PoWA ≥ 4.0 支持 PG 15` — line 769

**存疑**：版本兼容矩阵无任何官方链接支撑。建议补:pgwatch2 GitHub releases 页 / PoWA readthedocs 页,或弱化为"近年版本普遍支持到 PG 16/17"。

### U5. 1-optimization.md 中 `pg_hint_plan` "支持 PG 16/17" — line 1076

**存疑**：给了 GitHub 链接,可查证。但具体到 PG 17 的兼容版本号没说。建议补一句"建议用最新 release,具体见 GitHub releases"。

### U6. 5-faq-ai.md 中"AD Lock 秒杀 23 万 TPS、批量写入 145 万行/s"等数字 — line 449 / 5-faq-ai.md line 454

**存疑**：数字本身与 20260708_05.md 一致(可追溯),但 1-optimization.md line 137 已经诚实标注"56 核 ECS + NVMe 上的数据"。终稿保留时建议**同时附硬件配置 + 测试日期**,避免读者拿这两个数字套自己的环境。

---

## 四、可疑数据 / 案例清单(数字合理但条件不全)

| # | 稿件 | 数字/案例 | 缺什么 |
|---|---|---|---|
| C1 | 1-optimization.md line 137 | 批量写入 145 万行/s,unlogged 813 万行/s | 已标"56 核 ECS + NVMe" + 2018 年测试;终稿保留需注明 PG 10 与硬件 |
| C2 | 1-optimization.md line 138 / 5-faq-ai.md | JSON GIN 1 亿行 14.4 万 TPS | 缺 PG 版本 / 硬件 / 数据形态(schema、字段数) |
| C3 | 2-monitoring.md / 5-faq-ai.md | AD Lock 23 万 TPS(nowait 66630、未优化 2855) | 数字与 20260708_05.md 一致可追溯,但 5-faq-ai.md 没标硬件 |
| C4 | 1-optimization.md line 138 | pg_trgm / RUM 性能 | 用了"性能足够"这种定性词,无 benchmark,不影响可信度但建议弱化 |

**处理建议**：这些数字都不是"错",只是**缺前置条件**。终稿如果直接抄 5-faq-ai.md 中的数字(如 line 449),建议把 20260708_05.md / 1-optimization.md 已标的硬件一并搬过去。

---

## 五、已核对且一致的事实(给终稿作者"放心区"参考)

下列条目五位专家全部一致,且与 PG 17 官方文档 / 20181203_01.md / 20260708_05.md 对齐:

- `pg_blocking_pids()` 函数 PG 9.6+ 引入 ✓(1/2/4 多处一致)
- `compute_query_id` PG 13+ 默认 on ✓
- `autovacuum_work_mem` PG 13+ 引入 ✓
- `wal_compression` PG 9.5+ 引入,PG 15 改 LZ4 ✓
- `auto_explain.log_format = json` PG 10+ ✓
- `uuidv7()` PG 17+ ✓
- `REINDEX CONCURRENTLY` PG 12+ ✓
- `INCLUDE` 非主键列 PG 11+ ✓
- Hash 索引 WAL logged PG 11+ ✓
- Bloom filter index PG 10+ ✓
- `enable_partitionwise_join/aggregate` PG 11+ ✓
- `track_io_timing` PG 8.2+ ✓
- `idle_in_transaction_session_timeout` PG 9.6+ ✓
- `idle_session_timeout` PG 14+ ✓(3-fault-diagnosis.md line 1060)
- `SKIP LOCKED` PG 9.5+ ✓
- `wait_event_type` / `wait_event` PG 9.6+ ✓
- `pg_stat_progress_vacuum` PG 9.6+,`max_dead_tuple_bytes` PG 13+ ✓
- `write_lag/flush_lag/replay_lag` PG 10+ ✓
- `synchronous_standby_names ANY n` 语法 PG 10+ ✓
- `pg_stat_checkpointer` PG 17+(3-fault-diagnosis.md line 768) ✓
- `pg_stat_io` PG 16+(3-fault-diagnosis.md line 803) ✓
- `wal_status / safe_wal_size` PG 13+(3-fault-diagnosis.md line 638) ✓
- `mxid_age(datminmxid)` 函数 PG 9.5+ ✓
- `huge_pages = try` 默认 PG 13+ ✓
- `backend_type` 字段 PG 10+ ✓
- `random_page_cost = 4.0` 默认,SSD 场景 1.0~1.1 推荐 ✓
- `max_connections` 公式「物理内存(GB) × 1000 × (1/4) / 5」(1-optimization.md 与 20181203_01.md 一致)✓
- `shared_buffers` 公式(hugepage 时 RAM × 1/4,否则 min(32GB, RAM × 1/4))与 20181203_01.md 一致 ✓
- `work_mem` / `maintenance_work_mem` / `autovacuum_work_mem` 公式与 20181203_01.md 一致 ✓
- 6 张视图速查(`pg_stat_activity` / `pg_stat_database` / `pg_stat_user_tables` / `pg_stat_user_indexes` / `pg_statio_user_tables` / `pg_stat_replication`)在 2-monitoring.md 与 20260708_05.md §2.3 一致 ✓
- "先 EXPLAIN ANALYZE → 看 total_time → 看 buffer → 看 actual → 看 settings → 看 filter" 七步法在 1/2/3/20260708_05.md 全部一致 ✓
- "DDL 加 lock_timeout" 范式 4 份稿件一致 ✓
- `hot_standby_feedback = off` 生产推荐 1-optimization.md / 20260708_05.md / 4-problem-analysis.md 一致 ✓
- 长事务 → 阻 vacuum → 膨胀 → 雪崩因果链 5 份稿件一致 ✓

---

## 六、终稿合成建议(操作清单)

1. **`checkpoint_completion_target`**：以 0.9 为准统一(M1)。
2. **`synchronous_commit = off` 数据丢失公式**：改成 `3 × wal_writer_delay`(E1)。
3. **`pg_dump` 并行备份示例**：改成 `-Fd -j N`(E2)。
4. **B-Tree dedup 版本**：PG 13+(E3)。
5. **`queryid` 跨实例稳定**：弱化为"同 major 版本内稳定"或删"跨实例"(U1)。
6. **5-faq-ai.md 引用 AD Lock / 145 万行/s 等数字**：补硬件 + 测试日期(U6 / C1)。
7. **2-monitoring.md `pgwatch2 / PoWA` 版本兼容矩阵**：补 GitHub releases 链接或弱化(U4)。

---

## 七、事实可信度评级

**整体评级：基本可信(B 档)**

- 没有"PG 17 有 X 功能"这种大方向错误
- 没有版本号严重错位(只有 dedup vs bottom-up 这种小细节)
- 没有公式 / 机制层面硬伤(`synchronous_commit` 数据丢失公式是一处明显瑕疵,但专家自己在文中也加了"通常几毫秒~几十毫秒"的限定,实际影响有限)
- 没有发现"工具已停更"类硬错(2-monitoring.md / 20260708_05.md 都诚实标了"PipelineDB 已停止维护" ✓)
- 没有发现同参数 / 同函数 / 同机制在多专家间相互打架(M1 的 checkpoint_completion_target 是唯一明显矛盾)

终稿合成时,按本清单 **7 条建议** 修订即可。