#!/usr/bin/env bash
# extract_commit_info.sh <pg_src_dir>
# 输出: commit_id, short_id, branch, tag, commit_time, subject, dirty
set -euo pipefail
SRC="${1:?usage: $0 <pg_src_dir>}"
cd "$SRC"

COMMIT=$(git rev-parse HEAD)
SHORT=$(git rev-parse --short HEAD)
BRANCH=$(git rev-parse --abbrev-ref HEAD)
TAG=$(git describe --tags --abbrev=0 2>/dev/null || echo "none")
TIME=$(git log -1 --format='%ci')
SUBJ=$(git log -1 --format='%s')
DIRTY=$([[ -n "$(git status --porcelain)" ]] && echo "dirty" || echo "clean")

cat <<EOF
commit_id:  $COMMIT
short_id:   $SHORT
branch:     $BRANCH
nearest_tag:$TAG
commit_time:$TIME
subject:    $SUBJ
tree_state: $DIRTY
EOF
