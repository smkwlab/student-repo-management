#!/bin/bash
#
# 既存の学生リポジトリの README.md を draft ブランチから main へ流し込む
#
# 学生リポジトリの main は、提出時の最終 merge まで draft の内容を受け取らない。
# 実測では大半のリポジトリで提出時にも受け取っていない（最終 PR が未 merge で
# 閉じられる）。一方テンプレートの README.md は「このファイルは自分のリポジトリ
# のトップページに表示されます」と書いており、トップページが表示するのは default
# branch すなわち main なので、執筆期間中はテンプレートのプレースホルダが出続ける。
# 詳しい実測は smkwlab/latex-ecosystem#191 を参照。
#
# これは人が必要なときに回す後追いの用具であり、定期実行はしない。新規リポジトリ
# では作成フローが著者情報を埋めるので、対象になるのはその仕組みより前に作られた
# 既存リポジトリである。
#
# 定期実行にしない理由: 保護された main へ push できる主体を常設することになり、
# #577 で「Actions がバイパスする必要は無い」と結論して #578 が消したレビュー要件
# のバイパスを復活させる必要がある。作成時に埋めるならブランチ保護を掛ける前なので、
# バイパスそのものが要らない。後追いの 1 回だけなら、教員の管理者権限で足りる。
#
# 設計
#   - draft ブランチを README.md の権威とし、main はそれを写すだけにする
#   - 著者名のプレースホルダが残っているうちは名簿から埋める。学生が一度でも
#     書き換えたら、以後そこには触らない
#   - 保護された main へは管理者権限のトークンで push する。学生リポジトリの保護は
#     enforce_admins: false なので、管理者は PR を介さずに push できる
#
# Usage:
#   ./sync-author-readme.sh [--dry-run] [<repository_name> ...]
#
#   引数を省略すると、レジストリの review_flow が true で未 archive の
#   リポジトリすべてを対象にする。
#
# Options:
#   --dry-run   変更内容を表示するだけで push しない
#
# Environment:
#   REPO_OWNER          対象 owner（default: smkwlab）
#   REGISTRY_REPO       レジストリ（default: <owner>/thesis-student-registry）
#   ROSTER_REPO         氏名の名簿を持つリポジトリ（default: <owner>/thesis-report）
#   ROSTER_PATH         名簿のパス（default: <年度>/students.csv）
#
# 必要な権限:
#   対象リポジトリへの admin（保護された main へ push するため）、名簿とレジストリ
#   への contents: read、ブランチ保護の確認に administration: read。
#   教員が gh auth login したトークンで実行することを前提にしている。

set -euo pipefail

OWNER="${REPO_OWNER:-smkwlab}"
REGISTRY_REPO="${REGISTRY_REPO:-${OWNER}/thesis-student-registry}"
ROSTER_REPO="${ROSTER_REPO:-${OWNER}/thesis-report}"

DRY_RUN=false

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARNING]${NC} $1"; }

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

ROSTER_FILE="$WORK_DIR/roster.csv"

# gh の stderr の置き場。ファイルが無いことと要求が失敗したことは、どちらも gh を
# 非ゼロで終わらせる。見分けられるのは stderr だけである
# （thesis-report の collect-progress.sh と同じ理由・同じ手）
API_ERR="$WORK_DIR/api-err.txt"

# 名簿の引き方とプレースホルダの置換は、作成時に埋める fill-author-readme.sh と
# 同じでなければならない（違うと同じリポジトリを 2 回処理したときに内容が揺れる）。
# shellcheck source=scripts/lib/author-readme.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/author-readme.sh"

# 最新の draft ブランチ名（0th-draft, 1st-draft, ... のうち序数が最大のもの）。
# 学生が執筆しているのは常に最新の draft であり、そこが README.md の権威になる。
#
# 取得に失敗したときは非ゼロで終わる。空を返して「draft が無い」と同じ扱いにすると、
# 消えた・改名されたリポジトリや一時的な障害がスキップとして成功に数えられてしまう。
latest_draft_branch() {
    local repo="$1" branches="$WORK_DIR/branches.txt"

    if ! gh api "repos/${repo}/branches" --paginate --jq '.[].name' \
        > "$branches" 2>"$API_ERR"; then
        error "  ブランチ一覧を取得できない (${repo}): $(tr '\n' ' ' < "$API_ERR")"
        return 1
    fi

    awk '/^[0-9]+(st|nd|rd|th)-draft$/ { ordinal = $0; sub(/[^0-9].*$/, "", ordinal); print ordinal, $0 }' \
        "$branches" \
        | sort -k1,1n \
        | tail -1 \
        | cut -d' ' -f2
}

# 保護された main へ、このトークンで push できるか。
# 0: push できる
# 1: push できない
can_push_to_main() {
    local repo="$1" protection is_admin

    if ! protection=$(gh api "repos/${repo}/branches/main/protection" 2>/dev/null); then
        # 保護が無いリポジトリ。レビュー要件も無いので push できる
        return 0
    fi

    # 保護があってもレビュー必須でなければ（ステータスチェックのみなど）
    # 管理者権限は要らない。レビュー要件の有無を見ずに判定すると、そうした保護の
    # リポジトリを push できないものとして過剰にスキップしてしまう
    if ! printf '%s' "$protection" \
        | jq -e '.required_pull_request_reviews != null' >/dev/null 2>&1; then
        return 0
    fi

    # 学生リポジトリの保護は enforce_admins: false なので、管理者は PR を介さずに
    # push できる。有効化されている場合は管理者でも越えられない
    if printf '%s' "$protection" \
        | jq -e '.enforce_admins.enabled == true' >/dev/null 2>&1; then
        return 1
    fi

    is_admin=$(gh api "repos/${repo}" --jq '.permissions.admin // false' 2>/dev/null) || return 1
    [ "$is_admin" = true ]
}

sync_repository() {
    local repo_name="$1"
    local repo="${OWNER}/${repo_name}"
    local draft desired main_readme
    local draft_sha main_sha status values_status

    draft=$(latest_draft_branch "$repo") || return 1
    if [ -z "$draft" ]; then
        log "  draft ブランチが無いためスキップ: $repo_name"
        return 0
    fi

    # main に書けないことが分かっているなら、何も変えずに止める。draft への補完を
    # 先に走らせると、補完だけ済んで main に届かないという中途半端な状態になる
    if ! can_push_to_main "$repo"; then
        warn "  main の保護を越えられないため push できない: $repo_name"
        warn "    対象リポジトリの管理者権限を持つトークンで実行する"
        return 1
    fi

    desired="$WORK_DIR/desired-readme.md"
    status=0
    fetch_readme "$repo" "$draft" "$desired" || status=$?
    case "$status" in
        0) draft_sha="$FETCHED_SHA" ;;
        1)
            log "  $draft に README.md が無いためスキップ: $repo_name"
            return 0
            ;;
        *)
            return 1
            ;;
    esac

    # 1. 氏名のプレースホルダが残っているなら名簿から埋め、draft に push する。
    #    draft を権威とする設計なので、補完も draft 側へ行う。
    if grep -q '（氏名）' "$desired"; then
        values_status=0
        author_readme_values "$repo_name" || values_status=$?

        if [ "$values_status" = 0 ]; then
            local filled="$WORK_DIR/filled-readme.md"
            if ! fill_placeholders "$desired" "$filled"; then
                return 1
            fi

            if [ "$DRY_RUN" = true ]; then
                log "  [dry-run] $draft の著者情報を名簿から補完する"
            else
                # 内容と同じ応答から取った SHA を渡す。学生がこの数秒の間に
                # draft へ push していた場合、PUT は 409 で失敗する。学生の
                # commit を上書きするより、失敗して次回に回すほうが良い
                put_readme "$repo" "$draft" "$filled" \
                    "docs: fill in the author information from the lab roster" \
                    "$draft_sha"
                success "  $draft の著者情報を名簿から補完した"
            fi

            # dry-run でも採用する。この後の main との比較を、実行したときと同じ
            # 内容で行うため。ここで分けると dry-run だけ「main と一致」と報告して
            # しまい、実行結果を予告できなくなる
            mv "$filled" "$desired"
        elif [ "$values_status" = 1 ]; then
            log "  リポジトリ名から学籍番号を取り出せないため補完をスキップ: $repo_name"
        else
            log "  名簿に ${AR_STUDENT_ID} の行が無いため著者情報の補完をスキップ"
        fi
    fi

    # 2. main が draft と違うなら、draft の内容を main に写す。
    main_readme="$WORK_DIR/main-readme.md"
    main_sha=""
    status=0
    fetch_readme "$repo" main "$main_readme" || status=$?
    case "$status" in
        0)
            main_sha="$FETCHED_SHA"
            if cmp -s "$desired" "$main_readme"; then
                log "  main は $draft と一致している: $repo_name"
                return 0
            fi
            ;;
        1)
            # main に README.md が無い。SHA 無しの PUT で作成する
            ;;
        *)
            return 1
            ;;
    esac

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] $draft の README.md を main に写す: $repo_name"
        return 0
    fi

    put_readme "$repo" main "$desired" \
        "docs: mirror README.md from ${draft} onto main" "$main_sha"
    success "  $draft の README.md を main に写した: $repo_name"
}

# レジストリから対象リポジトリを列挙する。
#
# review_flow が true のものだけを対象にする。draft ブランチ階層を使うのはこれら
# で、main が執筆期間中ずっと置き去りになるのも これらだけである。
list_targets() {
    local registry="$WORK_DIR/registry.json"

    # 取得と解釈を分ける。1 本のパイプにすると、レジストリが読めないのか中身の
    # 形が変わったのかが同じエラーに潰れ、原因の切り分けができない
    if ! gh api "repos/${REGISTRY_REPO}/contents/data/registry.json" \
        -H "Accept: application/vnd.github.raw" > "$registry" 2>"$API_ERR"; then
        error "レジストリを取得できない (${REGISTRY_REPO}): $(tr '\n' ' ' < "$API_ERR")"
        return 1
    fi

    if ! jq -r 'to_entries[]
                | select(.value.review_flow == true)
                | select(.value.archived_at == null)
                | .key' "$registry" 2>"$API_ERR"; then
        error "レジストリの形が想定と違う (${REGISTRY_REPO}): $(tr '\n' ' ' < "$API_ERR")"
        return 1
    fi
}

main() {
    local targets=() failures=0

    if ! gh auth status >/dev/null 2>&1; then
        error "GitHub CLI is not authenticated"
        exit 1
    fi

    if [ "$#" -gt 0 ]; then
        targets=("$@")
        log "対象: 引数で指定された ${#targets[@]} リポジトリ"
    else
        local listed
        # 失敗の内容は list_targets が具体的に報告している
        if ! listed=$(list_targets); then
            exit 1
        fi
        if [ -z "$listed" ]; then
            warn "レジストリに review_flow が true のリポジトリがありません"
            exit 0
        fi
        while IFS= read -r line; do
            targets+=("$line")
        done <<< "$listed"
        log "対象: レジストリの review_flow が true な ${#targets[@]} リポジトリ"
    fi

    load_roster

    local repo_name
    for repo_name in "${targets[@]}"; do
        log "$repo_name"
        if ! sync_repository "$repo_name"; then
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -gt 0 ]; then
        error "$failures リポジトリで同期できませんでした"
        exit 1
    fi

    success "同期が完了しました（${#targets[@]} リポジトリ）"
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            # 先頭のコメントブロックをそのまま出す。shebang を飛ばし、コメントで
            # ない行に当たったら止める（行数を固定すると、説明を増やしたときに
            # 途中で切れる）
            awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
            exit 0
            ;;
        --*)
            error "Unknown option: $1"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

main "$@"
