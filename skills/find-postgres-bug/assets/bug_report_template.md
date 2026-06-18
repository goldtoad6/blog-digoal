# {{TITLE}}

## Summary

<!-- 一句话描述这个 bug，包括现象、影响范围、严重性 -->

## Environment

| Item | Value |
|---|---|
| OS | {{OS}} |
| Kernel | {{KERNEL}} |
| Locale | {{LOCALE}} |
| Compiler | {{CC}} |
| PostgreSQL version | {{PG_VER}} |
| Source commit | `{{COMMIT}}` (see block below) |
| Configure options | `{{CONFIGURE}}` |
| Source tree | `{{PG_SRC}}` |
| Install prefix | `{{PG_INSTALL}}` |
| Report date (UTC) | {{DATE}} |

### Source commit details

```
{{COMMIT}}
```

## Reproducible

**{{REPRO}}**

- Frequency: <!-- e.g. 10/10, 1/5 -->
- First observed: <!-- commit id / version -->
- Still present on `master` @ <!-- commit id -->: Yes / No / Not checked

## Reproduction Steps

```
{{STEPS}}
```

> 复现脚本应满足：
> - 自包含（不依赖外部数据）
> - 可独立运行（`psql -f repro.sql`）
> - 最小化（只保留触发 bug 的语句）

## Bug Log

> 贴原始日志，不要截断。从 `pg_log/postgresql-*.log` 取，crash 段包含 stack trace。

```
{{LOG}}
```

### 关键栈帧（如有）

```
#0  <function>  (<file>:<line>)
#1  ...
```

### 异常信号

- Signal: <!-- SIGSEGV(11) / SIGABRT(6) / SIGBUS(7) -->
- SQLSTATE: <!-- 5 字符代码 -->
- Error hint: <!-- server log 里的 HINT 字段 -->

## Why is this a bug?

{{WHY}}

> 引用 PG 官方文档章节或 SQL 标准条款说明行为违反预期。
> 如果是 crash，引用 PG Source Code 注释里相关 invariant / Assert 条件。

## Impact

<!-- 影响哪些用户场景？数据丢失？宕机？性能降级？安全？ -->

## Fix Suggestion

{{FIX}}

### 建议的修复入口

- 文件: <!-- `src/backend/.../<file>.c` -->
- 函数: <!-- `function_name` -->
- 行号: <!-- `:line` -->
- 相关 commit: <!-- 引用的修复 commit -->

### 修复 patch 草案（如有）

```diff
diff --git a/src/backend/.../file.c b/src/backend/.../file.c
index .....
--- a/src/backend/.../file.c
+++ b/src/backend/.../file.c
@@ -<line>,<count> +<line>,<count> @@
     /* 旧代码 */
+    /* 新代码 */
```

### 备选方案

1. <!-- 备选 1 -->
2. <!-- 备选 2 -->

## Related

- Maling list thread: <!-- url -->
- Similar past bug: <!-- url -->
- Open commitfest entry: <!-- url -->

## Workaround

<!-- 临时绕开方法（升级、改配置、改 SQL），如果存在 -->

---

## Reporter

- Name: 
- Email: 
- GitHub: 
- Downstream: <!-- 是否有下游产品受影响，可加速 backport -->
