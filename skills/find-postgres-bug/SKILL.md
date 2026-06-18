---
name: find-postgres-bug
description: >
  Find latent bugs in a local PostgreSQL source tree (REL_xx_STABLE branch
  or HEAD). Builds and starts a local PG instance (debug + cassert, never
  auto-shuts-down), scans recent commits for high-risk code paths, lets
  the user pick a commit, writes and runs a .sql repro, captures the
  server log, and renders a community-style markdown bug report
  (Environment, Repro, Actual/Expected, Log, Why-bug, Fix). Use when the
  user says "find a bug in postgres", "test a recent commit", "check
  this commit for bugs", "write a repro", "I want to look for bugs in
  REL_xx_STABLE", "把 PG 源码跑起来找一个 bug", "看看这个 commit 会不会
  出问题", etc. Triggers whenever the user gives a PG source directory
  and asks to hunt bugs.
---

# Find Postgres Bug

## Overview

End-to-end pipeline for finding a latent bug in a local PostgreSQL
source tree and producing a community-style markdown report. The
instance stays up between steps so the user can iterate on the repro
without re-building.

**Source layout assumed:** the standard PG tree
(`src/backend/`, `src/include/`, `contrib/`, `src/test/`, …) at
`$PG_SRC_DIR`.

**Important:** the skill **never** auto-stops the PG instance. Run
`scripts/stop_pg.sh` explicitly when you are done.

---

## Quick start

```bash
# 1. point at the source tree (the rest has sane defaults)
export PG_SRC_DIR=/path/to/postgres

# 2. one-shot: configure + build + initdb + start
./scripts/build_and_start_pg.sh

# 3. see what's risky in the last 30 commits
./scripts/find_suspicious_commits.sh 30 HEAD

# 4. pick one, e.g. abc1234, and look at the diff
./scripts/analyze_commit.sh abc1234

# 5. write a repro, then run it
$EDITOR /tmp/repro.sql
./scripts/run_repro.sh /tmp/repro.sql my-repro

# 6. inspect what the server said
./scripts/capture_log.sh errors

# 7. render a bug report
$EDITOR /tmp/bug.yaml       # fill the fields from references/bug_report_template.md
./scripts/gen_bug_report.sh /tmp/bug.yaml
```

If a real bug surfaces, the markdown is ready to copy into a
[pgsql-bugs] post. If not, you've at least confirmed the commit is
clean for that input — pick the next suspicious commit and iterate.

---

## Workflow

Each step has a **success criterion** the agent should verify before
moving on.

### Step 1 — Declare the source tree

```bash
export PG_SRC_DIR=/path/to/postgres
source ./scripts/pg_env.sh
```

The `source` line is optional; the scripts source `pg_env.sh`
internally, but sourcing it in your shell gives you `$PGPORT`,
`$PGDATA`, `$PG_LOG`, `psql` on `$PATH`, etc.

**Success:** `ls $PG_SRC_DIR/src/backend/parser/parse_expr.c` exists,
and `git -C $PG_SRC_DIR rev-parse HEAD` prints a SHA.

### Step 2 — Build & start the instance

```bash
./scripts/build_and_start_pg.sh
```

This runs `./configure --enable-debug --enable-cassert
--enable-debug-symbols`, `make -jN`, `make install`, `initdb`, and
`pg_ctl start` on port `${PG_PORT:-55432}`. It is **idempotent** —
re-run after editing C code; it skips steps that are already done.

**Success:** `pg_isready -h /tmp -p $PG_PORT` returns 0 and
`psql -h /tmp -p $PG_PORT -U $PG_USER -d postgres -c "SELECT 1"`
prints `1`.

### Step 3 — Discover risky commits

```bash
./scripts/find_suspicious_commits.sh 30 HEAD
```

Outputs tab-separated rows: `HASH  DATE  AUTHOR  FILES  INSERTIONS
DELETIONS  SUBJECT`. Read [references/commit_risk_indicators.md](references/commit_risk_indicators.md)
to bias the pick toward parser/planner/executor/storage/replication
paths and away from docs / pure refactors.

**Success:** you have 3–5 candidate commit hashes to choose from.

### Step 4 — Analyze the chosen commit

```bash
./scripts/analyze_commit.sh <hash> 600
```

Shows the commit message + file list + first 600 lines of the diff.
Read the diff against the risk indicators; the goal is to answer
"what input would hit the new code path, and at what boundary?".

**Success:** you can name the function / branch / GUC that the
commit touches, and you have a one-sentence description of the
expected invariant it should preserve.

### Step 5 — Write a repro

Create `repro/<name>.sql` (or `/tmp/<name>.sql`). Use
[references/repro_patterns.md](references/repro_patterns.md) for
patterns by area. Common shape:

```sql
SET client_min_messages = debug1;
-- minimal setup that hits the new code path
-- boundary cases: empty, single, NULL, max, very many, concurrent
```

**Success:** you can point at one specific clause / call site the
repro exercises.

### Step 6 — Run the repro

```bash
./scripts/run_repro.sh repro/<name>.sql <name>
```

This executes the SQL, tees output to `$PGDATA/repro-<name>-<ts>.log`,
and prints the most recent `ERROR/FATAL/PANIC/WARNING/STATEMENT`
lines from the server log scoped to that run. See
[references/log_indicators.md](references/log_indicators.md) for
multi-line patterns (backtraces, error context).

**Success:** either

- (a) the repro completes without any `ERROR/FATAL/PANIC` in the log
  → pick the next commit, or
- (b) the repro triggers a real symptom → proceed to Step 7.

### Step 7 — Render the bug report

Fill [references/bug_report_template.md](references/bug_report_template.md)
into a YAML file, then:

```bash
./scripts/gen_bug_report.sh /tmp/<name>.yaml
```

The script writes to
`./markdown/find_postgres_bug-<title-slug>-<date>.md` and embeds
OS, kernel, compiler, PG version, source commit, the repro SQL,
the actual output, a log tail, and the `why-bug` / `fix` fields.

**Success:** the rendered markdown has all six required blocks
(Environment / Summary / Repro / Actual / Why / Fix) and a server
log snippet that contains the `ERROR:`/`FATAL:` line.

### Step 8 — Tear down (only when done)

```bash
./scripts/stop_pg.sh
```

This is the **only** script that stops the instance. Run it
explicitly; nothing else will.

---

## Output format

A successful run produces one markdown file per bug, named
`markdown/find_postgres_bug-<slug>-<YYYY-MM-DD>.md`. The full
template is in [assets/bug_report.md.template](assets/bug_report.md.template);
the field reference is in
[references/bug_report_template.md](references/bug_report_template.md).

Required sections (mapped to community pgsql-bugs expectations):

1. **Environment** — OS / OS version / kernel / compiler / PG
   version (`pg_config --version`) / branch / commit hash / build
   flags.
2. **Summary** — 1–3 sentences, factual, no judgement.
3. **Reproduction** — file path + inline `.sql` block.
4. **Actual vs expected** — verbatim `ERROR:`/output text vs the
   expected text, plus a server-log tail.
5. **Why is this a bug** — point at the spec, docs, or invariant
   it violates.
6. **Suggested fix** — even a rough direction is fine; community
   reports often accept "I'm not sure how to fix it but here's a
   reproducer".

---

## Script reference

| Script | Purpose |
| --- | --- |
| `scripts/pg_env.sh` | Sourceable env (`PG_SRC_DIR`, `PGBIN`, `PGDATA`, `PGPORT`, `PG_LOG`, `PG_CONF`) |
| `scripts/build_and_start_pg.sh` | configure + make + install + initdb + pg_ctl start, **idempotent, never auto-stops** |
| `scripts/stop_pg.sh` | Explicit teardown |
| `scripts/find_suspicious_commits.sh` | List recent commits, biased to code paths |
| `scripts/analyze_commit.sh` | Show stat + diff slice for one commit |
| `scripts/run_repro.sh` | Run a `.sql` repro, capture output + log slice |
| `scripts/capture_log.sh` | Grep `$PG_LOG` (tail / errors / full) |
| `scripts/gen_bug_report.sh` | Render markdown from a YAML inputs file |

Override any default by exporting the variable before running:

```bash
PG_PORT=55433 PG_USER=postgres ./scripts/build_and_start_pg.sh
```

---

## Reference index

Load only the file you need; each is self-contained.

- [references/pg_build_options.md](references/pg_build_options.md) —
  `./configure` flags, common pitfalls, build lifecycle.
- [references/commit_risk_indicators.md](references/commit_risk_indicators.md) —
  where to look, what to look for, anti-patterns to skip.
- [references/repro_patterns.md](references/repro_patterns.md) —
  minimal repro patterns by subsystem (parser, planner, executor,
  storage, replication, DDL, partitioning, GUC, extensions, indexes,
  FDW).
- [references/log_indicators.md](references/log_indicators.md) —
  severity levels, useful greps, multi-line patterns (assertions,
  backtraces, error context), how to read the log_line_prefix.
- [references/bug_report_template.md](references/bug_report_template.md) —
  YAML field reference + skeleton, plus how to post to
  pgsql-bugs@lists.postgresql.org.
- [references/pg_version_helpers.md](references/pg_version_helpers.md) —
  one-liners for version / commit / compiler / OS in the report.

---

## What this skill does *not* do

- It does not submit a patch or a post to pgsql-bugs — it produces
  a markdown draft for the human to review and post.
- It does not auto-build with every flag combination — one build
  per source tree, with the recommended debug + cassert flags.
- It does not shut the instance down for you. **Explicit teardown
  only** (`stop_pg.sh`).
- It does not pick the commit for you — Step 3 lists candidates,
  Step 4 lets you analyse, you pick. The agent can recommend but
  the human chooses the commit to test.

---

## Decision tree (TL;DR)

```
user has PG source dir?
  ├─ NO  → ask for it; suggest $HOME/postgres as a starting point
  └─ YES → source pg_env.sh → build_and_start_pg.sh
            ├─ build fails?  → read configure error, surface to user
            └─ build ok      → find_suspicious_commits 30
                                ├─ pick 1 commit (human or agent picks)
                                │   ├─ analyze_commit
                                │   ├─ write repro .sql
                                │   └─ run_repro
                                │       ├─ no bug → pick next commit
                                │       └─ bug found → fill bug.yaml
                                │                     → gen_bug_report
                                └─ after N rounds with no bug → suggest
                                    broadening N, switching branch, or
                                    focusing on a known hot area
```
