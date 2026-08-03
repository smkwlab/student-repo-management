#!/bin/bash
#
# Residual dependabot.yml Removal Script
#
# 学生リポジトリに残った .github/dependabot.yml を削除する（issue #574）。
#
# 生成時の削除処理は #514（2026-07-11）で入ったが、それ以前に作られた
# リポジトリには残っている。設定が残っていると Dependabot が PR を作り続け、
# 誤マージ防止 CI や review 必須保護と干渉して溜まる。学生から見れば、自分が
# 作った覚えのない PR が論文リポジトリに現れ、承認が必要なため自分では閉じる
# 以外にできることがない。
#
# Usage:
#   ./remove-dependabot-config.sh            # 対象を列挙するのみ（既定）
#   ./remove-dependabot-config.sh --apply    # 実際に削除する
#
# 既定を dry-run にしているのは、この操作が学生リポジトリの内容を消すため。
# 同じ scripts/ の audit-branch-protection.sh は --dry-run をオプトインに
# しているが、そちらは Issue を起票するだけで破壊的ではない。
#
# Environment:
#   ORG              対象 org（default: smkwlab）
#   REPO_PATTERN     学生リポジトリを識別する正規表現
#                    （default: ^k[0-9]{2}(rs|gjk)[0-9]+）
#   REPO_LIST_LIMIT  gh repo list の取得上限（default: 2000）。org の
#                    リポジトリ総数を下回ると走査対象が黙って欠ける
#
# 対象:
#   - .github/dependabot.yml が存在する学生リポジトリ
#   - archived は対象外。読み取り専用で Dependabot が動かないため設定が
#     残っていても新しい PR は作られない。unarchive → 削除 → 再 archive は
#     得られるものに対して操作が重い
#
# 前提:
#   ブランチ保護は required_approving_review_count=1 だが enforce_admins=false
#   なので、管理者権限の gh 認証であれば contents API から直接削除できる。
#   権限が足りない場合は該当リポジトリを errors として報告し、処理は続行する。

set -eu

ORG="${ORG:-smkwlab}"
# 既定値を ${VAR:-...} に直接書かない。パターンに含まれる {2} の } が
# パラメータ展開を早期に終わらせ、壊れた正規表現になる
REPO_PATTERN="${REPO_PATTERN:-}"
if [ -z "$REPO_PATTERN" ]; then
    REPO_PATTERN='^k[0-9]{2}(rs|gjk)[0-9]+'
fi
# org のリポジトリ総数を上回る値にする（gh は既定 30 件で打ち切る）
REPO_LIST_LIMIT="${REPO_LIST_LIMIT:-2000}"
TARGET_PATH=".github/dependabot.yml"
COMMIT_MESSAGE="chore: remove dependabot.yml inherited from the template

学生リポジトリでは Actions の自動更新は不要（最新化はテンプレート側で管理）。
誤マージ防止 CI や review 必須保護と dependabot PR が干渉して溜まるため削除する。

Refs smkwlab/student-repo-management#574"

APPLY=false
if [ "${1:-}" = "--apply" ]; then
    APPLY=true
elif [ -n "${1:-}" ]; then
    echo "不明な引数: $1" >&2
    echo "Usage: $0 [--apply]" >&2
    exit 1
fi

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

removed=0
skipped_archived=0
errors=0
error_repos=""

log "対象 org: ${ORG}"
if [ "$APPLY" = "true" ]; then
    log "モード: --apply（実際に削除する）"
else
    log "モード: dry-run（列挙のみ。削除するには --apply を付ける）"
fi

# 学生リポジトリを列挙する。registry ではなくリポジトリ名で判定するのは、
# 登録依頼 Issue を経由していないリポジトリ（ポスター・研究会論文など）にも
# 同じ残存があるため。
repos=$(gh repo list "$ORG" --limit "$REPO_LIST_LIMIT" --json name,isArchived \
    --jq ".[] | select(.name | test(\"${REPO_PATTERN}\")) | \"\(.name)\t\(.isArchived)\"" \
    | sort)

total=$(printf '%s\n' "$repos" | grep -c . || true)
log "学生リポジトリ: ${total} 件を走査"

while IFS=$'\t' read -r name archived; do
    [ -z "$name" ] && continue

    # ファイルの有無で対象を決める。同時に sha を取る（削除に必要）。
    # gh api は 404 でもエラー JSON を stdout に出すため、出力の空判定では
    # なく終了状態で分岐する（|| true で握りつぶすと全リポジトリが対象になる）
    if ! sha=$(gh api "repos/${ORG}/${name}/contents/${TARGET_PATH}" \
        --jq '.sha' 2>/dev/null); then
        continue
    fi
    if [ -z "$sha" ] || [ "$sha" = "null" ]; then
        continue
    fi

    if [ "$archived" = "true" ]; then
        skipped_archived=$((skipped_archived + 1))
        log "  skip (archived): ${name}"
        continue
    fi

    if [ "$APPLY" != "true" ]; then
        log "  target: ${name}"
        removed=$((removed + 1))
        continue
    fi

    branch=$(gh api "repos/${ORG}/${name}" --jq '.default_branch')
    if gh api -X DELETE "repos/${ORG}/${name}/contents/${TARGET_PATH}" \
        -f "message=${COMMIT_MESSAGE}" \
        -f "sha=${sha}" \
        -f "branch=${branch}" >/dev/null 2>&1; then
        removed=$((removed + 1))
        log "  removed: ${name} (${branch})"
    else
        errors=$((errors + 1))
        error_repos="${error_repos}${name} "
        log "  ERROR: ${name} — 削除できなかった（権限・保護設定を確認）"
    fi
done <<EOF
$repos
EOF

log "---"
if [ "$APPLY" = "true" ]; then
    log "削除: ${removed} 件"
else
    log "削除対象: ${removed} 件（--apply で実行）"
fi
log "スキップ (archived): ${skipped_archived} 件"
if [ "$errors" -gt 0 ]; then
    log "エラー: ${errors} 件 — ${error_repos}"
    exit 1
fi
