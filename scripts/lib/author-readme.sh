# shellcheck shell=bash
#
# 著者 README（学生リポジトリのトップページに出る README.md）を扱う共通部分
#
# 作成時に埋める fill-author-readme.sh と、既存リポジトリを後追いで埋める
# sync-author-readme.sh が source する。名簿の引き方とプレースホルダの置換は
# 両方で同じでなければならない（違うと同じリポジトリを 2 回処理したときに
# 内容が揺れる）ので、実装を 1 つに寄せている。
#
# source する側に要求するもの:
#   - error() / log() / warn() を定義しておくこと（この単位はログの体裁を持たない）
#   - WORK_DIR に書き込めるディレクトリを入れておくこと（応答の一時置き場）
#   - API_ERR に gh の stderr の置き場（書き込めるパス）を入れておくこと
#   - ROSTER_FILE に名簿の置き場を入れておくこと
#   - ROSTER_REPO（と任意で ROSTER_PATH）を設定しておくこと
#
# 呼び出し順序:
#   author_readme_values <リポジトリ名>   ← AR_* をそろえる
#   fetch_readme ... / migrate_legacy_readme ... / fill_placeholders ... / put_readme ...
#   migrate_legacy_readme は fill_placeholders より先に通すこと。旧テンプレートの
#   literal な選択肢をプレースホルダに変えるので、順序が逆だと埋まらない。
#   fill_placeholders は AR_* を読むので、先に author_readme_values を通すこと
#   （通っていなければ番兵が非ゼロで返る）。load_roster は author_readme_values
#   が氏名を引く前に 1 度呼んでおく。
#
# 変数の名前を呼び出し側と共有しているのは、どちらのスクリプトも 1 プロセスで
# 完結する用具であり、引数で引き回すより取り違えが起きにくいためである。

# 直近の fetch_readme が取った README.md の blob SHA。成功時のみ設定される。
# shellcheck disable=SC2034  # source 元が put_readme に渡すために読む
FETCHED_SHA=""

ROSTER_AVAILABLE=false

# 名簿から引いた、または学籍番号から決まる値。author_readme_values が設定する。
AR_NAME=""
AR_STUDENT_ID=""
AR_KIND=""
AR_AFFILIATION=""
AR_YEAR=""

UNDERGRADUATE_AFFILIATION="九州産業大学理工学部情報科学科"
GRADUATE_AFFILIATION="九州産業大学大学院情報科学研究科"

# 必要な外部コマンドがそろっているか確かめる。
#
# 無い場合でも黙って誤った結果を出すことはない（jq や openssl が無ければ
# パイプラインが失敗し、fetch_readme は 2 を返す）。ただし出る文面は
# `openssl: command not found` で、何を入れればよいか分からない。
# 入口で名前を挙げて止める。
require_tools() {
    local missing="" tool
    for tool in gh jq openssl base64 awk; do
        command -v "$tool" >/dev/null 2>&1 || missing="${missing:+$missing, }$tool"
    done

    if [ -n "$missing" ]; then
        error "必要なコマンドがありません: $missing"
        return 1
    fi
}

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

# 名簿を取得する。無くても呼び出し側の処理は続けられる（氏名の補完だけが効かない）。
#
# **この関数は常に 0 を返す。** 名簿が無いことは異常ではなく ROSTER_AVAILABLE に
# 記録される状態なので、set -e の下で bare call してよい。末尾の return 0 は
# その契約を固定するためのもので、消すと最後のコマンドの終了コードが漏れる。
load_roster() {
    local path="${ROSTER_PATH:-$(fiscal_year)/students.csv}"

    # 取得に失敗しても下のリダイレクトが ROSTER_FILE を空にするので、旗を先に
    # 倒しておく。倒さずに 2 回目の呼び出しが失敗すると、「旗は true だが中身は
    # 空」になり、名簿が読めないことが「名簿に行が無い」に化ける
    ROSTER_AVAILABLE=false

    if gh api "repos/${ROSTER_REPO}/contents/${path}" \
        -H "Accept: application/vnd.github.raw" > "$ROSTER_FILE" 2>/dev/null; then
        ROSTER_AVAILABLE=true
        log "名簿: ${ROSTER_REPO}/${path}（$(wc -l < "$ROSTER_FILE" | tr -d ' ') 行）"
    else
        # 事実だけを言う。この先どうなるかは呼び出し元で違う（作成時は失敗、
        # 後追いは補完だけを飛ばして続行）ので、呼び出し元が言う
        warn "名簿を取得できません: ${ROSTER_REPO}/${path}"
    fi

    return 0
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

# 学籍番号から所属を決める。学科コードは rs / jk が学部、gjk が大学院。
# jk は 2016 年入学までの学部生で、いま在籍していないが、過去のリポジトリを
# 後追いで埋める場合に出てくる。
affiliation_for() {
    case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
        *gjk*) echo "$GRADUATE_AFFILIATION" ;;
        *)     echo "$UNDERGRADUATE_AFFILIATION" ;;
    esac
}

# リポジトリ名と学籍番号から種別を決める。
#
# 種別のプレースホルダ（（種別））を持つのは sotsuron-template と
# ise-report-template だけで、残り 4 つのテンプレートは種別が固定文字列である。
# 決められない場合は空を返し、呼び出し側は（種別）を置換しない。置換しなければ
# プレースホルダがそのまま残るので、埋め損ねたことが README を見れば分かる。
#
# 卒論と修論の区別は**リポジトリ名の接尾辞ではなく学籍番号で**付ける。接尾辞は
# どのテンプレートから作られたかの判定にだけ使う。接尾辞で区別すると、所属が
# 学籍番号から決まるのに対して種別が別の情報源から決まることになり、2 つが
# 食い違う余地が残る（poster と latex のリポジトリ名は
# ${STUDENT_ID}-${POSTER_NAME} / ${STUDENT_ID}-${DOCUMENT_NAME} で、名前の
# 部分は自由入力なので `-master` も付けられる）。
# リポジトリ名を決めている determine_thesis_type も学籍番号を見ているので、
# 学籍番号に寄せれば情報源が 1 つになる。
kind_for() {
    local repo_name="$1" student_id="$2"

    case "$repo_name" in
        *-sotsuron|*-master|*-thesis)
            case "$(printf '%s' "$student_id" | tr '[:upper:]' '[:lower:]')" in
                *gjk*) echo "修士論文" ;;
                *)     echo "卒業論文" ;;
            esac
            ;;
        *-ise-report1) echo "情報科学演習 I レポート" ;;
        *-ise-report2) echo "情報科学演習 II レポート" ;;
        *)             echo "" ;;
    esac
}

# リポジトリ名の先頭が学籍番号ならそれを書き出す。そうでなければ何も書かない。
#
# 学籍番号は `k` + 入学年 2 桁 + 学科コード + 連番で、**学科コードによらず
# 必ず `k` で始まる**（k23rs001 / k21gjk01 / k16jk001）。`jk` 世代の
# リポジトリもこのパターンで取れる。
#
# 個人モード（INDIVIDUAL_MODE=true）で作られたリポジトリは学籍番号を名前に
# 持たず、名簿にも載らない。呼び出し側はここが空かどうかで、埋める対象かを
# API を叩く前に判定できる。
student_id_from_repo_name() {
    case "$1" in
        k[0-9][0-9]*-*) printf '%s' "${1%%-*}" ;;
    esac
}

# リポジトリ名から、そのリポジトリに書くべき著者情報を決めて AR_* に入れる。
#
# 学籍番号はリポジトリ名の先頭部分をそのまま使う（例: k23rs017）。README の
# プレースホルダ側も `k` 付きの小文字なので形式が揃う。lookup_author が `k` を
# 落として大文字化するのは名簿の列に合わせるためだけで、README に書く表記とは
# 別物である。
#
# 氏名が引けない理由は 2 つあり、直す場所が違うので返り値も分ける。名簿が
# 読めないのはトークンの権限か ROSTER_REPO の指定、行が無いのは名簿そのもの
# である。呼び出し側に ROSTER_AVAILABLE を見させると、この区別が呼び出し側の
# 数だけ重複する。
#
# 0: 埋めるべき値がそろった
# 1: 学籍番号を取り出せない（個人モードで作られたリポジトリなど）
# 2: 名簿そのものを取得できていない
# 3: 名簿にこの学籍番号の行が無い
#
# 2 と 3 を受けたあとどうするかは呼び出し元で違う。作成時（fill-author-readme.sh）
# は README がテンプレートのままなので、埋められないことは失敗である。後追い
# （sync-author-readme.sh）は draft から main へ写す仕事が残っているので、補完
# だけを飛ばして続ける。この違いは意図したものなので、同じ返り値で別の扱いを
# している。
author_readme_values() {
    local repo_name="$1"

    AR_NAME=""; AR_STUDENT_ID=""; AR_KIND=""; AR_AFFILIATION=""; AR_YEAR=""

    AR_STUDENT_ID=$(student_id_from_repo_name "$repo_name")
    [ -n "$AR_STUDENT_ID" ] || return 1

    [ "$ROSTER_AVAILABLE" = true ] || return 2

    AR_NAME=$(lookup_author "$AR_STUDENT_ID")
    [ -n "$AR_NAME" ] || return 3

    AR_KIND=$(kind_for "$repo_name" "$AR_STUDENT_ID")
    AR_AFFILIATION=$(affiliation_for "$AR_STUDENT_ID")
    AR_YEAR=$(fiscal_year)
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
#
# 判定は -i が出す HTTP のステータス行で行う。gh の人間向けメッセージ
# （`gh: Not Found (HTTP 404)`）を照合すると、文面が変わった時点で壊れる。
# ステータス行は HTTP の形式なので変わらない。
#
# ただし -i の出力そのものは gh が組み立てたもので、通信そのままの形ではない。
# gh 2.103.2 で実測した形は次のとおりで、下の照合と分割はこれに合わせている。
#   - 1 行目は `HTTP/2.0 404 Not Found`（CR は付かない）
#   - ヘッダと本文の区切りは `\r` だけの行が 1 つ
#   - 404 でもステータス行は出て、終了コードは非ゼロ
# 照合は `HTTP/` と空白区切りのコードだけを見るので、`HTTP/1.1` でも
# `HTTP/2` でも通る。区切りの判定も CR の有無を問わない。
#
# この 404 は「ブランチに README.md が無い」とも「ブランチやリポジトリが無い」
# とも読める。区別は呼び出し側の役目で、どちらも先にリポジトリの存在を確かめて
# から呼んでいる（fill-author-readme.sh は repos/<repo>、sync-author-readme.sh は
# ブランチ一覧の取得）。
fetch_readme() {
    local repo="$1" ref="$2" out="$3"
    local resp="$WORK_DIR/readme-response.txt"
    local body="$WORK_DIR/readme-body.json"
    local status_line

    FETCHED_SHA=""
    # 失敗して返るときに前回の内容が残らないようにする。呼び出し側は 0 のときだけ
    # 読む約束だが、空にしておけば約束が破られても古い README を push しない
    : > "$out"

    # 終了コードは見ない。ステータス行で分けるので、gh が非ゼロで終わったことと
    # 「README.md が無い」ことを取り違える余地が無い
    gh api -i "repos/${repo}/contents/README.md?ref=${ref}" > "$resp" 2>"$API_ERR" || true

    status_line=$(head -1 "$resp")
    case "$status_line" in
        "HTTP/"*" 404"*) return 1 ;;
        "HTTP/"*" 200"*) ;;
        *)
            # ステータス行が無いのは、要求を出す前に落ちた場合（認証・名前解決）。
            # そのときだけ gh の文面を出す
            error "  README.md を取得できない (${repo}@${ref}): ${status_line:-$(tr '\n' ' ' < "$API_ERR")}"
            return 2
            ;;
    esac

    # ヘッダと本文は空行 1 つで区切られる（HTTP の形式どおり CR が付く）。
    # 最初の空行だけを境界として扱う
    awk 'BEGIN { body = 0 }
         /^\r?$/ && !body { body = 1; next }
         body { print }' "$resp" > "$body"

    if ! FETCHED_SHA=$(jq -er '.sha' < "$body" 2>"$API_ERR"); then
        error "  README.md の応答を解釈できない (${repo}@${ref}): $(tr '\n' ' ' < "$API_ERR")"
        return 2
    fi

    # content は base64 で、改行を挟んで返る。復号に openssl を使うのは
    # base64(1) の復号オプションが環境で揺れるため（GNU は -d、BSD は -D）。
    #
    # -A は外せない。openssl base64 -d は -A が無いと入力が 64 文字で折り返されて
    # いる前提で読むので、tr -d '\n' で 1 行にしたものを渡すと **何も出さずに
    # 成功する**（空の README.md を push することになる）。tr で 1 行に
    # しているからこそ -A が要るという関係で、どちらも冗長ではない。
    jq -r '.content' < "$body" | tr -d '\n' | openssl base64 -d -A > "$out"
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
    # どのブランチで起きたかを添えないと、まとめて回したログから特定できない
    if ! gh api "${args[@]}" --jq '.commit.sha' >/dev/null 2>"$API_ERR"; then
        error "  README.md を push できない (${repo}@${branch}): $(tr '\n' ' ' < "$API_ERR")"
        return 1
    fi
}

# AR_* の値でプレースホルダを埋める。
#
# 値が空のプレースホルダは置換しない。種別は 2 つのテンプレートにしか無く、
# 決められないこともあるので、空で上書きして欄を消すより、プレースホルダを
# 残して埋め損ねを見えるようにする。
#
# gsub も split も使わない。どちらも正規表現を経由するため、置換の両側で
# 文字列が解釈される。
#   - gsub の置換文字列では & が「一致した文字列」を意味し、-v の代入でも
#     エスケープが一段消えるので、& を含む氏名が二重に壊れる
#     （"A & B" が "A （氏名） B" になる）。実際に踏んで直した
#   - split の第 3 引数は正規表現として解釈される。現在のプレースホルダは
#     全角括弧なので実害は無いが、ASCII のメタ文字を含む形に変えた途端に壊れる
# index と substr で回せば、from 側も to 側も解釈が入らない。
fill_placeholders() {
    local in="$1" out="$2"

    # author_readme_values が 0 を返した後に呼ぶ契約を確かめる。
    #
    # 学籍番号だけでは足りない。author_readme_values は氏名を引く前に
    # AR_STUDENT_ID を設定するので、名簿に行が無い場合（返り値 3）でも
    # 学籍番号は入っている。両方を見て「値がそろっている」ことを確かめる。
    #
    # なお AR_NAME が空のまま通っても（氏名）が空文字で消えることはない。
    # replace() は to が空なら行をそのまま返すので、プレースホルダが残る。
    # それでも止めるのは、プレースホルダが残った README を push して
    # 「埋めた」と報告するより、埋められないと言うほうが正しいからである。
    # 種別は除く。（種別）を持つのは 2 つのテンプレートだけで、決まらない
    # ことが正常にあり得る（そのときはプレースホルダを残す）。残り 4 つは
    # author_readme_values が 0 を返したなら必ず入っている
    if [ -z "$AR_STUDENT_ID" ] || [ -z "$AR_NAME" ] \
        || [ -z "$AR_AFFILIATION" ] || [ -z "$AR_YEAR" ]; then
        error "  author_readme_values が 0 を返した後に呼ぶこと（著者情報が未設定）"
        return 1
    fi

    awk -v name="$AR_NAME" -v id="$AR_STUDENT_ID" -v kind="$AR_KIND" \
        -v affiliation="$AR_AFFILIATION" -v year="$AR_YEAR" '
        # to が空なら s を変更せずに返す（プレースホルダを残す）。
        # 置換の走査に入る前に返るので、from が何回現れても元の行がそのまま出る
        function replace(s, from, to,    out, pos, flen) {
            if (to == "") return s
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
            line = replace(line, "（種別）", kind)
            line = replace(line, "（所属）", affiliation)
            line = replace(line, "（20XX）", year)
            print line
        }
    ' "$in" > "$out"
}

# 旧テンプレート（sotsuron-template#151 より前）の形を、今の形に寄せる。
#
# テンプレートの README から「自動入力できない項目」を外したのは #151 ほかで、
# それより前に作られたリポジトリの README は旧い形のまま残っている。旧い形は
# 後追いで埋めても埋まりきらない。
#   - 種別と所属が「A / B」という literal な選択肢で、学生が該当しない方を消す
#     前提だった。プレースホルダではないので置換の対象にならず、修士の学生の
#     main に「卒業論文 / 修士論文」が並んだまま残る
#   - 指導教員と論文のタイトルは自動入力できないので、今の形には無い
#   - 冒頭の注記が「下の項目を自分の情報に書き換え」と指示している。寄せた後は
#     書き換える項目が無いので、今の注記に差し替える。ただし差し替えるのは項目が
#     寄るときだけである。学生が自分で全部書いたリポジトリでは項目が寄らないので、
#     そこでは注記にも触らない（今の注記は「作成時に自動で記入される」と書くが、
#     そのリポジトリでは起きていないことであり、注記だけの commit も残らない）
#
# 変換はどれも**旧テンプレートの文字列と完全に一致したときだけ**行う。学生が
# 一度でも書き換えていれば一致しないので、学生が書いたものには触らない。
# 「draft を権威とし、学生が書いたところは触らない」という設計のままである。
#
# 扱うのは卒業論文・修士論文のテンプレート（sotsuron-template）だけである。残り
# 5 つのテンプレートも旧い形の README を持つが、後追いで埋める対象から外して
# あるので（#191 での判断）ここでは扱わない。必要になったら同じ形で足せる。
#
# 旧い形でなければ入力をそのまま書き出す。呼び出し側は in と out を比べて、
# 寄せが起きたかどうかを判定する。
migrate_legacy_readme() {
    local in="$1" out="$2"

    awk '
        # fill_placeholders と同じ実装。正規表現を経由しないのが要点で、理由は
        # あちらのコメントに書いてある。両方を同じ実装にしておくほうが、
        # 置換の癖が片方だけ違うより読み手が楽である
        function replace(s, from, to,    out, pos, flen) {
            if (to == "") return s
            out = ""
            flen = length(from)
            while ((pos = index(s, from)) > 0) {
                out = out substr(s, 1, pos - 1) to
                s = substr(s, pos + flen)
            }
            return out s
        }
        # 題目の節がこの並びで未記入のまま残っているか
        function title_section_unwritten(i) {
            return (line[i] == title_head && line[i + 1] == "" \
                && line[i + 2] == title_body && line[i + 3] == "")
        }
        BEGIN {
            note_old_1 = "> **このファイルは自分のリポジトリのトップページに表示されます。**"
            note_old_2 = "> 下の項目を自分の情報に書き換え、該当しない選択肢は削除してください。"
            note_old_3 = "> `0th-draft` ブランチでの最初の作業です。"
            note_new_1 = "> **このファイルはリポジトリのトップページに表示されます。**"
            note_new_2 = "> 下の情報はリポジトリ作成時に自動で記入されるので、書き換える必要はありません。"
            supervisor = "- **指導教員**: （指導教員名）"
            title_head = "## 論文のタイトル"
            title_body = "（論文のタイトルを書いてください。まだ決まっていなければ仮のもので構いません。決まった時点で書き換えます。）"
            kind_alt   = "卒業論文 / 修士論文"
            affil_alt  = "九州産業大学理工学部情報科学科 / 九州産業大学大学院情報科学研究科"
        }
        # 節の削除と注記の差し替えは前後の行を見る必要があるので、いったん
        # ぜんぶ読んでから走査する。README は数十行なので保持して困らない
        { line[NR] = $0 }
        END {
            # 項目が寄るかどうかを先に見る。注記の差し替えはそれに従う
            for (i = 1; i <= NR; i++) {
                if (index(line[i], kind_alt) > 0 || index(line[i], affil_alt) > 0 \
                    || line[i] == supervisor || title_section_unwritten(i)) {
                    fields = 1
                    break
                }
            }
            for (i = 1; i <= NR; i++) {
                if (fields && line[i] == note_old_1 && line[i + 1] == note_old_2 \
                    && line[i + 2] == note_old_3) {
                    print note_new_1
                    print note_new_2
                    # 3 行とも読み終えた。for の i++ と合わせて次の行へ進む
                    # （ここを「読み終えた行数」に合わせると 1 行飛ばす）
                    i += 2
                    continue
                }
                # 指導教員の行は、未記入のときだけ落とす
                if (line[i] == supervisor) continue
                # 題目の節は、見出し・空行・未記入の本文・空行がそろったときだけ落とす
                if (title_section_unwritten(i)) {
                    # 4 行とも読み終えた。足し方は上の注記と同じ
                    i += 3
                    continue
                }
                s = replace(line[i], kind_alt, "（種別）")
                print replace(s, affil_alt, "（所属）")
            }
        }
    ' "$in" > "$out"
}
