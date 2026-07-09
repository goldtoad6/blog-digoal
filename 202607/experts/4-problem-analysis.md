# 四、PostgreSQL 问题分析

> 本章在 `/Users/digoal/new/tmp1/20260708_05.md` 第五章「问题分析：从“为什么”反推机制」的 9 个问题骨架基础上扩展：OFFSET、膨胀、STANDBY 延迟、雪崩、FREEZE、GIN、BRIN、执行计划、批量 push/pull。第三章偏「定位与止血」，本章偏「机制与反证」：看到现象时，先问它由哪个内核对象、哪条链路、哪个 horizon 或哪个 cost 模型推导出来。

本章默认 PostgreSQL 14-17 的行为；不同版本的视图字段、等待事件命名可能略有差异，所有 SQL 都应先在测试库验证。

## 4.0 本章读法：现象不是根因，机制才是根因

PostgreSQL 的常见问题大多不是「数据库玄学」，而是几个基础机制反复组合：

- **MVCC**：一个逻辑行可能有多个物理版本；可见性由 `xmin/xmax` 与快照判断。
- **Buffer / Page**：表、索引、WAL 最终都是页；页是否在 shared buffer、是否 all-visible、是否脏，决定 IO 路径。
- **WAL / LSN**：写入先落 WAL；复制、崩溃恢复、逻辑解码都按 LSN 推进。
- **Lock / LWLock / Pin**：SQL 锁、行锁、轻量锁、buffer pin 不是一类东西，等待事件不同，处理方法也不同。
- **Planner**：执行计划不是「智能判断」，而是统计信息 + 代价参数 + 枚举搜索空间的结果。

建议每个问题都按这 5 个问题反推：

1. **机制是什么**：底层数据结构或流程是什么。
2. **前置条件是什么**：什么情况下这个机制会主导性能。
3. **边界是什么**：什么情况下这个解释不成立。
4. **怎么观测**：用哪个视图、字段、EXPLAIN 节点看到它。
5. **怎么证伪**：做一个最小实验，让它变好或不变好。

---

## 4.1 为什么 OFFSET 大就慢：Limit 节点只能丢弃，不能按序号跳页

`LIMIT 20 OFFSET 1000000` 的直觉是「跳过前 100 万行」，但执行器并没有「按结果集序号跳到第 1000001 行」这个原语。PostgreSQL 的执行计划是迭代器模型：父节点不断向子节点要 tuple。`Limit` 节点要返回第 `OFFSET + LIMIT` 个结果之前，必须先从子节点消费并丢弃前 `OFFSET` 个可见、满足条件、排序后的位置。

### 机制

- 如果 `ORDER BY` 没有可用索引，子节点通常要扫描候选集并排序。即使用 top-N sort，N 也是 `OFFSET + LIMIT`，不是单纯的 `LIMIT`。
- 如果 `ORDER BY` 正好能走 B-Tree 顺序扫描，排序可以省掉，但仍要顺着索引读出前 `OFFSET + LIMIT` 个索引项，并对它们做 MVCC 可见性判断、过滤条件检查，必要时回表。
- B-Tree 能按 key 定位，例如 `id > 1000000`；不能按「第 1000000 个可见结果」定位，因为可见性取决于当前快照，索引页上也没有每个快照下的可见行计数。

### 前置条件

- `OFFSET` 远大于 `LIMIT`。
- 排序键不能转化为 keyset 条件，或者应用层坚持按页码跳页。
- 子节点需要排序、过滤、回表，或者可见性检查代价较高。

### 边界：什么时候不明显慢

- 表很小，全部在缓存中。
- `OFFSET` 很小。
- 结果集预先物化并带有行号，且查询命中物化结果。
- 使用同一个 server-side cursor 顺序拉取时，第一次仍要推进到当前位置，但后续 `FETCH` 不会反复从头排序；这不是 OFFSET 本身变快，而是复用了 portal 状态。

### 观测手段

看 `EXPLAIN (ANALYZE, BUFFERS)`：

- `Limit` 节点输出 20 行，但它的子节点 `actual rows` 接近 `OFFSET + LIMIT`。
- 如果有 `Sort`，看 `Sort Method` 是否 external merge、是否写临时文件。
- 如果走 Index Scan，看 `Buffers` 和 `Heap Fetches` 是否随 offset 线性增加。

### 证伪手段

改成 keyset 分页：用上次看到的排序键作为下一页条件。如果耗时从随页码线性增长变成稳定，就证明慢点来自 OFFSET 丢弃。

### 自检 SQL

```sql
CREATE TEMP TABLE t_offset AS
SELECT i AS id, md5(i::text) AS payload
FROM generate_series(1, 300000) AS s(i);
CREATE INDEX ON t_offset(id);
ANALYZE t_offset;

-- 需要读出并丢弃 200000 行。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM t_offset ORDER BY id LIMIT 20 OFFSET 200000;

-- keyset：直接从 key 定位，子节点只需要返回约 20 行。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM t_offset WHERE id > 200000 ORDER BY id LIMIT 20;
```

---

## 4.2 为什么表和索引会膨胀：MVCC 版本留下空洞，vacuum 只能在 horizon 之后清理

![MVCC 版本链与膨胀形成机制](../svg/4-problem-mvcc-bloat.svg)

PostgreSQL 的 UPDATE 不是原地覆盖，而是插入一个新 tuple 版本，再把旧版本的 `xmax` 标记为删除它的事务。DELETE 也是标记死亡，不是立即从文件中抹掉。这个设计换来读写不互相阻塞，但代价是旧版本必须等到所有可能看到它的快照都结束后才能回收。

### 机制

Heap tuple 头部包含 `xmin`、`xmax`、`ctid`、infomask 等字段。可见性判断大致是：

- `xmin` 对当前快照已提交，且不是未来事务；
- `xmax` 为空，或删除事务对当前快照不可见；
- 否则该版本不可见。

`VACUUM` 的核心不是压缩文件，而是：

1. 找出对所有活跃快照都不可见的 dead tuple。
2. 清理 heap 页上的 dead line pointer，或将空间加入 FSM 供后续 INSERT/UPDATE 复用。
3. 清理索引中指向 dead tuple 的索引项。
4. 可能推进 `relfrozenxid` 与 visibility map。

如果旧快照、长事务、prepared transaction、复制 slot、`hot_standby_feedback` 把 `OldestXmin` 固定在很老的位置，vacuum 即使运行也不能清理较新的 dead tuple。

索引膨胀还要再加一层：B-Tree 页分裂后形成的页一般不会因为删除而自动把文件缩回去。PG 12 以后 B-Tree 有 bottom-up deletion、dedup 等改进，但它们仍主要是复用页内空间，不等价于 `REINDEX` 那种重建紧凑结构。

### 前置条件

- 表上有大量 UPDATE/DELETE，尤其是非 HOT UPDATE。
- autovacuum 触发太晚：大表默认 `autovacuum_vacuum_scale_factor = 0.2` 可能意味着修改数达到几千万才触发。
- vacuum 跑得太慢：worker 少、cost delay 大、`maintenance_work_mem` 小、IO 被业务压满。
- horizon 被钉住：长事务、长 2PC、逻辑 slot、物理备库 feedback。

### 边界：什么时候不是膨胀问题

- `n_dead_tup` 高但刚刚产生，autovacuum 还没到触发时间。
- `VACUUM` 后 dead tuple 下降，但文件大小不变，这是高水位和 FSM 复用问题，不代表 vacuum 失败。
- 表大小增长来自真实 live tuple 增长，不是 bloat。
- 索引大于表不必然异常：宽索引、多列索引、低基数重复值、表达式索引都可能让索引天然很大。

### 观测手段

- `pg_stat_user_tables.n_dead_tup`：估算 dead tuple 数。
- `pg_stat_progress_vacuum`：vacuum 正在哪个阶段。
- `pg_stat_activity.backend_xmin`：谁持有旧快照。
- `pg_replication_slots.xmin/catalog_xmin`：slot 是否钉住 horizon。
- `pgstattuple`：更接近真实的 dead/free/bloat 估算。

### 证伪手段

- 结束长事务后手动 `VACUUM (VERBOSE)`，若 dead tuple 明显下降，说明 horizon 是关键。
- `VACUUM` 后表大小不降但 `free_percent` 上升，说明空间已可复用，不是继续堆积。
- `REINDEX CONCURRENTLY` 后索引体积显著下降，说明主要是索引膨胀；若不降，说明索引大是数据形态导致。

### 自检 SQL

```sql
-- 1. 找 dead tuple 和事务年龄。
SELECT schemaname, relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 2) AS dead_pct,
       last_autovacuum, last_vacuum,
       age(relfrozenxid) AS xid_age
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC
LIMIT 20;

-- 2. 找钉住 OldestXmin 的会话。
SELECT pid, usename, state,
       now() - xact_start AS xact_age,
       backend_xmin, query
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY backend_xmin NULLS LAST, xact_start;

-- 3. 找复制 slot 是否阻止清理。
SELECT slot_name, slot_type, active, xmin, catalog_xmin,
       restart_lsn, confirmed_flush_lsn
FROM pg_replication_slots;

-- 4. 可选：需要扩展权限。
CREATE EXTENSION IF NOT EXISTS pgstattuple;
SELECT * FROM pgstattuple('your_schema.your_table');
```

---

## 4.3 为什么 STANDBY 有延迟：send、flush、replay、xmin horizon 是四个不同问题

![物理复制延迟分解](../svg/4-problem-replication-lag.svg)

主备延迟不能只看一个 `lag`。物理复制从主库 WAL 产生到备库查询可见，至少经过：主库写 WAL、walsender 发送、备库 walreceiver 写入、flush 到备库磁盘、startup 进程 replay 到数据文件。每一段慢，症状和处理都不一样。

### 机制

- **send lag**：主库 WAL 产生速率超过网络发送速率，或 walsender 被 CPU/网络限制。
- **write lag**：备库 walreceiver 已收到，但写入 OS cache 慢。
- **flush lag**：备库将 WAL fsync 到持久介质慢。
- **replay lag**：WAL 已在备库，redo 应用到数据文件慢，或被 hot standby 查询冲突阻塞。

`hot_standby_feedback = on` 会让备库把自己的最老 xmin 反馈给主库，主库因此保留对备库查询仍可见的旧版本。这能减少备库查询被取消，但会让主库 vacuum 无法清理 dead tuple，也可能间接放大 WAL、膨胀和 replay 压力。

复制 slot 还会引入另一个保留条件：消费者没有确认到的 WAL 不能删除。slot 卡死时，主库 `pg_wal` 会持续增长。

### 前置条件

- WAL 产生速率高于备库接收、写入、flush 或 replay 能力。
- 备库有长查询，redo 与查询发生冲突。
- 使用了 replication slot 或 `hot_standby_feedback`。
- 同步复制下，提交路径还可能等待 standby write/flush/apply。

### 边界：什么时候不能只看时间 lag

- 主库长时间没有事务提交时，`pg_last_xact_replay_timestamp()` 会显示旧时间，但这不一定是延迟。
- `write_lag/flush_lag/replay_lag` 在追平时可能是 NULL，不代表断链。
- 字节 lag 大但 replay 很快，可能只是短时批量写入；时间 lag 大才影响读一致性。

### 观测手段

- 主库：`pg_stat_replication` 的 `sent_lsn/write_lsn/flush_lsn/replay_lsn`。
- 备库：`pg_last_wal_receive_lsn()`、`pg_last_wal_replay_lsn()`。
- slot：`pg_replication_slots.restart_lsn` 与 `pg_current_wal_lsn()` 差值。
- 等待事件：主库 `WALWrite/WALSync`、备库 `DataFileWrite/DataFileSync`、客户端等待。

### 证伪手段

- 如果 `sent_lsn - write_lsn` 大，换网络或限流 WAL 产生速率后改善，证明是 send 链路。
- 如果 `write_lsn` 接近 `sent_lsn` 但 `flush_lsn` 落后，换备库盘或降低同步级别后改善，证明是 flush。
- 如果 `flush_lsn` 接近但 `replay_lsn` 落后，取消备库长查询或调大备机 IO 后改善，证明是 replay。
- 关闭 `hot_standby_feedback` 后主库 dead tuple 不再堆积，但备库查询开始被取消，说明 feedback 是 horizon 根因。

### 自检 SQL

```sql
-- 主库：分解发送、写入、flush、replay 差距。
SELECT application_name, client_addr, state, sync_state,
       pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn))  AS send_to_write,
       pg_size_pretty(pg_wal_lsn_diff(write_lsn, flush_lsn)) AS write_to_flush,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)) AS flush_to_replay,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- 备库：接收与回放 LSN。
SELECT pg_last_wal_receive_lsn() AS receive_lsn,
       pg_last_wal_replay_lsn()  AS replay_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(), pg_last_wal_replay_lsn())) AS byte_gap,
       now() - pg_last_xact_replay_timestamp() AS time_since_last_replay;

-- 主库：slot 保留了多少 WAL。
SELECT slot_name, slot_type, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       xmin, catalog_xmin
FROM pg_replication_slots
WHERE restart_lsn IS NOT NULL;
```

---

## 4.4 为什么会雪崩：锁队列、DDL 强锁、热点行把局部等待放大成全局等待

![锁队列导致雪崩](../svg/4-problem-lock-avalanche.svg)

雪崩的核心不是「某条 SQL 慢」，而是「等待会占住连接和锁队列位置」。一个后台连接等锁时，它仍占用应用连接池、数据库 backend、事务上下文；业务层重试会继续制造等待者。最终局部锁冲突变成连接池耗尽、请求排队、超时重试的放大回路。

### 机制

PostgreSQL 有多类锁：

- **Heavyweight lock**：表锁、事务锁、DDL 锁，可在 `pg_locks` 看到。
- **Tuple lock**：行级冲突，常表现为 `Lock:tuple` 或 `Lock:transactionid`。
- **LWLock**：共享内存结构保护锁，例如 buffer mapping、WAL insert，不是 SQL 层锁。
- **Buffer pin**：某个 backend 正在使用 buffer，其他进程不能清理或改动该 buffer。

典型雪崩链路：

1. 长 SELECT 持有 `AccessShareLock`。
2. DDL 请求 `AccessExclusiveLock`，被 SELECT 阻塞。
3. 后续读写即使本来与 SELECT 兼容，也可能排在等待的强锁之后。
4. 连接池 worker 被等待占满，业务重试继续放大。

热点行是另一条链路：所有事务更新同一行，后来的事务必须等前一个事务提交或回滚。行锁等待本身不会自动失败，除非设置 `lock_timeout` 或应用层超时。

### 前置条件

- DDL 没有设置 `lock_timeout`。
- 长事务或慢查询持锁时间过长。
- 热点行设计，例如全局计数器、单库存行、单账户余额行。
- 应用连接池没有排队保护和重试退避。

### 边界：什么时候不是锁雪崩

- `state = active` 且 `wait_event IS NULL`，大概率是 CPU 在跑，不是锁等待。
- 等待事件是 `IO:DataFileRead`，根因在 IO。
- `LWLock` 主导时，不一定能用 `pg_blocking_pids()` 找到 SQL 阻塞者，因为它不是 heavyweight lock。

### 观测手段

- `pg_blocking_pids(pid)`：直接看阻塞链。
- `pg_locks`：看 lock mode、granted、relation、transactionid。
- `pg_stat_activity.wait_event_type`：区分 Lock、LWLock、IO、Client。
- 日志：`log_lock_waits = on`，配合 `deadlock_timeout`。

### 证伪手段

- 给 DDL 包一层 `SET LOCAL lock_timeout='100ms'`，如果雪崩不再出现，说明强锁排队是触发器。
- 将热点行拆分为分片计数器或队列消费 `FOR UPDATE SKIP LOCKED`，如果等待消失，说明是行锁串行化。
- 如果杀掉 blocking pid 后所有等待瞬间消失，锁链成立；如果不消失，转向 IO/LWLock/客户端等待。

### 自检 SQL

```sql
-- 当前谁被谁阻塞。
SELECT a.pid AS blocked_pid,
       a.usename,
       a.wait_event_type,
       a.wait_event,
       now() - a.query_start AS blocked_for,
       pg_blocking_pids(a.pid) AS blocking_pids,
       a.query AS blocked_query
FROM pg_stat_activity AS a
WHERE cardinality(pg_blocking_pids(a.pid)) > 0
ORDER BY blocked_for DESC;

-- 锁队列明细。
SELECT l.pid, a.state, l.locktype, l.mode, l.granted,
       l.relation::regclass AS relation,
       l.transactionid,
       now() - a.query_start AS age,
       a.query
FROM pg_locks AS l
JOIN pg_stat_activity AS a USING (pid)
ORDER BY l.granted, age DESC;

-- DDL 防雪崩写法。
BEGIN;
SET LOCAL lock_timeout = '100ms';
-- ALTER TABLE your_table ADD COLUMN ...;
COMMIT;
```

---

## 4.5 为什么需要 FREEZE：32-bit XID 回卷会颠倒“过去”和“未来”

![XID 回卷与 FREEZE 保护机制](../svg/4-problem-xid-wraparound.svg)

PostgreSQL 的普通事务号 XID 是 32 位，约 42.9 亿个，会循环使用。MVCC 可见性依赖事务号的相对新旧，如果一个非常老的 tuple 没有被 freeze，等 XID 绕回后，它可能被误判成「未来事务产生的 tuple」，可见性就会颠倒。FREEZE 的意义是把足够老的 tuple 标记成「对所有正常事务都已经提交且永远很老」。

### 机制

每张表有 `relfrozenxid`，表示这张表中所有早于该 XID 的普通 tuple 都已经不再需要查询 `pg_xact` 判断提交状态。数据库级别的 `datfrozenxid` 是库内表的下界。`VACUUM FREEZE` 会扫描 tuple，把足够老的 `xmin` 标记为 frozen，并推进 `relfrozenxid`。

如果 `age(datfrozenxid)` 持续增长，接近 `autovacuum_freeze_max_age`，系统会触发 anti-wraparound vacuum。这个 vacuum 即使表上禁用了 autovacuum 也会尽力运行，因为这是数据安全边界，不是普通维护任务。

### 前置条件

- 事务量大，XID 消耗快。
- 表很少被 vacuum，或者长事务阻止 vacuum 推进 freeze horizon。
- 大表 freeze 代价高，导致一直扫不完。
- 频繁创建 MultiXact 的工作负载还要关注 `relminmxid/datminmxid`。

### 边界：什么时候 age 高但不一定危险

- 大批量只读查询通常不分配 XID；看的是写事务消耗速度。
- age 接近触发阈值不等于马上停库，但说明系统将强制把资源倾向 vacuum。
- 临时表、unlogged 表、分区父表的语义要分开看，真正压力常在活跃分区。

### 观测手段

- `age(datfrozenxid)`：数据库级风险。
- `age(relfrozenxid)`：表级风险。
- `pg_stat_progress_vacuum`：是否正在 anti-wraparound vacuum。
- `pg_settings`：`autovacuum_freeze_max_age`、`vacuum_freeze_table_age`、`vacuum_failsafe_age`。

### 证伪手段

- 手动对最老表执行 `VACUUM (FREEZE, VERBOSE)`，如果 `age(relfrozenxid)` 大幅下降，说明 freeze 是主因。
- 如果 age 不下降，通常是还有旧快照、2PC、slot 或访问不到的表阻止推进。
- 如果 IO 风暴期间 `pg_stat_progress_vacuum` 显示 anti-wraparound vacuum，说明不是业务 SQL 突然变多，而是 XID 防线触发。

### 自检 SQL

```sql
-- 数据库级 XID / MultiXact 年龄。
SELECT datname,
       age(datfrozenxid) AS xid_age,
       age(datminmxid)   AS mxid_age
FROM pg_database
ORDER BY xid_age DESC;

-- 表级最危险对象。
SELECT c.oid::regclass AS rel,
       age(c.relfrozenxid) AS xid_age,
       age(c.relminmxid)   AS mxid_age,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
FROM pg_class AS c
JOIN pg_namespace AS n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm', 't')
  AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY xid_age DESC
LIMIT 20;

-- freeze 相关阈值。
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('autovacuum_freeze_max_age',
               'vacuum_freeze_table_age',
               'vacuum_failsafe_age',
               'autovacuum_multixact_freeze_max_age');
```

---

## 4.6 为什么 GIN 有时不快：pending list 把写入成本推迟到了查询或合并时

![GIN pending list 合并机制](../svg/4-problem-gin-pending-list.svg)

GIN 是倒排索引：一个 key 对应一组 TID。它适合 `jsonb`、数组、全文检索这类「一个值拆成多个 key」的检索。但倒排索引的写入天然重：一行更新可能对应多个 key 的 posting list 更新。为降低写入延迟，GIN 默认 `fastupdate = on`，先把变更放进 pending list，之后再批量合并到主索引。

### 机制

查询 GIN 时不是只查主索引，还要检查 pending list。pending list 小时问题不大；pending list 大时，查询要额外扫描大量未合并条目。更糟的是，当 pending list 达到 `gin_pending_list_limit`，某次 INSERT/UPDATE 或 VACUUM 会触发 cleanup，把延迟集中支付，形成 RT 尖刺。

### 前置条件

- GIN 索引处于高写入、高更新场景。
- autovacuum 不及时，pending list 长时间不合并。
- `gin_pending_list_limit` 设置过大，单次合并成本高。
- 查询条件选择性不高，需要访问大量 posting list 并回表重检。

### 边界：什么时候不是 pending list

- `n_pending_pages` 很小，查询仍慢，说明慢点可能是低选择性、recheck 多、返回行太多或 operator class 不合适。
- `fastupdate = off` 时没有 pending list 快路径，写入变慢但查询抖动可能更小。
- GIN 不负责排序；如果查询还要 `ORDER BY ts LIMIT`，可能需要另一个索引或 RUM 扩展。

### 观测手段

- `pageinspect.gin_metapage_info()` 看 `n_pending_pages/n_pending_tuples`。
- `pg_stat_user_indexes.idx_scan/idx_tup_read/idx_tup_fetch` 看读放大。
- `EXPLAIN (ANALYZE, BUFFERS)` 看 Bitmap Index Scan、Bitmap Heap Scan、Recheck Cond。
- autovacuum 日志看是否频繁清理 GIN。

### 证伪手段

- 手动 `VACUUM` 后 pending list 下降且查询稳定，证明 pending list 是主因。
- 对写多读少表把 `fastupdate=off` 做 A/B，若写延迟上升但查询尖刺消失，说明成本转移成立。
- 改 operator class 或加更高选择性过滤条件后仍慢，才考虑 GIN 本身不适合。

### 自检 SQL

```sql
-- 需要 superuser 或足够权限。
CREATE EXTENSION IF NOT EXISTS pageinspect;

-- 查看 GIN metapage。把 idx_your_gin 换成真实 GIN 索引名。
SELECT *
FROM gin_metapage_info(get_raw_page('idx_your_gin', 0));

-- 看索引选项。
SELECT c.oid::regclass AS index_name, c.reloptions
FROM pg_class AS c
WHERE c.oid = 'idx_your_gin'::regclass;

-- 合并 pending list 的常用动作。
VACUUM (ANALYZE) your_table;
```

---

## 4.7 为什么 BRIN 有时不快：BRIN 只保存块范围摘要，物理顺序错了就只能大量 recheck

BRIN 不是小号 B-Tree。BRIN 的基本单位是 block range，例如每 128 个 heap page 记录一条摘要：这个范围内某列的最小值、最大值、是否有 null 等。查询时，BRIN 只能判断「哪些范围可能匹配」，然后把这些范围对应的 heap page 加入 lossy bitmap，再回表逐行 recheck。

### 机制

如果列值与物理插入顺序高度相关，例如时序表按 `created_at` 追加写入，则 `created_at BETWEEN t1 AND t2` 只命中少量连续范围，BRIN 极小且有效。反过来，如果数据随机写入，每个 block range 的 min/max 都覆盖很宽，几乎所有 range 都「可能匹配」，BRIN 就退化成大范围 heap 扫描 + recheck。

`pages_per_range` 是关键参数：

- 越大：索引越小，但摘要越粗，误判范围越大。
- 越小：索引稍大，但过滤更准，维护成本也更高。

### 前置条件

- 表很大，B-Tree 体积或维护成本不可接受。
- 查询列与 heap 物理顺序高度相关。
- 查询谓词是范围型，选择性较高。
- 新 range 已被 summarization，未汇总的 range 会降低效果。

### 边界：什么时候 BRIN 不合适

- OLTP 随机主键、随机时间回填、多租户混写导致物理顺序低相关。
- 查询返回表的很大比例，即使 BRIN 命中也要扫大量 heap。
- 等值高选择性点查通常 B-Tree 更合适。
- 多列任意组合查询不能指望单个 BRIN 解决。

### 观测手段

- `pg_stats.correlation`：接近 1 或 -1 表示物理顺序相关性高。
- `EXPLAIN`：看 `Bitmap Heap Scan`、`Rows Removed by Index Recheck`、lossy pages。
- `brin_summarize_new_values()`：检查新 range 是否需要汇总。
- 对比 `CLUSTER` 或重写有序表前后的计划。

### 证伪手段

- 将测试表按 BRIN 列重写或 `CLUSTER` 后，同样范围查询显著变快，说明原问题是物理顺序。
- 调小 `pages_per_range` 后误判下降，说明摘要粒度过粗。
- 如果有序后仍慢，说明选择性太低或谓词本身无法利用 BRIN。

### 自检 SQL

```sql
-- 看物理相关性。correlation 越接近 ±1，BRIN 越可能有效。
SELECT schemaname, tablename, attname, correlation
FROM pg_stats
WHERE schemaname = 'your_schema'
  AND tablename  = 'your_table'
  AND attname    = 'your_brin_column';

-- 检查执行计划中的 lossy/recheck。
EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM your_schema.your_table
WHERE your_brin_column >= now() - interval '1 day'
  AND your_brin_column <  now();

-- 对指定 BRIN 索引汇总新 range。
SELECT brin_summarize_new_values('idx_your_brin'::regclass);
```

---

## 4.8 为什么执行计划不正确：Planner 不是错觉机，它只是吃错了统计信息或代价参数

![规划器估算与实际执行偏差](../svg/4-problem-planner-estimate.svg)

执行计划「不正确」通常不是优化器随机犯错，而是输入信息不足：统计信息没有表达真实分布，代价参数不匹配硬件，或者 plan cache 复用了不适合当前参数的 generic plan。Planner 做的是：估算每个路径的行数和成本，在有限搜索空间内选成本最低的路径。

### 机制

优化器的行数估算依赖：

- `pg_class.reltuples/relpages`：表大小估算。
- `pg_statistic`：MCV、直方图、null fraction、ndistinct、相关性。
- 扩展统计：多列 dependencies、ndistinct、MCV。
- 代价参数：`seq_page_cost`、`random_page_cost`、`cpu_tuple_cost`、`effective_cache_size` 等。
- SQL 结构：JOIN 顺序、谓词是否可下推、函数 volatility、表达式是否匹配索引。

如果两列高度相关，但优化器按独立分布相乘，`WHERE province='Zhejiang' AND city='Hangzhou'` 的行数可能被低估几个数量级。低估会让 Nested Loop 看起来很便宜，实际却循环几十万次。

Prepared statement 还会引入 custom/generic plan 选择。generic plan 对所有参数共用，如果参数分布高度倾斜，就可能对大多数值还行、对少数值灾难。

### 前置条件

- 数据倾斜明显，或多列相关。
- bulk load 后没 ANALYZE，或 `n_mod_since_analyze` 很高。
- SSD/云盘仍使用机械盘时代的 `random_page_cost = 4`。
- SQL 使用 prepared statement，参数选择性差异巨大。
- JOIN 表很多，搜索空间被 `join_collapse_limit/geqo_threshold` 限制。

### 边界：什么时候不是 Planner 问题

- `rows` 估算与 `actual rows` 接近，但仍慢，多半是 IO、锁、CPU 或返回结果过大。
- 优化器选择 Seq Scan 不一定错：当返回表很大比例时，顺序扫比索引随机回表更快。
- 强行 hint/关闭某类 plan 得到更快结果，不代表全局都该这么改；只说明当前样本成立。

### 观测手段

- `EXPLAIN (ANALYZE, BUFFERS, SETTINGS)`：估算 vs 实际、buffer、实际生效参数。
- `pg_stat_user_tables.n_mod_since_analyze`：统计是否过期。
- `pg_stats` 与 `pg_stats_ext`：分布、相关性、扩展统计。
- `pg_stat_statements`：同一 queryid 的平均耗时与抖动。

### 证伪手段

- `ANALYZE` 后计划恢复，说明统计陈旧。
- `CREATE STATISTICS ... (dependencies, mcv)` 后行数估算改善，说明多列相关是根因。
- `SET plan_cache_mode = force_custom_plan` 后慢参数变快，说明 generic plan 不适合。
- 调整 `random_page_cost` 后只在 SSD 随机读场景变好，说明代价模型之前偏保守。

### 自检 SQL

```sql
-- 1. 看统计新鲜度。
SELECT schemaname, relname, last_analyze, last_autoanalyze,
       n_mod_since_analyze, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_mod_since_analyze DESC
LIMIT 20;

-- 2. 看实际计划与估算偏差。
EXPLAIN (ANALYZE, BUFFERS, SETTINGS)
SELECT * FROM your_table WHERE col1 = 'x' AND col2 = 'y';

-- 3. 多列相关场景：创建扩展统计后重新 ANALYZE。
CREATE STATISTICS st_your_table_col1_col2 (dependencies, mcv, ndistinct)
ON col1, col2 FROM your_table;
ANALYZE your_table;

-- 4. 验证 prepared statement generic plan 影响。
SET plan_cache_mode = force_custom_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE your_prepared_statement(...);
RESET plan_cache_mode;
```

---

## 4.9 为什么 push/pull 大量数据慢：协议往返、解析规划、fsync、文本编解码叠加

大量数据搬运慢，通常不是单点慢，而是每行或每批都在重复支付固定成本：网络 RTT、SQL 解析、计划生成、事务提交 fsync、索引维护、触发器、约束检查、文本格式编解码。

### 机制

PostgreSQL wire protocol 有 simple query 和 extended query 两类常用路径：

- **Simple query**：发送 SQL 字符串，服务端 parse/analyze/rewrite/plan/execute，适合一次性语句。
- **Extended query**：Parse/Bind/Describe/Execute/Sync 分阶段，支持 prepared statement、参数绑定、二进制格式，更适合重复执行。

写入侧最大的固定成本是提交：默认 `synchronous_commit = on` 时，事务提交通常要等待 WAL flush。单行一事务会把 fsync 成本放大 N 倍；批量提交可利用 group commit。`COPY` 又进一步减少每行 SQL 解析、协议消息和 executor 启动成本。

读取侧慢常见于：一次拉取巨大结果集、客户端消费慢导致 `ClientWrite`、文本格式转 JSON/CSV、网络 RTT 高但 fetch size 太小。

### 前置条件

- 应用逐行 INSERT/UPDATE/SELECT，而不是批量。
- 高 RTT 网络，或跨地域访问数据库。
- 每行都有索引、外键、触发器、逻辑复制等额外写放大。
- 客户端使用文本协议并做大量类型转换。

### 边界：什么时候 COPY 也救不了

- 触发器或外键检查本身是主成本。
- 目标表索引过多，写入主要慢在索引维护。
- 同步复制配置为 remote_apply，提交必须等备库 replay。
- 客户端处理速度低于数据库发送速度，瓶颈在客户端。

### 观测手段

- `pg_stat_statements`：`mean_plan_time`、`mean_exec_time`、`wal_bytes`。
- `pg_stat_wal`：WAL records、bytes、sync 次数与时间。
- `pg_stat_activity.wait_event_type = Client`：客户端读写慢。
- `wait_event = WALWrite/WALSync`：提交刷 WAL 慢。

### 证伪手段

- 单行事务改成每 1000 行提交一次，如果 TPS 数量级提升，fsync/事务固定成本成立。
- INSERT 改 COPY 后吞吐提升，说明协议和 executor per-row 成本占主导。
- 本机连接快、跨地域慢，说明 RTT/网络是主因。
- 去掉非必要索引或先装载后建索引显著提升，说明索引维护是主因。

### 自检 SQL

```sql
-- 1. 看哪些 SQL 产生 WAL 多、计划时间多。需要 pg_stat_statements。
SELECT queryid, calls,
       round(mean_plan_time::numeric, 3) AS mean_plan_ms,
       round(mean_exec_time::numeric, 3) AS mean_exec_ms,
       wal_bytes,
       left(query, 120) AS sample_sql
FROM pg_stat_statements
ORDER BY wal_bytes DESC
LIMIT 20;

-- 2. 看 WAL 写入与同步压力。
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes,
       wal_buffers_full, wal_write, wal_sync,
       wal_write_time, wal_sync_time
FROM pg_stat_wal;

-- 3. 看是否在等客户端或 WAL。
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
GROUP BY 1, 2
ORDER BY count(*) DESC;
```

---

## 4.10 为什么 count(*) 会扫表：MVCC 下没有一个对所有快照都正确的全局行数

MySQL 某些引擎或分析型数据库可能维护精确行数，但 PostgreSQL heap 表不能简单返回元数据里的行数。原因是 MVCC：同一时刻不同事务的快照可能看到不同数量的行。一个全局 counter 无法同时满足所有快照。

### 机制

`count(*)` 的语义是「当前快照下满足条件的可见行数」。因此 PostgreSQL 必须检查可见性：

- Seq Scan：逐 heap tuple 判断可见性并计数。
- Index Only Scan：扫描索引项；如果 heap page 的 visibility map 标记为 all-visible，可以不回表，否则仍要访问 heap 判断可见性。
- 估算值：`pg_class.reltuples` 只是 ANALYZE/VACUUM 维护的估算，不满足精确 `count(*)` 语义。

### 前置条件

- 要求精确计数。
- 表较大，谓词选择性不高。
- visibility map 覆盖率低，index-only scan 仍需 heap fetch。

### 边界：什么时候 count 可以快

- `WHERE` 条件高度选择性，并能走小范围索引。
- 表很小或全在缓存。
- 允许近似值：使用 `reltuples`、采样、物化计数、增量汇总。
- 分区表按分区元数据或业务维度维护汇总。

### 观测手段

- `EXPLAIN (ANALYZE, BUFFERS)` 看 Seq Scan / Index Only Scan / Heap Fetches。
- `pg_class.reltuples` 看估算值。
- `pg_visibility` 或 `pg_stat_all_tables` 看 all-visible 情况。

### 证伪手段

- `VACUUM` 后 Index Only Scan 的 `Heap Fetches` 下降，说明之前慢在可见性回表。
- 改用估算值瞬间返回但与精确 count 有误差，说明精确语义才是成本来源。
- 加高选择性条件后 count 变快，说明不是 count 函数慢，而是扫描范围大。

### 自检 SQL

```sql
-- 精确 count 的执行路径。
EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*) FROM your_table;

-- 估算行数：快，但不是精确 count。
SELECT reltuples::bigint AS estimated_rows,
       relpages
FROM pg_class
WHERE oid = 'your_table'::regclass;

-- 可选：看 visibility map 覆盖率。
CREATE EXTENSION IF NOT EXISTS pg_visibility;
SELECT * FROM pg_visibility_map_summary('your_table'::regclass);
```

---

## 4.11 为什么 LIMIT 不一定能止住大扫描：LIMIT 只截断上层输出，不能穿透阻塞型节点

`LIMIT 10` 只保证最终最多返回 10 行，不保证底层只处理 10 行。执行计划中有些节点是 streaming 的，能边读边吐；有些节点是 blocking 的，必须先读完大量输入才能产生第一行。

### 机制

常见 blocking 或半 blocking 节点：

- `Sort`：无可用索引排序时，必须看完候选输入才能确定前 10。top-N heapsort 也要扫描全部候选来比较。
- `Hash Join`：build side 通常要先完整建 hash table。
- `HashAggregate`：要看完整个分组输入。
- `WindowAgg`：很多窗口函数要处理完整分区。
- `Materialize/CTE`：可能先物化子查询。
- `Gather Merge`：并行 worker 的输出还要合并排序。

### 前置条件

- `LIMIT` 上方有 `ORDER BY`、聚合、窗口函数、DISTINCT、复杂 JOIN。
- 排序键没有匹配索引。
- 谓词选择性低，候选集很大。

### 边界：什么时候 LIMIT 真能快

- `ORDER BY` 与索引顺序一致，Index Scan 可在返回 N 行后停止。
- WHERE 条件高度选择性，扫描很快命中足够行。
- Nested Loop 的外层带 LIMIT，且内层成本受控。

### 观测手段

`EXPLAIN ANALYZE` 看每个子节点的 `actual rows`：如果 Limit 输出 10 行，Sort/Seq Scan/HashAggregate 却处理百万行，说明 LIMIT 没能下推到底层。

### 证伪手段

- 增加匹配 `WHERE + ORDER BY` 的复合索引，若计划从 Sort + Seq Scan 变为 Index Scan 且子节点 rows 接近 LIMIT，证明阻塞节点是根因。
- 去掉 ORDER BY 后变快，说明排序是主因；不变则看 JOIN/聚合。

### 自检 SQL

```sql
-- LIMIT 10 仍可能扫描全表，因为 ORDER BY random() 必须给所有候选行算 random。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM your_table
ORDER BY random()
LIMIT 10;

-- 看 Limit 下方节点 actual rows 是否远大于 10。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM your_table
ORDER BY non_indexed_column
LIMIT 10;

-- 证伪方向：创建匹配排序的索引后对比。
-- CREATE INDEX ON your_table(non_indexed_column);
```

---

## 4.12 为什么 Index Only Scan 还是会回表：索引没有保存“对当前快照可见”这个事实

Index Only Scan 的名字容易误导：它不是永远只读索引，而是「在 heap page 被标记为 all-visible 时可以不回表」。PostgreSQL 的普通 B-Tree 索引项保存 key 和 TID，不保存每个事务快照下的可见性。

### 机制

Visibility Map 为每个 heap page 保存两个重要 bit：

- **all-visible**：这个 page 上所有 tuple 对所有当前和未来事务都可见。
- **all-frozen**：这个 page 上 tuple 已足够 freeze。

Index Only Scan 扫到索引项后：

1. 检查对应 heap page 的 all-visible bit。
2. 如果 bit 已置位，可以直接从索引返回列值。
3. 如果 bit 未置位，必须访问 heap tuple 做 MVCC 可见性判断。

UPDATE/DELETE/INSERT 会清除相关 page 的 all-visible bit；VACUUM 扫描确认后才会重新置位。因此写入活跃表即使有 covering index，也可能频繁 heap fetch。

### 前置条件

- 查询列都在索引中，计划选择 Index Only Scan。
- 表近期有写入，visibility map 覆盖率低。
- autovacuum 没及时重新设置 all-visible。

### 边界：什么时候真正只读索引

- 只读或追加后及时 vacuum 的历史表。
- 查询命中的 heap pages 基本 all-visible。
- 索引包含所有需要返回和过滤的列，且表达式完全匹配。

### 观测手段

- `EXPLAIN (ANALYZE, BUFFERS)` 中 `Heap Fetches`。
- `pg_visibility_map_summary()` 看 all-visible page 数。
- `pg_stat_user_tables.last_autovacuum` 与写入计数。

### 证伪手段

- 对表执行 `VACUUM (ANALYZE)` 后，`Heap Fetches` 明显下降，说明慢在 visibility map。
- 如果 VACUUM 后仍大量 Heap Fetches，说明表持续写入或索引不覆盖。
- 如果计划根本不是 Index Only Scan，说明索引列、表达式或代价模型不匹配。

### 自检 SQL

```sql
-- 看 Index Only Scan 是否仍回表。
EXPLAIN (ANALYZE, BUFFERS)
SELECT indexed_col
FROM your_table
WHERE indexed_col BETWEEN 100 AND 200;

-- VACUUM 后重跑，看 Heap Fetches 是否下降。
VACUUM (ANALYZE) your_table;
EXPLAIN (ANALYZE, BUFFERS)
SELECT indexed_col
FROM your_table
WHERE indexed_col BETWEEN 100 AND 200;

-- 可选：visibility map 覆盖率。
CREATE EXTENSION IF NOT EXISTS pg_visibility;
SELECT * FROM pg_visibility_map_summary('your_table'::regclass);
```

---

## 4.13 为什么 partial index 有时候不用：Planner 必须证明查询谓词蕴含索引谓词

Partial index 只覆盖满足谓词的一部分行，例如 `WHERE status = 'active'`。它能显著降低索引体积和维护成本，但 Planner 只有在能证明查询条件一定落在这部分行内时，才允许使用它。否则使用 partial index 会漏行。

### 机制

索引谓词是一个逻辑约束：

```sql
CREATE INDEX ON users(id) WHERE status = 'active';
```

查询要使用它，Planner 需要证明：

```text
query WHERE  条件  =>  index predicate
```

PostgreSQL 的证明能力不是完整定理证明器，更多依赖表达式形态匹配和少量简单推理。以下情况经常失败：

- 查询没有写出 `status = 'active'`。
- 条件被函数、隐式类型转换、collation、表达式包装改变了形态。
- prepared statement 使用参数：generic plan 阶段不知道 `$1` 一定是 `'active'`。
- 谓词写法与索引谓词不等价或无法被识别为等价。

### 前置条件

- partial index 谓词足够选择性高。
- 查询条件稳定、可字面匹配谓词。
- SQL 模板不会把关键谓词参数化成 generic plan 无法证明的形式。

### 边界：什么时候不用 partial index 是对的

- 查询确实可能访问 predicate 外的数据。
- partial index 覆盖比例太高，Seq Scan 或普通索引更便宜。
- 统计信息显示 active 行很多，partial index 不再有优势。

### 观测手段

- `pg_indexes.indexdef` 查看 partial index 谓词。
- `EXPLAIN` 看是否出现该索引名。
- `plan_cache_mode` 对比 generic/custom plan。

### 证伪手段

- 把查询改成字面量 `status = 'active'` 后使用索引，说明原 SQL 无法证明谓词。
- `SET plan_cache_mode = force_custom_plan` 后使用索引，说明 generic plan 是根因。
- `ANALYZE` 后仍不用，且强制关闭 seqscan 后反而更慢，说明 Planner 不用是正确选择。

### 自检 SQL

```sql
CREATE TEMP TABLE t_pi(id int, status text, payload text);
INSERT INTO t_pi
SELECT i,
       CASE WHEN i % 100 = 0 THEN 'active' ELSE 'inactive' END,
       md5(i::text)
FROM generate_series(1, 100000) AS s(i);
CREATE INDEX t_pi_active_idx ON t_pi(id) WHERE status = 'active';
ANALYZE t_pi;

-- 字面谓词：通常能证明并使用 partial index。
EXPLAIN (ANALYZE, BUFFERS)
SELECT * FROM t_pi WHERE status = 'active' AND id = 1000;

-- generic plan：Planner 不知道 $1 恒等于 active。
PREPARE q_pi(text, int) AS
SELECT * FROM t_pi WHERE status = $1 AND id = $2;
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE q_pi('active', 1000);
SET plan_cache_mode = force_custom_plan;
EXPLAIN (ANALYZE, BUFFERS) EXECUTE q_pi('active', 1000);
RESET plan_cache_mode;
```

---

## 4.14 为什么 checkpoint 突然变慢：脏页、WAL 边界与 full page writes 一起形成写入波峰

![pg_wal 滚动、checkpoint 与保留条件](../svg/4-problem-wal-checkpoint.svg)

Checkpoint 是把「到某个 LSN 为止的数据页修改」推进到持久化边界。它不是简单写一个标记，而是要把一批脏 buffer 写到数据文件并 fsync。checkpoint 过于频繁或过于集中，就会形成 IO 波峰。

### 机制

- 后端修改数据页前写 WAL；数据页可以稍后由 background writer、checkpointer 或 backend 写盘。
- checkpoint 开始后，checkpointer 尽量在 `checkpoint_completion_target * checkpoint_timeout` 窗口内平滑写脏页。
- 如果 `max_wal_size` 太小，WAL 增长触发 requested checkpoint，写入会更频繁。
- checkpoint 后每个数据页第一次修改需要 full page image（`full_page_writes=on`），短时间内会增加 WAL 量。

### 前置条件

- 写入突增，shared buffers 中脏页很多。
- `max_wal_size` 太小，`checkpoints_req` 明显多于 timed checkpoint。
- 存储 fsync 延迟高。
- 大批量写入后手动 `CHECKPOINT` 或系统被迫 checkpoint。

### 边界：什么时候不是 checkpoint

- 等待事件主要是 `DataFileRead`，是读 IO。
- `checkpoints_req` 没增长，`checkpoint_write_time/sync_time` 平稳，转看 autovacuum 或业务写入。
- 云盘突发性能耗尽也会让 checkpoint 看起来慢，但根因在存储配额。

### 观测手段

- `pg_stat_bgwriter`：`checkpoints_timed`、`checkpoints_req`、`checkpoint_write_time`、`checkpoint_sync_time`。
- PG 17 可同时关注 `pg_stat_checkpointer`（若版本提供）。
- `pg_stat_wal.wal_fpi/wal_bytes`：checkpoint 后 full page image 增多。
- OS `iostat`：await、util、fsync 延迟。

### 证伪手段

- 增大 `max_wal_size`、提高 `checkpoint_completion_target` 后，`checkpoints_req` 降低且延迟波峰变平，说明 checkpoint 配置是主因。
- 如果调大后无改善，检查后端自己写脏页、存储吞吐、autovacuum。

### 自检 SQL

```sql
-- 老版本和多数生产环境都可用。
SELECT checkpoints_timed, checkpoints_req,
       checkpoint_write_time, checkpoint_sync_time,
       buffers_checkpoint, buffers_clean,
       buffers_backend, buffers_backend_fsync
FROM pg_stat_bgwriter;

-- WAL 量与 full page image。
SELECT wal_records, wal_fpi, pg_size_pretty(wal_bytes) AS wal_bytes,
       wal_write, wal_sync, wal_write_time, wal_sync_time
FROM pg_stat_wal;

-- 关键参数。
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('checkpoint_timeout',
               'checkpoint_completion_target',
               'max_wal_size',
               'min_wal_size',
               'full_page_writes');
```

---

## 4.15 为什么 pg_wal 不能随便删：WAL 是恢复、复制、归档的共同账本

`pg_wal` 目录里的 segment 看起来像「旧日志」，但它不是普通日志文件。WAL 是 PostgreSQL 的 redo log：崩溃恢复靠它，物理复制靠它，PITR 归档恢复靠它，逻辑解码也从 WAL 读变更。手工删除 segment 可能让数据库无法恢复、备库断流、归档链断裂。

### 机制

一个 WAL segment 能被回收或删除，至少要满足：

1. 崩溃恢复不再需要它：checkpoint 已经推进。
2. 归档不再需要它：`archive_command` 成功（归档开启时）。
3. 复制不再需要它：所有物理/逻辑 slot 的 `restart_lsn` 已超过它。
4. 配置保留策略允许：`wal_keep_size`、`max_slot_wal_keep_size` 等。

只要其中一个条件不满足，PostgreSQL 就必须保留它。磁盘满时直接 `rm pg_wal/*` 是破坏账本，不是清理空间。

### 前置条件

- 有 replication slot，消费者落后或挂掉。
- 归档失败，`archive_status` 中大量 `.ready`。
- checkpoint 推进慢，WAL 产生快。
- `wal_keep_size` 或备份工具保留策略过大。

### 边界：什么时候可以清理

- 归档目录可以用 `pg_archivecleanup` 按恢复需要清理；这不是清理主库 `pg_wal`。
- 删除不再需要的 replication slot 可以释放保留压力，但必须确认没有消费者依赖。
- `pg_resetwal` 是灾难恢复最后手段，不是日常运维工具。

### 观测手段

- `pg_replication_slots`：slot 保留 WAL 的量。
- `pg_stat_archiver`：归档失败次数和最后失败 WAL。
- `pg_ls_waldir()`：当前 WAL 目录实际大小。
- `pg_stat_replication`：备库 replay 是否落后。

### 证伪手段

- 修复归档命令后，WAL 开始自动回收，说明归档是根因。
- 让消费者追上或安全删除 slot 后，WAL 自动下降，说明 slot 是根因。
- 手动 `CHECKPOINT` 后仍不下降，说明还有归档/slot/保留策略阻止清理。

### 自检 SQL

```sql
-- slot 保留 WAL 估算。
SELECT slot_name, slot_type, active,
       restart_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       xmin, catalog_xmin
FROM pg_replication_slots
WHERE restart_lsn IS NOT NULL;

-- 归档状态。
SELECT archived_count, failed_count,
       last_archived_wal, last_archived_time,
       last_failed_wal, last_failed_time
FROM pg_stat_archiver;

-- pg_wal 当前大小。需要相应权限。
SELECT pg_size_pretty(sum(size)) AS pg_wal_size
FROM pg_ls_waldir();
```

---

## 4.16 为什么 shared_buffers 设太大反而慢：BufferTag 哈希、OS page cache、checkpoint 脏页集会一起反噬

![BufferTag 到 shared buffer 的映射](../svg/4-problem-buffer-mapping.svg)

`shared_buffers` 是 PostgreSQL 自己的 buffer pool，但它不是越大越好。PG 读一个数据块时，要用 `BufferTag`（relfilenode、fork、block number）在共享哈希表里找 buffer descriptor。这个过程受 LWLock 保护。缓冲池过大、连接过多、热点页集中时，可能出现 `LWLock:buffer_mapping` 争用。

### 机制

一次 buffer 查找大致是：

1. 构造 BufferTag。
2. 对 tag 做 hash，定位 buffer mapping partition。
3. 持有分区 LWLock，在 buffer table 中找 descriptor。
4. 命中则 pin buffer；未命中则选择 victim buffer，读入页面。

过大的 `shared_buffers` 还会带来两类副作用：

- 挤压 OS page cache。PostgreSQL 仍依赖 OS 做预读、文件系统缓存和 writeback。
- checkpoint 脏页集合变大。缓存越大，一次 checkpoint 可能要处理的脏页越多。

`effective_cache_size` 不是分配内存，只是告诉 Planner 估算 OS + PG cache 能缓存多少数据。把 `shared_buffers` 设小一些，同时合理设置 `effective_cache_size`，往往比盲目把 shared_buffers 撑满更稳。

### 前置条件

- 高连接数、高并发访问热点表或热点索引页。
- `shared_buffers` 远大于工作集需要，挤压 OS cache。
- checkpoint 写入时间长，脏页堆积。
- NUMA、透明大页、内存回收等 OS 因素叠加。

### 边界：什么时候大 shared_buffers 有价值

- 专用数据库服务器，内存充足，工作集稳定，连接数受 pgbouncer 控制。
- 读多写少，热点集明确小于 buffer pool。
- 系统已经验证没有 buffer_mapping 争用、checkpoint 波峰可控。

### 观测手段

- `pg_stat_activity` 等待事件：`LWLock:buffer_mapping`。
- `pg_buffercache`：usagecount 分布、缓存是否真的被有效使用。
- `pg_stat_bgwriter`：backend 写、checkpoint 写是否异常。
- OS：page cache、swap、major fault、IO await。

### 证伪手段

- 在压测环境降低 `shared_buffers`，保持 `effective_cache_size` 合理，如果 `buffer_mapping` 等待下降且吞吐上升，说明过大 buffer 是根因。
- 如果降低后物理读暴涨、延迟变差，说明原 buffer pool 承载了真实工作集。
- 升级版本或降低连接数后等待消失，说明争用不是 SQL 本身，而是共享结构竞争。

### 自检 SQL

```sql
-- 当前内存相关参数。
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('shared_buffers', 'effective_cache_size', 'huge_pages', 'work_mem', 'maintenance_work_mem');

-- 等待事件分布。
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE wait_event IS NOT NULL
GROUP BY 1, 2
ORDER BY count(*) DESC;

-- 可选：查看 buffer 使用热度。需要 pg_buffercache 扩展。
CREATE EXTENSION IF NOT EXISTS pg_buffercache;
SELECT usagecount, count(*) AS buffers
FROM pg_buffercache
GROUP BY usagecount
ORDER BY usagecount;
```

---

## 4.17 为什么 logical decoding 慢：解码必须按事务重组 WAL，还要被 slot 的确认位置约束

逻辑解码不是简单把 WAL 文件按行吐出来。WAL 是物理/逻辑混合的变更记录，逻辑解码需要解析 WAL、访问 catalog，按事务边界重组变化，再交给 output plugin 编码成下游协议。大事务在 commit 前不能完整对外发布，reorder buffer 可能占内存或 spill 到磁盘。

### 机制

逻辑复制 slot 有几个关键位置：

- `confirmed_flush_lsn`：消费者确认已经安全接收的位置。
- `restart_lsn`：服务端仍可能需要从这里重新解码，因此不能删除之前所需 WAL。
- `xmin/catalog_xmin`：为了解码旧事务和系统表信息，可能阻止 vacuum 清理 heap 或 catalog tuple。

慢的常见来源：

- 大事务：必须缓存大量 change，commit 后才集中发送。
- `logical_decoding_work_mem` 不够：reorder buffer spill 到磁盘。
- output plugin 编码慢，例如 JSON 格式很重。
- 下游消费慢：slot 不确认，WAL 和 xmin 都被保留。
- DDL/catalog 频繁变化，解码需要更多 catalog 快照处理。

### 前置条件

- 使用 logical replication、CDC、Debezium、wal2json、pgoutput 等。
- 有大事务、批量导入、长事务。
- 消费端网络慢、处理慢或停机。
- slot 无上限保留，`max_slot_wal_keep_size` 未设置或过大。

### 边界：什么时候不是逻辑解码问题

- 物理备库 replay 慢与逻辑解码不同，先区分 slot_type。
- 发布端 SQL 本身慢，不等于解码慢。
- 初始表同步慢可能是 COPY/网络/索引问题，不是 WAL 解码问题。

### 观测手段

- `pg_replication_slots`：logical slot 的 retained WAL、`catalog_xmin`。
- `pg_stat_replication`：walsender 发送位置。
- 订阅端 `pg_stat_subscription`：接收时间与 LSN。
- 日志：logical decoding spill、复制连接断开、slot 保留告警。

### 证伪手段

- 把大事务拆成小事务，解码延迟消失，说明 reorder buffer 是主因。
- 提高消费端吞吐后 `confirmed_flush_lsn` 前进，WAL 保留下降，说明消费者慢。
- 切换更轻量 output plugin 或二进制协议后 CPU 下降，说明编码成本是主因。
- 安全删除废弃 slot 后 WAL 释放，说明 slot 保留是根因；这一步必须先确认消费者不再需要。

### 自检 SQL

```sql
-- 逻辑 slot 状态与保留量。
SELECT slot_name, plugin, slot_type, active,
       restart_lsn, confirmed_flush_lsn,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal,
       xmin, catalog_xmin
FROM pg_replication_slots
WHERE slot_type = 'logical';

-- 发布端 walsender 状态。
SELECT pid, application_name, state, sync_state,
       sent_lsn, write_lsn, flush_lsn, replay_lsn,
       write_lag, flush_lag, replay_lag
FROM pg_stat_replication;

-- 订阅端接收状态。在 subscriber 上执行。
SELECT subname, pid, received_lsn, latest_end_lsn,
       now() - last_msg_receipt_time AS since_last_msg,
       latest_end_time
FROM pg_stat_subscription;

-- 解码相关参数。
SELECT name, setting, unit
FROM pg_settings
WHERE name IN ('logical_decoding_work_mem',
               'max_replication_slots',
               'max_slot_wal_keep_size',
               'wal_level');
```

---

## 4.18 串起来看：同一个现象可能来自不同层

| 现象 | 第一反应 | 机制层解释 | 优先观测 |
|---|---|---|---|
| 查询慢 | SQL 写差？ | 可能是 OFFSET 丢弃、Sort 阻塞、统计误差、IO、锁 | `EXPLAIN (ANALYZE, BUFFERS)` + wait event |
| 表越来越大 | 数据真的多？ | MVCC dead tuple 未清理或高水位未重写 | `n_dead_tup`、`pgstattuple`、长事务 |
| 备库延迟 | 网络慢？ | send/write/flush/replay/feedback/slot 任一段卡住 | `pg_stat_replication`、slot、备库 replay |
| CPU/IO 突增 | 业务突增？ | checkpoint、autovacuum、GIN pending merge、排序落盘 | `pg_stat_bgwriter`、`pg_stat_progress_vacuum`、EXPLAIN |
| 索引不用 | Planner 蠢？ | 谓词无法证明、统计失真、cost 模型认为不划算 | `pg_stats`、partial predicate、`SETTINGS` |
| WAL 爆盘 | 日志太多？ | slot、归档、checkpoint、备库落后共同保留 | `pg_replication_slots`、`pg_stat_archiver`、`pg_ls_waldir()` |

机制派排错的核心是：**不要停在现象名词上**。看到「慢」要问慢在哪个节点；看到「膨胀」要问 OldestXmin 为什么不动；看到「延迟」要问 LSN 卡在哪一段；看到「计划错」要问 rows 从哪里估出来。

---

## 4.19 讲解节奏建议（50 分钟）

- 0-5 分钟：4.0，建立「机制 → 观测 → 证伪」框架。
- 5-18 分钟：4.1-4.2，OFFSET 与 MVCC 膨胀，打通执行器和存储层。
- 18-28 分钟：4.3-4.5，复制延迟、锁雪崩、XID freeze，强调 horizon 和队列。
- 28-38 分钟：4.6-4.9，GIN/BRIN/Planner/批量搬运，强调访问方法和 cost 模型。
- 38-48 分钟：4.10-4.17，补充高频“为什么”，用自检 SQL 快速演示。
- 48-50 分钟：回到 4.18 表格，总结每类问题的第一观测点。

---

## 4.20 本章参考

- `/Users/digoal/new/tmp1/20260708_05.md` 第五章「问题分析：从“为什么”反推机制」：本章 4.1-4.9 的骨架来源。
- PostgreSQL 官方文档概念：MVCC、VACUUM、Planner Statistics、EXPLAIN、GIN/BRIN、Streaming Replication、WAL、Runtime Statistics。
- PostgreSQL 常用扩展视图：`pg_stat_statements`、`pageinspect`、`pg_visibility`、`pg_buffercache`、`pgstattuple`。

本章所有 SQL 的定位是「自检与证伪」，不是生产变更脚本；涉及 `VACUUM`、`REINDEX`、删除 slot、DDL、参数调整的动作，必须先在测试环境和维护窗口验证。
