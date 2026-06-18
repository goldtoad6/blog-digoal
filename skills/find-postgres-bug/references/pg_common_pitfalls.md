# PG 容易踩坑的子模块清单

按 churn 高 + 历史 bug 多排序。找 bug 时优先扫这些区域。

## 1. COPY / COPY FROM PROGRAM

- 编码转换（client_encoding → server_encoding）
- 嵌入 NUL（`\0`）处理
- 超大行（>1GB）
- 默认 delimiter / quote / escape 在错误 locale 下行为
- `FORCE_NOT_NULL` / `FORCE_NULL` 与空字符串
- `COPY FROM PROGRAM` 的 command string 为空/带换行
- `HEADER` mismatch

## 2. Partitioning (declarative)

- `PartitionPrune` 漏剪枝
- 跨分区 UPDATE（move row between partitions）
- `DETACH PARTITION CONCURRENTLY` 与外键
- `ATTACH PARTITION` 时索引不匹配
- `subpartition` 多级下 statistics 错
- partition-wise join / aggregate 失效

## 3. Replication

- logical replication: 大事务、DDL 复制（PG 15+）、列顺序
- physical: 备机查询冲突 (recovery conflict)
- 同步复制 timeout / cascade
- 订阅 enable/disable 时序
- `wal2json` / `pgoutput` 行为差异

## 4. PL/pgSQL

- `RECORD` / `ROW` 类型推导
- `PERFORM` vs `SELECT` 副作用
- 异常处理 (`EXCEPTION WHEN OTHERS`) 吞错
- 嵌套 `FOR`/`WHILE` 标签
- `EXECUTE` 与参数化
- `RETURNS TABLE` 函数变异
- `SECURITY DEFINER` 权限放大
- 触发器 `WHEN` 条件

## 5. 并发 / 锁

- `SELECT FOR UPDATE` 与 vacuum 冲突
- `advisory lock` 与事务结束时机
- `lock_timeout` / `statement_timeout` 配合
- `pg_advisory_xact_lock` 嵌套死锁
- `SKIP LOCKED` 与 queue 场景
- `SERIALIZABLE` 隔离级 ssi 误判

## 6. VACUUM / autovacuum

- `vacuum_cost_delay` / `autovacuum_vacuum_cost_delay` 调节
- `visibility map` 与 index-only scan
- freeze 失效 / wraparound
- `pg_stat_progress_vacuum` 卡住
- xid 溢出 (`xidStopLimit`)
- `multixact` 耗尽

## 7. 扩展 / contrib

- 升级时 `CREATE EXTENSION` 与 `ALTER EXTENSION UPDATE`
- `pg_trgm` / `pg_stat_statements` / `pg_prewarm` / `auto_explain` 行为
- `PostGIS` / `pg_cron` / `pg_partman` 等三方扩展版本兼容
- `pg_upgrade` 跨大版本

## 8. JSON / JSONB

- `jsonb_path_*` 操作符
- 深嵌套路径
- 数字字面量精度
- duplicate key 行为（保留最后一个）
- `jsonb_set` 创建路径

## 9. FDW

- `postgres_fdw` 远程估算
- `file_fdw` 编码
- 跨版本 FDW 协议
- 推下/拉回 (pushdown) 边界

## 10. 全文搜索 (FTS)

- `tsvector` 更新触发器
- `tsquery` 短语
- ranking (`ts_rank`) 稳定性
- 自定义词典
- `pg_trgm` + GIN 联合

## 11. 角色 / 权限

- `SECURITY LABEL` 跨 dump
- `GRANT ... WITH GRANT OPTION`
- `SET ROLE` 链
- `BYPASSRLS` 与 view
- 事件触发器 (event trigger) 时机
- 行级安全 (RLS) 与 view 组合

## 12. 监控 / 视图

- `pg_stat_*` 视图重置
- `EXPLAIN (FORMAT JSON)` schema
- `pg_locks` 大小与 grant/wait
- `pg_stat_replication` lag 计算
