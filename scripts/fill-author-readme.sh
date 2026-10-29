#!/bin/bash
#
# 作成直後の学生リポジトリの README.md に著者情報を書き込む
#
# テンプレートの README.md は著者情報をプレースホルダで持つ。これを学生に
# 書かせる設計だと、draft サイクルを使うリポジトリでは main に届かない
# （main が draft の内容を受け取るのは提出時の最終 merge だけで、実測では
# 大半のリポジトリで提出時にも受け取っていない）。GitHub がトップページに
# 出すのは default branch なので、執筆期間中はプレースホルダが出続ける。
# 詳しい実測は smkwlab/latex-ecosystem#191 を参照。
#
# そこで作成時に埋める。学籍番号と作成日から決まる値だけなので、学生に
# 入力させるものは無い。
#
# ブランチ保護を掛ける前に実行すること。保護後に main へ書くには、#577 で
# 「Actions がバイパスする必要は無い」と結論して #578 が消したレビュー要件の
# バイパスを復活させる必要がある。保護前なら、その概念自体が登場しない。
#
# Usage:
#   ./fill-author-readme.sh [--dry-run] <repository_name>
#
# Options:
#   --dry-run   書き込む内容を表示するだけで push しない
#
# Environment:
#   REPO_OWNER   対象 owner（default: smkwlab）
#   ROSTER_REPO  氏名の名簿を持つリポジトリ（default: <owner>/thesis-report）
#   ROSTER_PATH  名簿のパス（default: <年度>/students.csv）
#
# 必要な権限:
#   対象リポジトリへの contents: write、名簿への contents: read。
#   process-pending-issues.sh から呼ばれる場合は GitHub App の installation
#   token で足りる（この org の installation は repository_selection: all で
#   contents: write を持つため、名簿も対象リポジトリも同じトークンで届く）。
#
# 終了コード:
#   0  書き込んだ、または書き込むものが無かった
#   1  取得や push に失敗した、あるいは著者情報を決められず埋められなかった

set -euo pipefail

OWNER="${REPO_OWNER:-smkwlab}"
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
API_ERR="$WORK_DIR/api-err.txt"

# 名簿の引き方とプレースホルダの置換は、後追いで埋める sync-author-readme.sh と
# 同じでなければならない（違うと同じリポジトリを 2 回処理したときに内容が揺れる）。
# shellcheck source=scripts/lib/author-readme.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/author-readme.sh"

# 書き込む対象のブランチ。
#
# main だけでは足りない。draft サイクルのリポジトリでは学生が 0th-draft で
# 作業するので、そちらを埋めないと提出時の最終 merge で main がプレースホルダに
# 戻る。逆に 0th-draft だけでも足りない（それが #191 の症状そのものである）。
# draft サイクルを使わないリポジトリには 0th-draft が無く、その場合は 404 で
# 飛ばされる。
TARGET_BRANCHES=(main 0th-draft)

# main に渡されたリポジトリ名。ensure_values が報告に使う
REPO_NAME_ARG=""

# ensure_values の結果。"" 未試行 / ok / ng
VALUES_STATE=""

# 埋める値をそろえる。何度呼んでも名簿を引くのは 1 回だけ。
#
# 名簿を引くのは、埋める必要のあるブランチが実際に見つかってからにする。先に
# 引くと、著者情報が既に入っているリポジトリ（学生が書き換えた、作成フローが
# 既に埋めた）を手で再実行したときに、名簿に行が無いだけで失敗する。実測で
# 踏んだ: 現行の review_flow リポジトリには、今年度の名簿に行が無いものがある。
#
# 0: そろった
# 1: そろわない（理由は報告済み）
ensure_values() {
    local values_status=0

    # 失敗も覚える。覚えずに戻ると、2 つ目のブランチでもう一度名簿を取りに行き、
    # 同じ警告を 2 回出すことになる
    case "$VALUES_STATE" in
        ok) return 0 ;;
        ng) return 1 ;;
    esac
    VALUES_STATE=ng

    load_roster
    author_readme_values "$REPO_NAME_ARG" || values_status=$?
    case "$values_status" in
        0) ;;
        1)
            # main で先に落としているので通らない。契約が変わったときに黙って
            # 名簿を引かずに進まないよう、保険として残す
            error "リポジトリ名から学籍番号を取り出せない: $REPO_NAME_ARG"
            return 1
            ;;
        2)
            # load_roster が直前に「名簿を取得できません: <repo>/<path>」を
            # 出している。ここで同じことを繰り返さず、その結果と次の手だけ言う
            error "著者情報を記入できなかった"
            error "  名簿が読めるようになってから ./scripts/sync-author-readme.sh ${REPO_NAME_ARG} を実行する"
            return 1
            ;;
        3)
            error "名簿に ${AR_STUDENT_ID} の行が無いため著者情報を埋められない"
            error "  名簿を直してから ./scripts/sync-author-readme.sh ${REPO_NAME_ARG} を実行する"
            return 1
            ;;
        *)
            # 返り値が増えたときに、既存のどれかの文面で黙って処理されないように
            error "author_readme_values が予期しない値を返した: $values_status"
            return 1
            ;;
    esac

    VALUES_STATE=ok
    log "${REPO_NAME_ARG}: ${AR_NAME}（${AR_STUDENT_ID}）${AR_KIND:+ / ${AR_KIND}} / ${AR_AFFILIATION} / ${AR_YEAR}年度"
}

fill_branch() {
    local repo="$1" branch="$2"
    local current="$WORK_DIR/current-${branch}.md"
    local filled="$WORK_DIR/filled-${branch}.md"
    local status=0 sha

    fetch_readme "$repo" "$branch" "$current" || status=$?
    case "$status" in
        0) sha="$FETCHED_SHA" ;;
        1)
            log "  $branch に README.md が無いためスキップ"
            return 0
            ;;
        *)
            return 1
            ;;
    esac

    # 氏名のプレースホルダが無いなら、埋める対象ではない（既に埋まっているか、
    # 著者情報を持たない README である）。作成直後に 2 回実行されても、
    # 1 回目で消えるので 2 回目は何もしない
    if ! grep -q '（氏名）' "$current"; then
        log "  $branch の著者情報は既に埋まっている"
        return 0
    fi

    ensure_values || return 1

    fill_placeholders "$current" "$filled" || return 1

    # 自分の種別に関係ない「執筆するファイル」の行を落とす。種別が決まらない
    # 場合（AR_KIND が空）は prune_file_list が素通しするので、ここでは分けない
    local pruned="$WORK_DIR/pruned-${branch}.md"
    prune_file_list "$filled" "$pruned" "$AR_KIND" || return 1
    mv "$pruned" "$filled"

    if [ "$DRY_RUN" = true ]; then
        log "  [dry-run] $branch に書き込む内容:"
        # 変わった行だけを見せる。README 全体を出すと、数十行のうち数行しか
        # 変わらないことが読み取れない
        diff "$current" "$filled" | sed 's/^/    /' || true
        return 0
    fi

    # 内容と同じ応答から取った SHA を渡す。間に push があった場合、PUT は
    # 409 で失敗する。取り違えて上書きするより、失敗するほうが良い
    put_readme "$repo" "$branch" "$filled" \
        "docs: fill in the author information" "$sha" || return 1

    success "  $branch の著者情報を書き込んだ"
}

main() {
    REPO_NAME_ARG="$1"

    # 1 リポジトリ専用のスクリプトなので 1 回しか通らないが、ここで消しておけば、
    # 将来ループで複数リポジトリを回す形に変えたときに前の判定結果を引き継がない。
    # AR_* は author_readme_values が入口で全部消すので、ここで触る必要は無い
    # （消すのを一部だけにすると、消した変数と残った変数で食い違う）
    VALUES_STATE=""
    local repo="${OWNER}/${REPO_NAME_ARG}"
    local failures=0 branch

    require_tools || exit 1

    if ! gh auth status >/dev/null 2>&1; then
        error "GitHub CLI is not authenticated"
        exit 1
    fi

    # 学籍番号を名前に持たないリポジトリ（個人モードで作られたもの）は対象外。
    # API を叩く前に落とす。叩いてから落とすと、owner の下に無いリポジトリ名で
    # 「リポジトリを取得できない」という的を外した失敗になる
    if [ -z "$(student_id_from_repo_name "$REPO_NAME_ARG")" ]; then
        log "リポジトリ名から学籍番号を取り出せないためスキップ: $REPO_NAME_ARG"
        exit 0
    fi

    # リポジトリの存在を先に確かめる。確かめずに README を取ると、リポジトリが
    # 無いことによる 404 が「README.md が無い」と読めて、全ブランチがスキップ
    # され、成功として終わってしまう
    if ! gh api "repos/${repo}" --jq '.name' >/dev/null 2>"$API_ERR"; then
        error "リポジトリを取得できない (${repo}): $(tr '\n' ' ' < "$API_ERR")"
        exit 1
    fi

    for branch in "${TARGET_BRANCHES[@]}"; do
        if ! fill_branch "$repo" "$branch"; then
            failures=$((failures + 1))
        fi
    done

    if [ "$failures" -gt 0 ]; then
        error "$failures ブランチで書き込めませんでした"
        exit 1
    fi
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            # 先頭のコメント群をそのまま出す。行番号で切ると、ヘッダに
            # 行を足したときにヘルプが途中で切れる
            awk 'NR == 1 { next }
                 /^#/ { sub(/^# ?/, ""); print; next }
                 { exit }' "$0"
            exit 0
            ;;
        -*)
            error "不明なオプション: $1"
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

if [ "$#" -ne 1 ]; then
    error "リポジトリ名を 1 つ指定してください"
    error "Usage: $0 [--dry-run] <repository_name>"
    exit 1
fi

main "$1"
