#!/bin/bash
#
# README.md の著者情報を draft ブランチから main へ同期する
#
# 学生リポジトリの main は、提出時の最終 merge まで draft の内容を受け取らない。
# 実測では大半のリポジトリで提出時にも受け取っていない（最終 PR が未 merge で
# 閉じられる）。一方テンプレートの README.md は「このファイルは自分のリポジトリ
# のトップページに表示されます」と書いており、トップページが表示するのは default
# branch すなわち main なので、執筆期間中はテンプレートのプレースホルダが出続ける。
# 詳しい実測は smkwlab/latex-ecosystem#191 を参照。
#
# 設計
#   - draft ブランチを README.md の権威とし、main はそれを写すだけにする
#   - 学生リポジトリ側には何も置かない。秘密を配らずに済み、既存リポジトリへの
#     workflow 伝播（/propagate）も要らない
#   - main への push は GitHub App のレビュー要件バイパスで通す。設定するのは
#     scripts/setup-branch-protection.sh（AUTOMATION_APP_SLUG）で、このスクリプト
#     は設定の有無を確認するだけで、保護そのものは変更しない
#   - 著者名のプレースホルダが残っているうちは名簿から埋める。学生が一度でも
#     書き換えたら、以後そこには触らない
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
#   AUTOMATION_APP_SLUG main のレビュー要件をバイパスできる GitHub App の slug。
#                       これが設定されていない main へは push できないため、
#                       そのリポジトリは報告してスキップする
#
# 必要な権限:
#   対象リポジトリへの contents: write、名簿とレジストリへの contents: read、
#   ブランチ保護の確認に administration: read。
#   **main を更新するので、AUTOMATION_APP_SLUG の App のトークンで実行すること。**
#   個人トークンでも main の保護を越えられる場合があるが（管理者は
#   enforce_admins: false で越えられる）、人の操作と自動化の履歴が混ざるため避ける。

set -eu

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
ROSTER_AVAILABLE=false

# 年度（4月〜3月）。thesis-report の collect-progress.sh と同じ計算にそろえる。
# ずれると名簿を引く年度が変わり、氏名が引けなくなる。
fiscal_year() {
    local month year
    month=$(TZ='Asia/Tokyo' date +%-m)
    year=$(TZ='Asia/Tokyo' date +%Y)
    if [ "$month" -ge 4 ]; then
        echo "$year"
    else
        echo $((year - 1))
    fi
}

# 名簿を取得する。無くても同期自体は続ける（氏名の補完だけが効かなくなる）。
load_roster() {
    local path="${ROSTER_PATH:-$(fiscal_year)/students.csv}"

    if gh api "repos/${ROSTER_REPO}/contents/${path}" \
        -H "Accept: application/vnd.github.raw" > "$ROSTER_FILE" 2>/dev/null; then
        ROSTER_AVAILABLE=true
        log "名簿: ${ROSTER_REPO}/${path}（$(wc -l < "$ROSTER_FILE" | tr -d ' ') 行）"
    else
        warn "名簿を取得できません: ${ROSTER_REPO}/${path}"
        warn "氏名の補完はスキップし、draft → main の同期のみ行います"
    fi
}

# 学籍番号から氏名を引く。
#
# 名簿は学部の学籍番号と大学院の学籍番号を別の列に持つ。大学院生の行は学部の
# 学籍番号も併せ持つため、リポジトリ名から引くときは課程に応じて見る列を変える
# 必要がある。この規則は thesis-report の collect-progress.sh と同じ。
#   - 学部（rs / jk）: 3 列目
#   - 大学院（gjk）  : 2 列目
# 氏名は 4 列目。先頭の 'k' を落として大文字化した形で突き合わせる。
lookup_author() {
    local student_id="$1" normalized column

    [ "$ROSTER_AVAILABLE" = true ] || return 0

    normalized=$(printf '%s' "$student_id" | sed 's/^[kK]//' | tr '[:lower:]' '[:upper:]')
    case "$normalized" in
        *GJK*) column=2 ;;
        *)     column=3 ;;
    esac

    awk -F',' -v id="$normalized" -v c="$column" \
        '$c == id { gsub(/"/, "", $4); print $4; exit }' "$ROSTER_FILE"
}

# 最新の draft ブランチ名（0th-draft, 1st-draft, ... のうち序数が最大のもの）。
# 学生が執筆しているのは常に最新の draft であり、そこが README.md の権威になる。
latest_draft_branch() {
    local repo="$1"

    gh api "repos/${repo}/branches" --paginate --jq '.[].name' 2>/dev/null \
        | awk '/^[0-9]+(st|nd|rd|th)-draft$/ { ordinal = $0; sub(/[^0-9].*$/, "", ordinal); print ordinal, $0 }' \
        | sort -k1,1n \
        | tail -1 \
        | cut -d' ' -f2
}

# main のレビュー要件をバイパスできる App が設定されているか。
# 0: push できる（バイパス設定済み、または保護そのものが無い）
# 1: push できない
can_push_to_main() {
    local repo="$1" protection

    if ! protection=$(gh api "repos/${repo}/branches/main/protection" 2>/dev/null); then
        # 保護が無いリポジトリ。レビュー要件も無いので push できる
        return 0
    fi

    if [ -z "${AUTOMATION_APP_SLUG:-}" ]; then
        return 1
    fi

    printf '%s' "$protection" \
        | jq -e --arg slug "$AUTOMATION_APP_SLUG" \
            '[.required_pull_request_reviews.bypass_pull_request_allowances.apps[]?.slug]
             | index($slug) != null' >/dev/null 2>&1
}

# README.md をそのブランチから取り出す。無ければ非ゼロ。
fetch_readme() {
    local repo="$1" ref="$2" out="$3"

    gh api "repos/${repo}/contents/README.md?ref=${ref}" \
        -H "Accept: application/vnd.github.raw" > "$out" 2>/dev/null
}

# README.md の blob SHA（contents API の更新に必要）。無ければ空。
readme_sha() {
    local repo="$1" ref="$2"

    gh api "repos/${repo}/contents/README.md?ref=${ref}" --jq '.sha' 2>/dev/null || true
}

# ファイルを contents API で push する。
put_readme() {
    local repo="$1" branch="$2" file="$3" message="$4" sha="$5"
    local encoded

    # base64 の折り返し指定は環境差がある（GNU の -w0 は macOS に無い）ため、
    # 改行を後から落とす形にそろえる。
    encoded=$(base64 < "$file" | tr -d '\n')

    local args=(
        -X PUT "repos/${repo}/contents/README.md"
        -f "message=${message}"
        -f "content=${encoded}"
        -f "branch=${branch}"
    )
    [ -n "$sha" ] && args+=(-f "sha=${sha}")

    gh api "${args[@]}" --jq '.commit.sha' >/dev/null
}

# プレースホルダを名簿の値で埋める。
#
# 6 つのテンプレートすべてが同じプレースホルダ（（氏名）と（k00rs000））を使って
# いるため、置換は文字列一致で足りる。種別や所属は選択肢の削除を学生に委ねている
# ので触らない（機械的に決まるのは氏名と学籍番号だけ）。
fill_placeholders() {
    local name="$1" student_id="$2" in="$3" out="$4"

    # gsub は使わない。gsub の置換文字列では & が「一致した文字列」を意味し、
    # -v での代入時にもエスケープが一段解釈されるため、氏名に & が入ると二重に
    # 壊れる（"A & B" が "A （氏名） B" になる）。split して連結すれば置換文字列
    # の解釈が入らないので、氏名をそのまま埋められる。
    awk -v name="$name" -v id="$student_id" '
        function replace(s, from, to,    parts, out, i, n) {
            n = split(s, parts, from)
            out = parts[1]
            for (i = 2; i <= n; i++) out = out to parts[i]
            return out
        }
        {
            line = replace($0, "（氏名）", name)
            line = replace(line, "（k00rs000）", id)
            print line
        }
    ' "$in" > "$out"
}

sync_repository() {
    local repo_name="$1"
    local repo="${OWNER}/${repo_name}"
    local draft desired main_readme sha student_id author

    draft=$(latest_draft_branch "$repo")
    if [ -z "$draft" ]; then
        log "  draft ブランチが無いためスキップ: $repo_name"
        return 0
    fi

    desired="$WORK_DIR/desired-readme.md"
    if ! fetch_readme "$repo" "$draft" "$desired"; then
        log "  $draft に README.md が無いためスキップ: $repo_name"
        return 0
    fi

    # 1. 氏名のプレースホルダが残っているなら名簿から埋め、draft に push する。
    #    draft を権威とする設計なので、補完も draft 側へ行う。
    if grep -q '（氏名）' "$desired"; then
        student_id="${repo_name%%-*}"
        author=$(lookup_author "$student_id")

        if [ -n "$author" ]; then
            local filled="$WORK_DIR/filled-readme.md"
            fill_placeholders "$author" "$student_id" "$desired" "$filled"

            if [ "$DRY_RUN" = true ]; then
                log "  [dry-run] $draft の著者情報を名簿から補完する"
            else
                put_readme "$repo" "$draft" "$filled" \
                    "docs: fill in the author information from the lab roster" \
                    "$(readme_sha "$repo" "$draft")"
                success "  $draft の著者情報を名簿から補完した"
            fi
            mv "$filled" "$desired"
        else
            log "  名簿に $student_id の行が無いため著者情報の補完をスキップ"
        fi
    fi

    # 2. main が draft と違うなら、draft の内容を main に写す。
    main_readme="$WORK_DIR/main-readme.md"
    if fetch_readme "$repo" main "$main_readme" && cmp -s "$desired" "$main_readme"; then
        log "  main は $draft と一致している: $repo_name"
        return 0
    fi

    if ! can_push_to_main "$repo"; then
        warn "  main の保護にバイパスが無いため push できない: $repo_name"
        warn "    scripts/setup-branch-protection.sh --update $repo_name で設定する"
        return 1
    fi

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] $draft の README.md を main に写す: $repo_name"
        return 0
    fi

    sha=$(readme_sha "$repo" main)
    put_readme "$repo" main "$desired" \
        "docs: mirror README.md from ${draft} onto main" "$sha"
    success "  $draft の README.md を main に写した: $repo_name"
}

# レジストリから対象リポジトリを列挙する。
#
# review_flow が true のものだけを対象にする。draft ブランチ階層を使うのはこれら
# で、main が執筆期間中ずっと置き去りになるのも これらだけである。
list_targets() {
    gh api "repos/${REGISTRY_REPO}/contents/data/registry.json" \
        -H "Accept: application/vnd.github.raw" \
        | jq -r 'to_entries[]
                 | select(.value.review_flow == true)
                 | select(.value.archived_at == null)
                 | .key'
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
        if ! listed=$(list_targets); then
            error "レジストリを読めません: ${REGISTRY_REPO}"
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

    if [ -z "${AUTOMATION_APP_SLUG:-}" ]; then
        warn "AUTOMATION_APP_SLUG が未設定です。保護された main へは push できません"
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
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
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
