#!/usr/bin/env bash
# gen_bug_report.sh [output.md]
# 交互式生成社区级 PG Bug 报告
# 会问若干问题, 完成后渲染到 assets/bug_report_template.md
set -euo pipefail
OUT="${1:-bug_report.md}"
TPL="$(dirname "$0")/../assets/bug_report_template.md"

[ -f "$TPL" ] || { echo "template missing: $TPL"; exit 1; }

read -rp "Title (子模块: 现象): " TITLE
read -rp "OS (e.g. Ubuntu 22.04): " OS_NAME
read -rp "OS version: " OS_VER
read -rp "Kernel (uname -r): " KERNEL
read -rp "PG src dir: " PG_SRC
read -rp "PG install dir: " PG_INSTALL
read -rp "PG version (server_version): " PG_VER
read -rp "Locale: " LOCALE
read -rp "Compiler: " CC
read -rp "configure options: " CONFIGURE
read -rp "Reproducible (Yes / Sometimes / No): " REPRO
read -rp "Reproduction steps (一行一条, 结束 Ctrl-D): " STEPS
STEPS_BODY="$STEPS"
read -rp "Bug log file (默认 stderr 或 - ): " LOG_FILE
[ -z "$LOG_FILE" ] && LOG_FILE="-"
read -rp "Why is this a bug? (引用文档/manual): " WHY
read -rp "Fix suggestion (函数/文件/伪代码): " FIX

COMMIT_INFO="$("$PSQL" 2>/dev/null || true)"
if [ -d "$PG_SRC/.git" ]; then
    COMMIT_INFO=$(bash "$(dirname "$0")/extract_commit_info.sh" "$PG_SRC")
fi
LOG_BODY="$([ "$LOG_FILE" = "-" ] && cat || cat "$LOG_FILE")"

python3 - "$OUT" "$TPL" <<PY
import sys
out, tpl = sys.argv[1], sys.argv[2]
with open(tpl) as f: body = f.read()
repl = {
    "{{TITLE}}":     "$TITLE",
    "{{OS}}":        "$OS_NAME $OS_VER",
    "{{KERNEL}}":    "$KERNEL",
    "{{PG_VER}}":    "$PG_VER",
    "{{LOCALE}}":    "$LOCALE",
    "{{CC}}":        "$CC",
    "{{CONFIGURE}}": "$CONFIGURE",
    "{{REPRO}}":     "$REPRO",
    "{{STEPS}}":     """$STEPS_BODY""",
    "{{COMMIT}}":    """$COMMIT_INFO""",
    "{{LOG}}":       """$LOG_BODY""",
    "{{WHY}}":       "$WHY",
    "{{FIX}}":       "$FIX",
    "{{PG_SRC}}":    "$PG_SRC",
    "{{PG_INSTALL}}":"$PG_INSTALL",
    "{{DATE}}":      "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
}
for k, v in repl.items():
    body = body.replace(k, v)
with open(out, 'w') as f: f.write(body)
print(f"wrote {out}")
PY
