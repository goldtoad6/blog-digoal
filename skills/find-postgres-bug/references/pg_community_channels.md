# PG 社区上报渠道

## 主邮件列表

| 列表 | 订阅 | 用途 |
|---|---|---|
| pgsql-bugs | pgsql-bugs-subscribe@lists.postgresql.org | **所有 bug 上报** |
| pgsql-hackers | pgsql-hackers-subscribe@lists.postgresql.org | 开发讨论、patch review |
| pgsql-performance | pgsql-performance-subscribe@lists.postgresql.org | 性能问题 |
| pgsql-general | pgsql-general-subscribe@lists.postgresql.org | 一般使用问题 |
| pgsql-admin | pgsql-admin-subscribe@lists.postgresql.org | 运维 |

发邮件正文到 `pgsql-bugs@lists.postgresql.org` 即可（订阅后才能发）。

## Web 入口

- **邮件列表 archive**: https://www.postgresql.org/list/pgsql-bugs/
  可搜相似历史 bug。
- **GitHub mirror**: https://github.com/postgres/postgres/issues
  GitHub issue 主要用于 commitfest / patch review，不是首选 bug 渠道。
- **Slack/IRC**: 
  - libera.chat `#postgresql`
  - Postgresql Slack: https://postgres-slack.herokuapp.com/

## 上报前的准备清单

1. 必填:
   - 复现脚本（最小化、确定性能复现）
   - 完整 ERROR/PANIC 日志（含 stack trace）
   - PG 版本 + commit id
   - OS / 编译器 / locale / ICU
   - `configure` 选项
   - 关键 `postgresql.conf` 非默认项
   - 至少跑过 git 主分支/最新 stable 一次，确认仍存在
2. 加分:
   - 修复 patch（`git format-patch -1`）
   - 引用 manual 对应章节说明为什么是 bug
   - 引用 git log 中相关历史

## 报告被忽略的常见原因

- 没附 commit id / 用了预编译二进制
- 复现脚本过长 / 含敏感数据
- 实际是用户 SQL 写错（用 EXPLAIN 引导先看计划）
- 实际是新 feature 文档未补
- 在 bug 区发一般问题（应去 -general）

## 安全漏洞

**不要**直接发 pgsql-bugs。
发到 security@postgresql.org，等待 coordinator 安排披露时间。
PG 历史 CVE: https://www.postgresql.org/support/security/

## 收到回复后的流程

- `Tom Lane` / `Andres Freund` / `Alvaro Herrera` / `Heikki Linnakangas` 等 committer 会打 tag
- 等待 maintainer 决定 fix branch 和回移植范围
- 跟踪 `git log --grep="<bug_id_or_keyword>"` 看修复
- 修复后会自动出现在 next minor release notes
