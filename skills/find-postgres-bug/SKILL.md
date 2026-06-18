---
name: find-postgres-bug
description: 在本地编译并部署 PostgreSQL REL_xx_STABLE 分支实例，通过代码审计、回归测试、模糊测试和异常日志分析等手段快速发现 Bug，并以标准 Markdown 格式输出可投递到 pgsql-bugs 社区的 Bug 报告。适用场景：(1) 用户提供 PG 源码路径与分支名要求找 bug；(2) 用户希望复现某个疑似 PG 缺陷；(3) 跑完一个测试场景，需要结构化记录 ERROR/FATAL/PANIC 日志并生成社区级 bug report；(4) 需要确定 PG commit id、OS 信息、复现步骤以便向社区上报。
---

# Find Postgres Bug

在本地源码编译的 PostgreSQL 实例上快速发现 Bug 并生成符合 pgsql-bugs 社区规范的 Markdown Bug 报告。

## 适用场景

满足以下任一条件即可使用本 skill：

- 用户给出 PG 源码路径（`REL_xx_STABLE` 分支）和编译好的二进制路径，要求找 bug
- 用户描述了一个疑似 PG 缺陷，需要拉起实例复现
- 跑完一个测试/压测/模糊测试场景，需要整理 ERROR/FATAL/PANIC 日志生成可投递到社区的 bug report
- 需要把本地现象转化为完整复现脚本、commit hash、修复建议的 Markdown 文档

## 工作流决策树

```
用户提供的信息
├── 仅提供源码路径和分支
│   └── 走"通用扫描"路径：编译检查 + 跑回归 + 触发常见陷阱 → 见 references/pg_testing_strategies.md
├── 提供具体 SQL/操作复现一个已知可疑现象
│   └── 走"复现"路径：拉起实例 → 执行复现 → 抓日志 → 填模板
├── 提供 crash dump 或异常日志
│   └── 走"日志分析"路径：读日志 → 定位函数/文件 → 查 git blame → 写报告
└── 提供 commit id 或 patch，要求回归验证
    └── 走"回归验证"路径：打 patch → 重编 → 复现 → 对比日志
```

## 步骤 1：环境探测

依次执行：

1. **读源码路径元信息**
   - `git -C <src> log -1 --format='%H %ci %s'` 拿到 commit id
   - `git -C <src> rev-parse --abbrev-ref HEAD` 拿到分支名
   - `git -C <src> describe --tags --abbrev=0` 拿到最近 tag
   - 用 `scripts/extract_commit_info.sh <src>` 一次拿全

2. **读 OS 与工具链**
   - `uname -a`、`cat /etc/os-release`、`gcc --version`、`bison --version`、`flex --version`
   - 编译器、bison、flex、readline、zlib、openssl、icu、python3 任一缺失都可能导致 build/行为差异
   - 用 `scripts/pg_env_check.sh` 一键体检

3. **确认编译产物**
   - 期望路径：`<src>/src/backend/postgres`、`<src>/src/bin/pg_ctl/pg_ctl`、`<src>/src/bin/psql/psql`
   - 没有就 `cd <src> && ./configure --prefix=<install> && make -j$(nproc) && make install`

## 步骤 2：拉起实例

用 `scripts/pg_instance.sh` 完成 initdb / start / stop / status。默认端口 55432、数据目录 `/tmp/pgbug_data`，避免与系统 PG 冲突。

```
scripts/pg_instance.sh init <src_install>   # 初始化一次
scripts/pg_instance.sh start                # 启动
scripts/pg_instance.sh psql "SELECT version();"   # 验证
scripts/pg_instance.sh stop                 # 收尾
```

启动前确保 `postgresql.conf` 关键参数便于观察 bug：

- `logging_collector = on`
- `log_directory = 'pg_log'`
- `log_filename = 'postgresql-%Y-%m-%d_%H%M%S.log'`
- `log_min_messages = debug1`（深度排查时再开，平时 warning 即可）
- `log_statement = 'all'` 或 `'mod'`（视场景）
- `log_error_verbosity = verbose`
- `log_line_prefix = '%m [%p] %q%u@%d/%a from %h '`
- `client_min_messages = notice`（让 NOTICE/WARNING 走客户端）

## 步骤 3：发现 Bug

按现象从大到小分四类策略（详见 `references/pg_bug_categories.md` 与 `references/pg_testing_strategies.md`）：

1. **CRASH 类**（PANIC / FATAL / SIGSEGV）
   - 触发：`pg_instance.sh start` 启动后跑可疑 SQL
   - 抓取：`pg_log/postgresql-*.log` 里 `PANIC:` / `FATAL:` / `LOG: server process ... was terminated` 段
   - 同时记录 core dump 路径（`/cores/core.<pid>` 或 `pg_instance.sh status` 显示的 core_path）

2. **逻辑错误类**（结果错误、未定义行为、计划器缺陷、约束违规）
   - 跑对应的 `SELECT`/`EXPLAIN`，对正常实例 vs 源码实例做 diff
   - 看 `WARNING:`、`ERROR:` 后面跟的 hint、code（SQLSTATE）

3. **回归类**（已修过又复发）
   - `git -C <src> log --oneline -- <file>` 看可疑文件最近改动
   - `git -C <src> blame <file>` 锁定行
   - 用 `git -C <src> log -S <symbol>` 搜索字符串/标识符引入/删除记录

4. **资源/并发类**（死锁、内存泄漏、锁等待）
   - `pg_locks`、`pg_stat_activity`、`pg_stat_statements`
   - 长时间跑再 `pg_log` 里搜 `deadlock detected`、`out of memory`、`canceling statement due to lock timeout`

## 步骤 4：最小化复现

社区不会接受"我执行了一堆 SQL 才出问题"。复现必须：

- 一段独立的 SQL（或 psql 命令序列）
- 触发条件可枚举：版本、配置、并发数、数据规模、字符集、locale、ICU 库版本
- 不依赖外部数据（除非 bug 本质就是数据相关）

辅助脚本：`scripts/minimize_repro.sh` 接受原始大脚本，逐步删除语句直到 bug 仍可触发，输出最小集。

## 步骤 5：生成 Bug 报告

**必填字段**（pgs 社区标配，缺一会被打回）：

- Title：`<子模块>: <一句话现象>`，例如 `COPY FROM PROGRAM: FATAL on empty command string`
- Environment：OS、OS version、kernel、locale (`locale`)、compiler (`gcc --version`)
- PostgreSQL version：主版本号 + commit id
- Configuration：`./configure` 完整参数、`postgresql.conf` 关键 `非默认` 参数
- Reproducible: Yes / Sometimes / No
- Reproduction steps：编号命令清单，每步注释
- Bug log：原始 ERROR/FATAL/PANIC 日志原文 + `\`\`\`` 围栏
- Why is this a bug?：引用 PG 文档/manual 对应章节，说明违反预期
- Fix suggestion：函数/文件定位 + 伪代码 / 引用 commit 链接

**可选增强**：

- 修复可行性 patch（`\*.patch` 文本或 git diff）
- 触发概率（跑 N 次复现 M 次）
- 影响范围（哪些版本也受影响，搜索 `git tag --contains <bad_commit>`）

模板见 `assets/bug_report_template.md`，由 `scripts/gen_bug_report.sh` 渲染到 stdout 或文件。

## 关键提示

- 报告里**不要**包含用户真实数据，敏感字段要脱敏
- 涉及 crash 时，把**完整** stack trace 贴全，不要截断
- pgsql-bugs 邮件列表订阅后发邮件正文即可，不要附件（附件会被剥离）
- 提交前先 `git pull --rebase` 确认 commit id 是最新，避免重复报
- 用 `git format-patch -1 <commit>` 把可疑修复思路转成 patch 附在报告里

## 资源

### scripts/
- `extract_commit_info.sh`：从源码目录一次性导出 commit/branch/tag/dirty 状态
- `pg_env_check.sh`：OS、locale、工具链、共享库、PG 可执行文件体检
- `pg_instance.sh`：initdb / start / stop / status / psql / pglog 六个子命令
- `minimize_repro.sh`：二分/逐步删除法把复现脚本缩到最小
- `gen_bug_report.sh`：把环境/commit/log/repro 喂给模板生成 Markdown

### references/
- `pg_bug_categories.md`：4 大类 bug 及其典型信号
- `pg_log_interpretation.md`：PG 日志级别、SQLSTATE、stack trace 阅读
- `pg_testing_strategies.md`：代码审计、回归、模糊、fuzz、isolation test 入口
- `pg_community_channels.md`：pgsql-bugs 邮件列表、IRC、github issues 入口
- `pg_common_pitfalls.md`：容易踩坑的子模块清单（COPY、partition、replication、PL/pgSQL、订阅、逻辑复制、扩展）

### assets/
- `bug_report_template.md`：可直接渲染的标准报告模板
