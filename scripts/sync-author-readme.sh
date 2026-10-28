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
# #577 が「Actions がバイパスする必要は無い」として消したレビュー要件のバイパスを
# 復活させる必要がある。作成時に埋めるならブランチ保護を掛ける前なので、バイパス
# そのものが要らない。後追いの 1 回だけなら、教員の管理者権限で足りる。
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
ROSTER_AVAILABLE=false

# gh の stderr の置き場。ファイルが無いことと要求が失敗したことは、どちらも gh を
# 非ゼロで終わらせる。見分けられるのは stderr だけである
# （thesis-report の collect-progress.sh と同じ理由・同じ手）
API_ERR="$WORK_DIR/api-err.txt"

# 直近の fetch_readme が取った README.md の blob SHA。成功時のみ設定される。
FETCHED_SHA=""

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

    # 契約: 引けたら氏名を標準出力に書き、引けなければ何も書かない。名簿が無い
    # 場合も「引けなかった」と同じ扱いにする（呼び出し側は空かどうかだけを見る）。
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

# README.md をそのブランチから取り出し、blob SHA を FETCHED_SHA に置く。
#
# 内容と SHA を 1 回の呼び出しで取るのが要点である。別々に取ると、その間に
# push された場合に「新しい SHA + 古い内容」で上書きすることになり、学生の
# commit を失う。同じ応答から取った SHA を使えば、ブランチが動いていた場合は
# PUT が 409 で失敗する。取り違えて上書きするより、失敗するほうが良い。
#
# 「無い」と「取得できなかった」は呼び出し側が区別できるように返り値を分ける。
# ひとまとめにすると、一時的な 5xx や認証の失敗が「README.md が無い」と読めて
# しまい、黙ってスキップされる。
#   0: 取得できた（FETCHED_SHA にその時点の SHA が入る）
#   1: そのブランチに README.md が無い（404）
#   2: 取得に失敗した（それ以外）
fetch_readme() {
    local repo="$1" ref="$2" out="$3" json

    FETCHED_SHA=""

    if ! json=$(gh api "repos/${repo}/contents/README.md?ref=${ref}" 2>"$API_ERR"); then
        # gh 2.103.2 の文面は `gh: Not Found (HTTP 404)`。この判定は「HTTP 404」
        # だけに絞る。緩めると、リポジトリやブランチが無いことによる 404 まで
        # 「README.md が無い」と読んで**成功として数える**ことになる。逆に gh の
        # 文面が将来変わった場合は、ここを素通りして「取得に失敗」になり、
        # 非ゼロ終了して気付ける。読み違えるより騒がしく失敗するほうが良い
        if grep -q "HTTP 404" "$API_ERR"; then
            return 1
        fi
        error "  README.md を取得できない (${repo}@${ref}): $(tr '\n' ' ' < "$API_ERR")"
        return 2
    fi

    FETCHED_SHA=$(printf '%s' "$json" | jq -r '.sha')

    # content は base64 で、改行を挟んで返る。復号に openssl を使うのは
    # base64(1) の復号オプションが環境で揺れるため（GNU は -d、BSD は -D）。
    #
    # -A は外せない。openssl base64 -d は -A が無いと入力が 64 文字で折り返されて
    # いる前提で読むので、tr -d '\n' で 1 行にしたものを渡すと **何も出さずに
    # 成功する**（空の README.md を main に push することになる）。tr で 1 行に
    # しているからこそ -A が要るという関係で、どちらも冗長ではない。
    printf '%s' "$json" | jq -r '.content' | tr -d '\n' | openssl base64 -d -A > "$out"
}

# ファイルを contents API で push する。
#
# sha が空のときは SHA を送らない。contents API はこれを新規作成として扱うので、
# 「そのブランチに README.md が無い」場合の作成経路がこれになる。既存ファイルに
# 対して空で呼ぶと 422 になるため、呼び出し側は取得の成否で存在を確かめてから渡す。
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

    # 失敗の原因（保護・SHA の衝突・権限）は gh の文面にしか出ない。どのリポジトリの
    # どのブランチで起きたかを添えないと、27 件を回したログから特定できない
    if ! gh api "${args[@]}" --jq '.commit.sha' >/dev/null 2>"$API_ERR"; then
        error "  README.md を push できない (${repo}@${branch}): $(tr '\n' ' ' < "$API_ERR")"
        return 1
    fi
}

# プレースホルダを名簿の値で埋める。
#
# 6 つのテンプレートすべてが同じプレースホルダ（（氏名）と（k00rs000））を使って
# いるため、置換は文字列一致で足りる。種別や所属は選択肢の削除を学生に委ねている
# ので触らない（機械的に決まるのは氏名と学籍番号だけ）。
#
# 埋める学籍番号はリポジトリ名の先頭部分そのままで、`k` 付きの小文字である
# （例: k23rs017）。プレースホルダ側も `k` 付きの小文字なので形式が揃う。
# lookup_author が `k` を落として大文字化するのは名簿の列に合わせるためだけで、
# README に書く表記とは別物である。
fill_placeholders() {
    local name="$1" student_id="$2" in="$3" out="$4"

    # gsub も split も使わない。どちらも正規表現を経由するため、置換の両側で
    # 文字列が解釈される。
    #   - gsub の置換文字列では & が「一致した文字列」を意味し、-v の代入でも
    #     エスケープが一段消えるので、& を含む氏名が二重に壊れる
    #     （"A & B" が "A （氏名） B" になる）。実際に踏んで直した
    #   - split の第 3 引数は正規表現として解釈される。現在のプレースホルダは
    #     全角括弧なので実害は無いが、ASCII のメタ文字を含む形に変えた途端に壊れる
    # index と substr で回せば、from 側も to 側も解釈が入らない。
    awk -v name="$name" -v id="$student_id" '
        function replace(s, from, to,    out, pos, flen) {
            out = ""
            flen = length(from)
            while ((pos = index(s, from)) > 0) {
                out = out substr(s, 1, pos - 1) to
                s = substr(s, pos + flen)
            }
            return out s
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
    local draft desired main_readme student_id author
    local draft_sha main_sha status

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
        student_id="${repo_name%%-*}"
        author=$(lookup_author "$student_id")

        if [ -n "$author" ]; then
            local filled="$WORK_DIR/filled-readme.md"
            fill_placeholders "$author" "$student_id" "$desired" "$filled"

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
        else
            log "  名簿に $student_id の行が無いため著者情報の補完をスキップ"
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
