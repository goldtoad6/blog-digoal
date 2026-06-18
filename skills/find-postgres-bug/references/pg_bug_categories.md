# PG Bug 分类与典型信号

## 1. CRASH 类（PANIC / FATAL / SIGSEGV / SIGABRT）

**特征**: `postgres` 进程被信号杀掉，触发 core dump 或被 `postmaster` 重启。

**典型日志**:
```
LOG:  server process (PID 12345) was terminated by signal 11: Segmentation fault
LOG:  terminating any other active server processes
LOG:  all server processes terminated; reinitializing
FATAL:  could not open shared memory segment: ...
```

**重点抓取字段**:
- `signal 11` (SEGV) / `signal 6` (ABRT) / `signal 7` (BUS)
- `stack trace` (Linux 上用 `bt full` 从 core 拿)
- 失败函数名（`elog(ERROR)` 抛在哪个文件）
- `assertion "..." failed`（Assert 失败）

**常见位置**:
- 解析器 (`src/backend/parser/`)
- 执行器 (`src/backend/executor/`)
- 哈希/排序溢出（`src/backend/executor/nodeHash.c`）
- ICU/Collation 切换时
- 扩展加载时 ABI 不匹配

## 2. 逻辑错误类（结果错误 / 计划器缺陷 / 约束违规）

**特征**: 没崩，但返回值、影响行数、约束检查违反预期。

**典型日志**:
```
ERROR:  duplicate key value violates unique constraint "..."
ERROR:  new row for relation "..." violates check constraint "..."
WARNING:  page is not expected version ...
```

**调查入口**:
- `EXPLAIN (ANALYZE, BUFFERS, VERBOSE)` 对比预期计划
- `pg_stat_statements` 看实际执行次数/时间
- 涉及窗口函数、CTE、UPSERT、partition pruning 时尤其留意

**典型缺陷**:
- partition 表的 `PartitionPrune` 没正确剪枝
- 物化视图 `REFRESH MATERIALIZED VIEW CONCURRENTLY` 与 unique index 顺序冲突
- `MERGE` 语义错（PG15+ 引入，多版本修过）
- `UPSERT` 的 `ON CONFLICT DO UPDATE` 与 RETURNING 顺序

## 3. 回归类（已修复又复发 / 与新版本不兼容）

**调查路径**:
```bash
git -C <src> log --oneline -- <file> | head -20
git -C <src> blame -L 100,150 <file>
git -C <src> log -S "<symbol_or_string>" --oneline
```

**触发点**:
- 改 `src/backend/optimizer/` 容易踩到老 query
- 改 `src/backend/commands/analyze.c` 影响统计信息
- 改 `src/backend/storage/lmgr/` 影响锁行为

## 4. 资源/并发类

**日志关键词**:
- `deadlock detected` — 抓 `pg_locks` 全量快照
- `out of memory` / `out of shared memory` — `vmstat 1` 同步
- `canceling statement due to lock timeout` — `pg_locks` join `pg_stat_activity`
- `cannot allocate memory for ...` — 看 `overcommit_memory`、`vm.overcommit_ratio`
- `too many clients already` — `max_connections`、连接池泄漏

**复现条件**:
- 并发度（用 `pgbench -c N -j M`）
- 长时间运行（`pg_sleep`、批量 INSERT）
- 跨节点（replication / logical replication / BDR）

## 5. 文档/协议违反类

PG 是严格 spec 兼容的数据库。常见违反：
- SQL 标准语法不支持
- wire protocol 偏差
- `pg_dump` / `pg_upgrade` 跨大版本不兼容

这种情况不是 bug 是 feature，要先确认。
