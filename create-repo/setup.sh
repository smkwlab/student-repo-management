#!/bin/bash
# 統合リポジトリ作成スクリプト (Universal Setup Script)
# 使用例: bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis

set -e

# デバッグモード（環境変数 DEBUG=1 で有効化）
if [ "${DEBUG:-0}" = "1" ]; then
    set -x
    echo "🔍 デバッグモード有効"
fi

# ================================
# 組織・ツールリポジトリ設定（他 org 展開対応）
# ================================
# デプロイ先の既定組織。smkwlab 以外の org で運用する場合は、この既定値を
# fork 側で書き換えるか、実行時に DEFAULT_ORG 環境変数で指定する。組織メンバー
# 判定・組織ユーザーの既定作成先・案内文の URL がこの値に追従する。
DEFAULT_ORG="${DEFAULT_ORG:-smkwlab}"
# 組織 / アカウント名は gh api のパス（orgs/<org>/members/...）に埋め込むため、
# GitHub のログイン/組織名の文字種（英数字とハイフン）で検証する。
case "$DEFAULT_ORG" in
    ""|*[!A-Za-z0-9-]*)
        echo "❌ DEFAULT_ORG に使用できない文字が含まれています: $DEFAULT_ORG" >&2
        exit 1 ;;
esac
# TARGET_ORG が env で明示指定されている場合も、同じく gh api のパスに使う前に検証する
# （未指定＝空は後段で既定へ解決するのでここでは許容）。
if [ -n "${TARGET_ORG:-}" ]; then
    case "$TARGET_ORG" in
        *[!A-Za-z0-9-]*)
            echo "❌ TARGET_ORG に使用できない文字が含まれています: $TARGET_ORG" >&2
            exit 1 ;;
    esac
fi

# このスクリプトが内部で clone する student-repo-management の取得元。
# 配布元 org（＝ DEFAULT_ORG）が既定。学生リポジトリの作成先である TARGET_ORG は
# 個人アカウントにもなり得るためここでは使わない。owner / repo 名は git clone の
# URL に埋め込むため、安全な文字のみ許可する（文字種のみ検証し、連続ハイフンや
# 長さ制限など GitHub 側の詳細な命名規則は clone 時のエラーに委ねる）。
TOOLS_REPO_OWNER="${TOOLS_REPO_OWNER:-$DEFAULT_ORG}"
# TOOLS_REPO は env 変数 TOOLS_REPO_NAME を解決した内部変数（既定を適用済み）。
# TOOLS_REPO_NAME 自体は「ユーザーが指定した時のみコンテナへ転送する」判定に
# 後段（$TOOLS_REPO_NAME の有無チェック）で使うため、別名のまま残す。
TOOLS_REPO="${TOOLS_REPO_NAME:-student-repo-management}"
case "$TOOLS_REPO_OWNER" in
    ""|*[!A-Za-z0-9-]*)
        echo "❌ TOOLS_REPO_OWNER に使用できない文字が含まれています: $TOOLS_REPO_OWNER" >&2
        exit 1 ;;
esac
case "$TOOLS_REPO" in
    ""|*[!A-Za-z0-9._-]*)
        echo "❌ TOOLS_REPO_NAME に使用できない文字が含まれています: $TOOLS_REPO" >&2
        exit 1 ;;
esac
TOOLS_CLONE_URL="${TOOLS_CLONE_URL:-https://github.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}.git}"
# TOOLS_CLONE_URL は完全上書きを許すため、git clone へ渡す前にスキームを検証する。
# https:// / git@ 以外（ext:: や file:// 等の危険なスキーム、先頭 "-" による git の
# 引数注入）を拒否する。既定値も https:// で始まるため通常運用に影響はない。
case "$TOOLS_CLONE_URL" in
    https://*|git@*) ;;
    *)
        echo "❌ TOOLS_CLONE_URL は https:// または git@ で始まる必要があります: $TOOLS_CLONE_URL" >&2
        exit 1 ;;
esac

# ================================
# バージョン固定（再現性・安全性）
# ================================
# このスクリプトが内部で clone・利用する student-repo-management の参照先（ref）。
#
# EMBEDDED_REF はリリース時にタグ（例: v1.0.0）へ書き換えられる。main ブランチ上では
# "main" のまま。これにより、タグ付き URL から取得した setup.sh は、内部で clone する
# 内容も同じタグに固定され、完全な再現性が得られる（リリース手順は docs/RELEASE.md）。
#
# 明示的に上書きしたい場合は環境変数で指定する：
#   UNIVERSAL_REF=v1.0.0   タグ / コミットSHA / ブランチを固定（推奨）。解決できない
#                          場合はエラー終了する（再現性・監査性のため main へ暗黙
#                          フォールバックしない）。
#   UNIVERSAL_BRANCH=...   後方互換のためのエイリアス（UNIVERSAL_REF を優先）。従来
#                          どおり、解決できない場合は警告して main へフォールバックする。
# 優先順位: UNIVERSAL_REF > UNIVERSAL_BRANCH > EMBEDDED_REF
EMBEDDED_REF="main"
if [ -n "$UNIVERSAL_REF" ]; then
    SETUP_REF="$UNIVERSAL_REF"
    SETUP_REF_LENIENT=0
elif [ -n "$UNIVERSAL_BRANCH" ]; then
    SETUP_REF="$UNIVERSAL_BRANCH"
    SETUP_REF_LENIENT=1   # 後方互換: 解決失敗時は main へフォールバック
else
    SETUP_REF="$EMBEDDED_REF"
    SETUP_REF_LENIENT=0
fi

# ================================
# 文書タイプ設定
# ================================

# 引数または環境変数から文書タイプを取得（引数を優先）
DOC_TYPE="${1:-$DOC_TYPE}"

# 学籍番号は環境変数から取得
STUDENT_ID="${STUDENT_ID}"

# 文書タイプの検証
if [ -z "$DOC_TYPE" ]; then
    echo "❌ 文書タイプが指定されていません"
    echo ""
    echo "使用例："
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash thesis"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash wr"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash latex"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash ise"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash poster"
    echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash sotsuron-report"
    echo ""
    echo "学籍番号を指定する場合（環境変数）："
    echo "  STUDENT_ID=k21rs001 /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\" bash thesis"
    echo ""
    echo "環境変数での指定も可能："
    echo "  DOC_TYPE=thesis /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/main/create-repo/setup.sh)\""
    echo ""
    exit 1
fi

# 文書タイプの設定
DETECTED_DOC_TYPE="$DOC_TYPE"

# 設定マッピング
# この case は DOC_TYPE の whitelist 検証を兼ねる（後段で -e DOC_TYPE として
# 無引用のまま docker run へ渡すため、ここを通過した 6 値以外は流れない）。
# Dockerfile / 実行スクリプトはタイプ共通（create-repo/Dockerfile + main.sh、
# タイプは DOC_TYPE 環境変数で選択。Issue #516）。旧構成の ref を指定した
# 場合のフォールバックは clone 後に判定する。
configure_document_type() {
    local doc_type="$1"

    case "$doc_type" in
        thesis)
            DOC_DESCRIPTION="📚 論文リポジトリ"
            DOCKER_IMAGE_NAME="thesis-setup-alpine"
            ;;
        wr)
            DOC_DESCRIPTION="📝 週間報告リポジトリ"
            DOCKER_IMAGE_NAME="wr-setup-alpine"
            ;;
        latex)
            DOC_DESCRIPTION="📝 汎用LaTeXリポジトリ"
            DOCKER_IMAGE_NAME="latex-setup-alpine"
            ;;
        ise)
            DOC_DESCRIPTION="💻 情報科学演習リポジトリ"
            DOCKER_IMAGE_NAME="ise-setup-alpine"
            ;;
        poster)
            DOC_DESCRIPTION="📊 学会ポスターリポジトリ"
            DOCKER_IMAGE_NAME="poster-setup-alpine"
            ;;
        sotsuron-report)
            DOC_DESCRIPTION="📝 卒業論文調査報告リポジトリ"
            DOCKER_IMAGE_NAME="sotsuron-report-setup-alpine"
            ;;
        *)
            echo "❌ サポートされていない文書タイプ: $doc_type"
            echo "対応タイプ: thesis, wr, latex, ise, poster, sotsuron-report"
            exit 1
            ;;
    esac

    DOCKERFILE_NAME="Dockerfile"
}

# 設定の適用
configure_document_type "$DETECTED_DOC_TYPE"

# ================================
# 共通変数・関数定義
# ================================

# 一時ディレクトリ・ファイル変数（グローバルスコープ）
TEMP_DIR=""
TOKEN_FILE=""

# クリーンアップ関数
cleanup() {
    if [ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ]; then
        echo "🧹 クリーンアップ中..."
        rm -rf "$TEMP_DIR"
    fi
    # セキュアなトークンファイルの削除
    if [ -n "$TOKEN_FILE" ] && [ -f "$TOKEN_FILE" ]; then
        rm -f "$TOKEN_FILE"
    fi
    # Dockerイメージも削除
    if docker images -q "$DOCKER_IMAGE_NAME" >/dev/null 2>&1; then
        echo "🗑️  Dockerイメージをクリーンアップ中..."
        docker rmi "$DOCKER_IMAGE_NAME" >/dev/null 2>&1 || true
    fi
}

# 終了時・中断時のクリーンアップ
trap cleanup EXIT
trap cleanup INT
trap cleanup TERM

# ================================
# メイン処理開始
# ================================

echo "==============================================="
echo "$DOC_DESCRIPTION 作成ツール (Universal)"
echo "🐳 Dockerベース"
echo "==============================================="
echo "📋 検出された文書タイプ: $DETECTED_DOC_TYPE"

# 指定された文書タイプの表示
echo "🎯 文書タイプ: $DOC_TYPE"

echo ""

# Docker の確認
if ! command -v docker >/dev/null 2>&1; then
    echo "❌ Dockerがインストールされていません"
    echo "   https://docs.docker.com/get-docker/ からインストールしてください"
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "❌ Dockerデーモンが起動していません"
    echo "   Dockerを起動してから再実行してください"
    exit 1
fi

# GitHub CLI の確認（ホスト側）
if ! command -v gh >/dev/null 2>&1; then
    echo "❌ GitHub CLI (gh) がインストールされていません"
    echo "   https://cli.github.com/ からインストールしてください"
    exit 1
fi

# GitHub 認証状況を確認
echo "🔐 GitHub 認証状況を確認中..."

if ! gh auth status >/dev/null 2>&1; then
    echo "❌ GitHub CLI にログインしていません"
    echo ""
    echo "以下のコマンドでログインしてください："
    echo "  gh auth login"
    echo ""
    echo "💡 認証方法："
    echo "  - ブラウザ認証（推奨）: Enter → ワンタイムコードを入力"
    echo "  - Personal Access Token: トークンを直接入力"
    echo ""
    echo "🔧 トラブルシューティング："
    echo "  - エラー時: gh auth refresh"
    echo "  - 複数アカウント: gh auth switch --user USERNAME"
    echo ""
    exit 1
fi

# 現在のユーザーアカウントを取得
if ! CURRENT_USER=$(gh api user --jq .login 2>/dev/null); then
    echo "❌ GitHub APIアクセスに失敗しました"
    echo "認証トークンを更新してください："
    echo "  gh auth refresh"
    exit 1
fi

echo "✅ GitHub認証済み (ユーザー: $CURRENT_USER)"

# ユーザータイプ判定関数
# 第2引数で渡された組織のメンバーシップを確認する（既定は DEFAULT_ORG、
# TARGET_ORG が明示指定されていれば呼び出し側でそちらを渡す）。
detect_user_type() {
    local current_user="$1"
    local org="$2"

    if [ "${DEBUG:-0}" = "1" ]; then
        echo "🔍 ユーザータイプを判定中: $current_user (組織: $org)"
    fi

    # INDIVIDUAL_MODE環境変数による明示的指定
    if [[ "${INDIVIDUAL_MODE:-false}" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        echo "individual_user"
        return 0
    fi

    # 対象組織のメンバーシップを確認する。org が個人アカウント名の場合は
    # /orgs/<name>/members が 404 となり individual_user と判定される
    # （個人アカウントを作成先に指定したケースの意図どおりの挙動）。
    if gh api "orgs/$org/members/$current_user" >/dev/null 2>&1; then
        echo "organization_member"
    else
        echo "individual_user"
    fi
}

# ユーザータイプの判定
# メンバーシップ確認の対象は、TARGET_ORG が明示指定されていればその組織、
# 無ければ既定組織 (DEFAULT_ORG)。TARGET_ORG が明示指定されている場合は、
# ここ（型判定）と後段の作成先妥当性チェックの 2 か所でメンバーシップ API を
# 呼ぶ。型判定とアクセス検証は別関心なので、冗長 1 回は許容し分離を優先する。
MEMBERSHIP_ORG="${TARGET_ORG:-$DEFAULT_ORG}"
USER_TYPE=$(detect_user_type "$CURRENT_USER" "$MEMBERSHIP_ORG")

if [ "${DEBUG:-0}" = "1" ]; then
    echo "🔍 判定結果: $USER_TYPE"
fi

# TARGET_ORG（対象組織）の設定
if [ "$USER_TYPE" = "individual_user" ]; then
    # 個人アカウントに作成する。INDIVIDUAL_MODE が明示指定された場合は
    # 「個人アカウントに作成する」契約を優先し、TARGET_ORG の明示値があっても
    # 本人アカウントへ上書きする（矛盾した指定を安全側に倒す）。それ以外は
    # 明示された TARGET_ORG を尊重し、未指定なら本人アカウントを既定にする。
    if [[ "${INDIVIDUAL_MODE:-false}" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        # 矛盾指定（INDIVIDUAL_MODE=true かつ TARGET_ORG=組織）は、無視される側を
        # 明示してからユーザーへ知らせる。
        if [ -n "${TARGET_ORG:-}" ] && [ "$TARGET_ORG" != "$CURRENT_USER" ]; then
            echo "⚠️ INDIVIDUAL_MODE が有効なため TARGET_ORG=$TARGET_ORG を無視し、個人アカウント ($CURRENT_USER) を使用します"
        fi
        TARGET_ORG="$CURRENT_USER"
    else
        TARGET_ORG="${TARGET_ORG:-$CURRENT_USER}"
    fi
    echo "👤 個人ユーザーモードで実行中"
    echo "   作成先: $TARGET_ORG (個人アカウント)"
else
    # 組織ユーザーの場合、既定組織 (DEFAULT_ORG) を作成先とする
    TARGET_ORG="${TARGET_ORG:-$DEFAULT_ORG}"
    echo "🏢 組織ユーザーモードで実行中"
    echo "   作成先: $TARGET_ORG (組織)"
fi

# 作成先の妥当性チェック：
# TARGET_ORG が本人の個人アカウント (== CURRENT_USER) でも、CURRENT_USER が
# メンバーである組織でもない場合、そこにはリポジトリを作成できないため停止する。
# （旧実装は「TARGET_ORG == CURRENT_USER」の等値のみを許可していたため、実在の
# 組織を指定すると必ず不整合と判定されていた。実メンバーシップ判定に置き換える。）
# なお INDIVIDUAL_MODE 有効時は上のブロックで TARGET_ORG=$CURRENT_USER に確定する
# ため、この妥当性チェックは等値で必ずスキップされる。
if [ "$TARGET_ORG" != "$CURRENT_USER" ]; then
    if ! gh api "orgs/$TARGET_ORG/members/$CURRENT_USER" >/dev/null 2>&1; then
        echo "⚠️ 作成先組織にアクセスできません"
        echo "  指定組織: $TARGET_ORG"
        echo "  現在のアカウント: $CURRENT_USER"
        echo ""
        echo "$CURRENT_USER は $TARGET_ORG のメンバーではないか、組織が存在しません。"
        echo ""
        echo "対処法："
        echo "  - メンバーのアカウントに切り替える: gh auth switch --user <member>"
        echo "  - 現在のアカウントで個人リポジトリとして作成: TARGET_ORG=$CURRENT_USER $0"
        exit 1
    fi
fi

# 複数アカウントが存在する場合の情報表示
AUTH_STATUS=$(gh auth status 2>&1)
ACCOUNT_COUNT=$(echo "$AUTH_STATUS" | grep -c "Logged in to" || echo "1")

if [ "$ACCOUNT_COUNT" -gt 1 ]; then
    echo "ℹ️ 複数のGitHubアカウントが検出されました (${ACCOUNT_COUNT}個)"
    if [ "${DEBUG:-0}" = "1" ]; then
        echo "認証状況:"
        echo "$AUTH_STATUS" | grep -E "(Logged in to|Active account)"
    fi
    echo "現在のアクティブアカウント ($CURRENT_USER) を使用します"
fi

# GitHub トークンをセキュアな一時ファイルに保存
echo "🎫 GitHub 認証トークンを準備中..."
TOKEN_FILE=$(mktemp)
chmod 600 "$TOKEN_FILE"  # 所有者のみ読み書き可能

if gh auth token > "$TOKEN_FILE" 2>/dev/null; then
    echo "✅ GitHub 認証トークンを安全に準備しました"
else
    echo "❌ トークン取得に失敗しました"
    echo "以下のコマンドでGitHub CLIを再認証してください："
    echo "  gh auth refresh"
    exit 1
fi

# workflow スコープの事前確認
#
# 生成リポジトリには setup 時に .github/workflows/autoassignees.yml を追加する
# （テンプレートには置かず動的に足す。common-lib.sh の
# setup_auto_assign_for_organization_members）。GitHub は workflow スコープを
# 持たない OAuth トークンによる workflows/ 配下の作成・更新を拒否する。push は
# アトミックなので、ワークフロー 1 個のために main の内容がまるごと入らない:
#
#   ! [remote rejected] main -> main (refusing to allow an OAuth App to create
#     or update workflow .github/workflows/autoassignees.yml without workflow scope)
#
# ここで止めなければ、リポジトリだけが Initial commit の状態で残り、0th-draft・
# ブランチ保護・レジストリ登録のいずれも行われない。しかも学生に見えるのは上の
# 英文だけで、何をすればよいか分からない。push まで進ませずここで落とす。
#
# gh auth login の既定スコープは repo・read:org・gist で workflow を含まない。
# 一方コンテナ側の対話認証（common-lib.sh の perform_interactive_auth）は
# workflow を要求する。ホストで gh auth login 済みの利用者はそのトークンが
# そのまま転送されるため、どちらの経路を通ったかで成否が分かれていた。
#
# スコープは API の X-OAuth-Scopes ヘッダで確かめる。gh auth status の出力を
# 解析するより安定しており、gh 自身も同じヘッダを読んでいる。fine-grained PAT や
# GitHub App のトークンではこのヘッダが空になる。その場合はスコープという概念が
# 無く判定できないので、警告だけで続行する。判定できないことを理由に止めると、
# 必要な権限を持つ利用者を塞ぐことになる。
#
# ここに来た時点で TOKEN_FILE は中身のあるファイルである。直前の
# gh auth token が失敗すれば exit しており、さらにその前段で gh api user の
# 成功も確かめている。空ファイルで「判定不能」に落ちる経路は無い。
echo "🔎 トークンのスコープを確認中..."

# ヘッダ名だけを取り除いて残り全体を値として扱う。$2 を取ると、値に ": " が
# 現れた場合に切れる。スコープ名に ": " は現れないが、ここで切れると
# 「workflow が無い」と誤判定して正当な利用者を止めるため、形に頼らない。
TOKEN_SCOPES=$(curl -fsSI -H "Authorization: Bearer $(cat "$TOKEN_FILE")" \
    https://api.github.com/ 2>/dev/null \
    | tr -d '\r' \
    | awk 'tolower($0) ~ /^x-oauth-scopes:/ { sub(/^[^:]*:[[:space:]]*/, ""); print }')

if [ -z "$TOKEN_SCOPES" ]; then
    echo "⚠️ スコープを判定できませんでした（fine-grained PAT などの可能性があります）"
    echo "   ワークフローファイルの push が拒否される場合は workflow 相当の権限を確認してください"
elif printf '%s' "$TOKEN_SCOPES" | tr ',' '\n' | tr -d ' ' | grep -qx 'workflow'; then
    echo "✅ workflow スコープを確認しました"
else
    echo "❌ GitHub トークンに workflow スコープがありません"
    echo ""
    echo "現在のスコープ: ${TOKEN_SCOPES}"
    echo ""
    echo "このままではリポジトリ作成の途中で push が拒否され、"
    echo "中身の無いリポジトリだけが残ります。先に権限を追加してください："
    echo ""
    echo "  gh auth refresh -h github.com -s workflow"
    echo ""
    echo "追加後、このコマンドをもう一度実行してください。"
    exit 1
fi

# GitHub から直接ビルド & 実行
echo "🔧 セットアップ開始..."

# 一時ディレクトリでリポジトリをクローン
TEMP_DIR=$(mktemp -d)
ORIGINAL_DIR=$(pwd)

echo "📥 リポジトリを取得中..."

if ! git clone "$TOOLS_CLONE_URL" "$TEMP_DIR" 2>/dev/null; then
    echo "❌ リポジトリのクローンに失敗しました ($TOOLS_CLONE_URL)"
    exit 1
fi

cd "$TEMP_DIR"

# 指定された参照（タグ / コミットSHA / ブランチ）に切り替える。
# clone 直後は既定ブランチ（main）に居るため、main 指定時は切り替え不要。
if [ "$SETUP_REF" != "main" ]; then
    # オプション注入対策: git がオプションと解釈するのは先頭が "-" の値のみ。
    # そのような値（例: UNIVERSAL_REF=-x）は不正な参照として拒否する。
    case "$SETUP_REF" in
        -*)
            echo "❌ 不正な参照指定です: $SETUP_REF"
            exit 1
            ;;
    esac

    # SETUP_REF をコミットに解決する。git rev-parse はリビジョンのみを解決し
    # パスは解決しないため、SETUP_REF が（ref ではなく）パスとして誤って checkout され、
    # HEAD が main のまま「固定成功」と表示される事態を防げる。
    # ローカルに無いブランチ名は origin/ 経由でも解決を試みる。
    if SETUP_COMMIT=$(git rev-parse --verify --quiet "${SETUP_REF}^{commit}"); then
        :
    elif SETUP_COMMIT=$(git rev-parse --verify --quiet "origin/${SETUP_REF}^{commit}"); then
        :
    elif [ "$SETUP_REF_LENIENT" = "1" ]; then
        # 後方互換（UNIVERSAL_BRANCH）: 解決できない場合は従来どおり警告して main を使用する。
        echo "⚠️ 指定された参照 ($SETUP_REF) が見つかりません。mainブランチを使用します。"
        SETUP_COMMIT=""
    else
        # 固定版（UNIVERSAL_REF / リリースタグ）が見つからない場合、main への暗黙
        # フォールバックは再現性・監査性を損なうため、エラーとして終了する。
        echo "❌ 指定された参照 ($SETUP_REF) が見つかりません。"
        echo "   タグ名・コミットSHA・ブランチ名が正しいか確認してください。"
        echo "   利用可能なバージョン: https://github.com/${TOOLS_REPO_OWNER}/${TOOLS_REPO}/releases"
        exit 1
    fi

    # 解決できた場合のみ detached HEAD で切り替える（lenient フォールバック時は main のまま）
    if [ -n "$SETUP_COMMIT" ]; then
        if ! git checkout --detach "$SETUP_COMMIT" 2>/dev/null; then
            echo "❌ 参照 ($SETUP_REF) への切り替えに失敗しました。"
            exit 1
        fi
        echo "📌 バージョン固定: $SETUP_REF"
    fi
fi

cd create-repo

# 後方互換: 統合前の旧構成（v1 系タグ等）を UNIVERSAL_REF / UNIVERSAL_BRANCH で
# 指定した場合は、旧タイプ別 Dockerfile-<type>（ENTRYPOINT main-<type>.sh）で
# 動作させる（Issue #516）。DOC_TYPE 環境変数は旧 main-<type>.sh では単に
# 無視されるため、転送されても無害。
# これは暫定措置であり、統合前の ref（v1 系）を指す利用が無くなったら削除してよい。
# clone 済みツリーの判定なので main.sh の有無で十分（下段で解決先の実在も確認する）。
if [ ! -f main.sh ]; then
    if [ -f "Dockerfile-${DETECTED_DOC_TYPE}" ]; then
        echo "ℹ️ 統合前の構成を検出: Dockerfile-${DETECTED_DOC_TYPE} を使用します"
        DOCKERFILE_NAME="Dockerfile-${DETECTED_DOC_TYPE}"
    else
        echo "❌ create-repo/main.sh も Dockerfile-${DETECTED_DOC_TYPE} も見つかりません"
        echo "   UNIVERSAL_REF / UNIVERSAL_BRANCH で古い・不正な参照を指定していないか確認してください"
        exit 1
    fi
fi

# 解決した Dockerfile が実在することを確認する。main.sh はあるが Dockerfile が
# 無い中間状態（不完全なチェックアウト等）を、docker の不明瞭なエラーではなく
# 明示的なメッセージで停止させる。
if [ ! -f "$DOCKERFILE_NAME" ]; then
    echo "❌ ビルド対象の $DOCKERFILE_NAME が create-repo/ に見つかりません"
    echo "   チェックアウトが不完全な可能性があります。UNIVERSAL_REF / UNIVERSAL_BRANCH を確認してください"
    exit 1
fi

echo "🐳 Dockerイメージをビルド中..."
if [ "${DEBUG:-0}" = "1" ]; then
    # デバッグモードでは詳細出力を表示
    if ! docker build --progress=plain -f "$DOCKERFILE_NAME" -t "$DOCKER_IMAGE_NAME" .; then
        echo "❌ Dockerイメージのビルドに失敗しました"
        exit 1
    fi
else
    # 通常モードでも進行状況を表示
    if ! docker build --progress=auto -f "$DOCKERFILE_NAME" -t "$DOCKER_IMAGE_NAME" .; then
        echo "❌ Dockerイメージのビルドに失敗しました"
        exit 1
    fi
fi

echo "🚀 セットアップ実行中..."

# 元のディレクトリに戻って実行
cd "$ORIGINAL_DIR"

# Docker実行（TTY対応、GitHub認証トークンをセキュアファイル経由で渡す）
# 動作モード情報と環境変数を渡す。DOC_TYPE は統合 main.sh の文書タイプ選択用
# （configure_document_type の case で whitelist 済みのため無引用展開でも安全）
DOCKER_ENV_VARS="-e USER_TYPE=$USER_TYPE -e TARGET_ORG=$TARGET_ORG -e DOC_TYPE=$DETECTED_DOC_TYPE"

# リポジトリ名規約の override をコンテナへ転送（未設定なら渡さない = 規約デフォルト）
# DOCKER_ENV_VARS は既存慣習どおり無引用展開されるため、安全な文字のみ許可する
valid_repo_name() {
    case "$1" in
        *[!A-Za-z0-9._-]*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}
if [ -n "${REGISTRY_REPO_NAME:-}" ]; then
    valid_repo_name "$REGISTRY_REPO_NAME" || { echo "❌ REGISTRY_REPO_NAME に使用できない文字が含まれています: $REGISTRY_REPO_NAME" >&2; exit 1; }
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e REGISTRY_REPO_NAME=$REGISTRY_REPO_NAME"
fi
if [ -n "${TOOLS_REPO_NAME:-}" ]; then
    valid_repo_name "$TOOLS_REPO_NAME" || { echo "❌ TOOLS_REPO_NAME に使用できない文字が含まれています: $TOOLS_REPO_NAME" >&2; exit 1; }
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e TOOLS_REPO_NAME=$TOOLS_REPO_NAME"
fi

# 他 org 展開向けの override をコンテナへ転送（未設定なら渡さない = 既定）。
# いずれも無引用展開に載るため、空白を含まない安全な文字種のみ許可する。
if [ -n "${TEMPLATE_REPO:-}" ]; then
    case "$TEMPLATE_REPO" in
        *[!A-Za-z0-9._/-]*|"") echo "❌ TEMPLATE_REPO に使用できない文字が含まれています: $TEMPLATE_REPO" >&2; exit 1 ;;
    esac
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e TEMPLATE_REPO=$TEMPLATE_REPO"
fi
if [ -n "${AUTO_ASSIGN_REVIEWER:-}" ]; then
    case "$AUTO_ASSIGN_REVIEWER" in
        *[!A-Za-z0-9-]*|"") echo "❌ AUTO_ASSIGN_REVIEWER に使用できない文字が含まれています: $AUTO_ASSIGN_REVIEWER" >&2; exit 1 ;;
    esac
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e AUTO_ASSIGN_REVIEWER=$AUTO_ASSIGN_REVIEWER"
fi
if [ -n "${ALDC_URL:-}" ]; then
    case "$ALDC_URL" in
        https://*) ;;
        *) echo "❌ ALDC_URL は https:// で始まる必要があります: $ALDC_URL" >&2; exit 1 ;;
    esac
    # 無引用展開（docker run $DOCKER_ENV_VARS）に載るため、URL 安全文字のみ許可し、
    # 空白（単語分割）と glob 文字（* ? [）を排除する。他の転送変数と同じ流儀。
    case "$ALDC_URL" in
        *[!A-Za-z0-9._~:/%-]*) echo "❌ ALDC_URL に使用できない文字が含まれています: $ALDC_URL" >&2; exit 1 ;;
    esac
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e ALDC_URL=$ALDC_URL"
fi
if [ -n "${SETUP_GIT_EMAIL_DOMAIN:-}" ]; then
    case "$SETUP_GIT_EMAIL_DOMAIN" in
        *[!A-Za-z0-9.-]*|"") echo "❌ SETUP_GIT_EMAIL_DOMAIN に使用できない文字が含まれています: $SETUP_GIT_EMAIL_DOMAIN" >&2; exit 1 ;;
    esac
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e SETUP_GIT_EMAIL_DOMAIN=$SETUP_GIT_EMAIL_DOMAIN"
fi

# REVIEW_FLOW: latex タイプで draft PR レビューフロー（main + 0th-draft 初期化・
# auto-assign・ブランチ保護）を有効化するオプトイン。truthy のときだけ正規化して
# 転送する（thesis / ise / poster は常時有効、wr は非対応のため latex 以外では無視）。
if [ -n "${REVIEW_FLOW:-}" ]; then
    if [[ "$REVIEW_FLOW" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        if [ "$DETECTED_DOC_TYPE" = "latex" ]; then
            DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e REVIEW_FLOW=true"
        else
            echo "⚠️ REVIEW_FLOW は latex タイプ専用のため無視します（$DETECTED_DOC_TYPE は指定不要: thesis/ise/poster は常時有効、wr は非対応）"
        fi
    else
        echo "⚠️ REVIEW_FLOW の値が truthy ではないため無視します: $REVIEW_FLOW（有効化するには true/1/yes）"
    fi
fi

# DOCUMENT_NAME / POSTER_NAME はコンテナ側 main.sh で ^[a-zA-Z0-9_-]+$ を要求する。
# ここでも無引用展開（docker run $DOCKER_ENV_VARS）に載るため、同じ文字種のみ許可して
# 単語分割・glob を防ぐ（他の転送変数と同じ流儀）。
valid_doc_name() {
    case "$1" in
        *[!A-Za-z0-9_-]*) return 1 ;;
        "") return 1 ;;
        *) return 0 ;;
    esac
}

# 文書タイプ固有の環境変数を渡す
# 注: 旧構成では latex に AUTHOR_NAME、ise に ASSIGNMENT_TYPE も転送していたが、
# どちらもコンテナ側スクリプトから参照されない死に変数だったため削除した（Issue #519）。
case "$DETECTED_DOC_TYPE" in
    latex)
        # ドキュメント名が環境変数で指定されている場合は渡す
        if [ -n "$DOCUMENT_NAME" ]; then
            valid_doc_name "$DOCUMENT_NAME" || { echo "❌ DOCUMENT_NAME に使用できない文字が含まれています: $DOCUMENT_NAME" >&2; exit 1; }
            DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e DOCUMENT_NAME=$DOCUMENT_NAME"
        fi
        ;;
    poster)
        # poster は POSTER_NAME を優先し、無ければ DOCUMENT_NAME を使う（main.sh の
        # read_poster_name と同じ優先順位）。旧 setup.sh は poster でどちらも転送せず、
        # 常に対話入力になっていた（Issue #519）。
        if [ -n "$POSTER_NAME" ]; then
            valid_doc_name "$POSTER_NAME" || { echo "❌ POSTER_NAME に使用できない文字が含まれています: $POSTER_NAME" >&2; exit 1; }
            DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e POSTER_NAME=$POSTER_NAME"
        fi
        if [ -n "$DOCUMENT_NAME" ]; then
            valid_doc_name "$DOCUMENT_NAME" || { echo "❌ DOCUMENT_NAME に使用できない文字が含まれています: $DOCUMENT_NAME" >&2; exit 1; }
            DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e DOCUMENT_NAME=$DOCUMENT_NAME"
        fi
        ;;
    ise)
        # ISE固有の環境変数処理
        if [ -n "$ISE_REPORT_NUM" ]; then
            DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e ISE_REPORT_NUM=$ISE_REPORT_NUM"
        fi
        ;;
esac

# Git Bash環境下でのみGH_TOKENを環境変数として渡す
if [[ -n "$MSYSTEM" ]] || [[ "$OSTYPE" == "msys" ]] || [[ -n "$MINGW_PREFIX" ]] || ([[ -n "$WINDIR" ]] && [[ "$SHELL" == *"bash"* ]]); then
    # Git Bash環境下ではGH_TOKENを取得・設定
    if [ -z "$GH_TOKEN" ]; then
        if GH_TOKEN=$(gh auth token 2>/dev/null); then
            DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e GH_TOKEN=$GH_TOKEN"
        else
            echo "⚠️ GitHub認証トークンの取得に失敗しました。gh auth login を実行してください。"
        fi
    fi
fi

# 対話的入力が必要かどうかを判断。非対話実行のパスは 2 つ:
#
#  1) ASSUME_YES（Issue #527）: 確認プロンプト（コンテナ側 confirm_creation）を
#     自動承認し、全タイプで非対話実行する。組織フローでも使える汎用フラグで、
#     INDIVIDUAL_MODE（個人アカウント作成）とは独立。ただし名前・学籍番号の入力
#     プロンプトは自動承認では消えないため、必要な入力が揃っていることを前提とする
#     （揃っていなければ下でエラー終了する）。
#  2) INDIVIDUAL_MODE（従来・Issue #519）: 個人モードでは confirm_creation が
#     自動承認されるため、「名前が env 指定済み（名前プロンプトが出ない）」なら
#     非対話にできる。latex は DOCUMENT_NAME、poster は POSTER_NAME か DOCUMENT_NAME が
#     あればよい（poster は read_poster_name が POSTER_NAME 未設定時に DOCUMENT_NAME を
#     採用するフォールバックのため。両方指定時は POSTER_NAME 優先）。thesis/wr/ise は
#     従来どおり -it 付きで実行する（挙動不変）。
# 注: set -e 下で `[ ... ] && VAR=...` は左辺 false で終了してしまうため if 構造で書く。

# ASSUME_YES 非対話実行に必要な入力の欠落を ", " 区切りで返す（無ければ空文字）。
# コンテナ側 main.sh が出すプロンプトに対応する:
#  - 組織モード（INDIVIDUAL_MODE でない）は全タイプで read_student_id_if_needed が
#    STUDENT_ID を要求する（空だと read_student_id が対話 or GitHub ユーザー名へ誤フォールバック）。
#  - latex は read_document_name が DOCUMENT_NAME、poster は read_poster_name が
#    POSTER_NAME/DOCUMENT_NAME を要求する。
missing_noninteractive_inputs() {
    local missing=""
    if ! [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]] && [ -z "$STUDENT_ID" ]; then
        missing="STUDENT_ID"
    fi
    case "$DOC_TYPE" in
        latex)
            if [ -z "$DOCUMENT_NAME" ]; then
                missing="${missing:+$missing, }DOCUMENT_NAME"
            fi
            ;;
        poster)
            if [ -z "$POSTER_NAME" ] && [ -z "$DOCUMENT_NAME" ]; then
                missing="${missing:+$missing, }POSTER_NAME/DOCUMENT_NAME"
            fi
            ;;
    esac
    printf '%s' "$missing"
}

DOCKER_OPTIONS="--rm"
INTERACTIVE=true
if [[ "${ASSUME_YES:-}" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
    # 入力欠落のまま非対話にすると、コンテナ内で EOF が空回答＝Yes と誤解釈されたり
    # STUDENT_ID が GitHub ユーザー名へ誤フォールバックする。コンテナ起動前に止める。
    MISSING_INPUTS=$(missing_noninteractive_inputs)
    if [ -n "$MISSING_INPUTS" ]; then
        echo "❌ ASSUME_YES での非対話実行には次の入力が必要です（$DOC_TYPE）: $MISSING_INPUTS" >&2
        echo "   組織フローの例: STUDENT_ID=k21rs001 ASSUME_YES=1 ... bash $DOC_TYPE" >&2
        exit 1
    fi
    # コンテナ側 confirm_creation を自動承認させる（正規化済みの true を転送）
    DOCKER_ENV_VARS="$DOCKER_ENV_VARS -e ASSUME_YES=true"
    INTERACTIVE=false
elif [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
    case "$DOC_TYPE" in
        latex)
            if [ -n "$DOCUMENT_NAME" ]; then INTERACTIVE=false; fi
            ;;
        poster)
            if [ -n "$POSTER_NAME" ] || [ -n "$DOCUMENT_NAME" ]; then INTERACTIVE=false; fi
            ;;
    esac
fi
if [ "$INTERACTIVE" = false ]; then
    echo "📋 非対話的モードで実行（$DOC_TYPE）"
else
    DOCKER_OPTIONS="$DOCKER_OPTIONS -it"
fi

# 統一されたDocker実行（全タイプ共通）
if [ -n "$STUDENT_ID" ]; then
    if ! docker run $DOCKER_OPTIONS $DOCKER_ENV_VARS -v "$TOKEN_FILE:/tmp/gh_token:ro" "$DOCKER_IMAGE_NAME" "$STUDENT_ID"; then
        echo "❌ セットアップスクリプトの実行に失敗しました"
        echo "学籍番号: $STUDENT_ID"
        exit 1
    fi
else
    if ! docker run $DOCKER_OPTIONS $DOCKER_ENV_VARS -v "$TOKEN_FILE:/tmp/gh_token:ro" "$DOCKER_IMAGE_NAME"; then
        echo "❌ セットアップスクリプトの実行に失敗しました"
        exit 1
    fi
fi

# 成功メッセージ（クリーンアップは trap で自動実行）
echo ""
echo "✅ $DOC_DESCRIPTION のセットアップが完了しました！"