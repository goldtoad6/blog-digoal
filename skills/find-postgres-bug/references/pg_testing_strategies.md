# PG 测试策略

## 1. 代码审计入口

| 子模块 | 关注点 |
|---|---|
| `src/backend/parser/` | 语法解析歧义、新 SQL 语法 |
| `src/backend/optimizer/` | 计划器、partition pruning、join order |
| `src/backend/executor/` | nodeHash/nodeSort/nodeAgg 溢出、并行 worker 同步 |
| `src/backend/commands/` | DDL、COPY、VACUUM、ANALYZE |
| `src/backend/storage/lmgr/` | 锁、deadlock detection |
| `src/backend/replication/` | 物理/逻辑复制 |
| `src/backend/utils/adt/` | 类型/函数实现，cast、formatting |
| `contrib/` | 扩展、PG 14+ 增加的 MERGE/RETURNING |

审计技巧：
- `git log --since="6 months ago" --oneline -- src/backend/commands/copy.c` 找高 churn 区
- `git blame` + `git log -S` 找某函数上次改动原因

## 2. 回归测试

PG 自带 `make check`，新增测试在 `src/test/regress/sql/` 下写 `.sql` + `expected/` 下写 `.out`。

```bash
cd <src>
make -C src/test/regress check
# 或单个测试
make -C src/test/regress check EXTRA_TESTS="partition_split copy2"
```

关注点：
- `expected/` 与 `results/` 不一致 → 真正的回归
- 不同 `--enable-debug` / `--with-icu` / `--with-openssl` 配置组合
- 跨字符集（`LC_COLLATE=en_US.UTF-8` / `C` / `zh_CN.UTF-8`）

## 3. 隔离测试 (isolation)

`src/test/isolation/` 用于并发死锁/竞态测试。

```bash
cd <src>/src/test/isolation
make installcheck
# 或跑单个
make installcheck EXTRA_TESTS="deadlock-detected partition-snapshot-conflict"
```

## 4. 模糊测试 (fuzz)

PG 项目用 AFL/libFuzzer 在 `src/test/fuzz/`。

```bash
# 自己搭 fuzz harness
$CC -fsanitize=address,undefined -g \
    src/test/fuzz/fuzz_expr.c \
    -I src/include -L src/port -lpgport \
    -o fuzz_expr
./fuzz_expr corpus/
```

参考资料：
- https://github.com/postgres/postgres/tree/master/src/test/fuzz

## 5. pgbench 压测

```bash
pgbench -i -s 50
pgbench -c 64 -j 8 -T 60 -M prepared
# 自定义脚本
pgbench -c 32 -j 8 -T 300 -f custom.sql
```

观察 `pg_stat_statements` 的 mean_time 方差、wal/秒、连接数、锁等待。

## 6. TAP 集成测试

`make installcheck-world` 跑全部测试，含 contrib/、ECPG、PL 各种语言。

## 7. 主动构造边缘情况

针对具体子模块构造输入：
- COPY: 空文件、超大行、嵌入 NUL、错误编码转换
- 数值: `NUMERIC` 最大精度、NaN/Infinity、denormal float
- 字符串: 嵌入式 NUL、超长（>1GB）、broken UTF-8
- 时间: 闰秒、时区切换、timestamptz 边界
- JSON: 深嵌套、巨大 key、duplicate key、非法 escape
- 数组: 空数组、含 NULL、多维、含 default
- 事务: SAVEPOINT 嵌套、回滚后使用临时对象
- 并发: `SELECT FOR UPDATE` 与 vacuum 同时、subtrans 溢出
