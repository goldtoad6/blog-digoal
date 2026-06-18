# PG 日志解读

## 日志级别（按严重性递增）

| 级别 | 含义 | 是否进 server log |
|---|---|---|
| DEBUG[1-5] | 调试信息 | 默认否 |
| INFO | 普通事件 | 否 |
| NOTICE | 提示 | 否 |
| LOG | 后台事件 | 是 |
| WARNING | 警告 | 是 |
| ERROR | 当前语句失败 | 是 |
| FATAL | 当前会话终止 | 是 |
| PANIC | 所有会话终止 | 是 |

`log_min_messages` 控制写入 server log 的最小级别。
`client_min_messages` 控制返回给客户端的最小级别。

## `log_line_prefix` 推荐格式

```
%m [%p] %q%u@%d/%a from %h
```

- `%m` 时间戳
- `%p` PID
- `%q` 高级查询标记
- `%u` 用户
- `%d` 数据库
- `%a` 应用名
- `%h` 远端主机

## SQLSTATE 速查

PG 用 5 字符 SQLSTATE，前两位是类：

| 类别 | 含义 |
|---|---|
| 00 | 成功 |
| 01 | 警告 |
| 02 | 无数据 |
| 03..0B | 事务/连接类 |
| 0A | feature not supported |
| 21..24 | 完整性/语法 |
| 22 | 数据异常 (22P02 反序列化错误) |
| 23 | 完整性约束违反 (23505 唯一、23503 外键、23514 check) |
| 25 | 事务状态无效 |
| 28 | 权限不足 (28000) |
| 2B | 触发器/依赖存在 |
| 34 | 无效游标名 |
| 40 | 事务回滚 (40P01 死锁) |
| 42 | 语法/访问规则 (42P01 表不存在) |
| 53 | 资源不足 (53300 too many connections) |
| 54 | 程序限制 (54000 嵌套层过深、54023 参数超限) |
| 55 | 对象不在要求状态 |
| 57 | 操作员介入 |
| 58 | 系统错误 |
| F0 | 配置文件 |
| HV | FDW |

## Stack trace 解读

crash 时 core dump 拿 stack：
```
gdb /path/to/postgres /cores/core.12345
(gdb) bt full
```

关注调用栈**顶端**的函数 — 那是崩的位置。
如果是 `errfinish`/`elog` 触发的，看 `errordata` 的 `sqlerrcode` 和 `message`。
如果是 `__assert`/`ExceptionalCondition`，看具体 condition 字符串。

## auto_explain

`shared_preload_libraries = 'auto_explain'` + `auto_explain.log_min_duration = 0`
可以抓所有慢 SQL 的实际计划，定位计划器/执行器异常。

## 关联其他信号源

- `pg_stat_activity`: 当前活跃会话
- `pg_locks`: 锁等待
- `pg_stat_database` / `pg_stat_user_tables`: 长期指标
- `pg_stat_statements`: 历史 SQL
- `dmesg`: 内核 OOM / segfault 信号
- `vmstat 1` / `iostat -x 1`: IO/内存
