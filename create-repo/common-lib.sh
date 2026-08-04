#!/bin/bash
# 共通ライブラリ: main*.sh スクリプト用の共通関数・変数定義（リファクタリング版）

# ================================
# 設定・定数
# ================================

# スクリプトディレクトリを読み込み時に確定（cd後でも正しいパスを参照できるように）
# 注: source で読み込まれた場合、${BASH_SOURCE[0]} はこのファイルのパス
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# 色定義
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly BRIGHT_WHITE='\033[1;37m'
readonly NC='\033[0m'

# デフォルト設定
readonly DEFAULT_ORG="smkwlab"
# リポジトリ名の規約（org 部分は実行時に導出。ECOSYSTEM.md の
# Organization-Scoped Deployment 原則を参照）。env で上書き可能
REGISTRY_REPO_NAME="${REGISTRY_REPO_NAME:-thesis-student-registry}"
TOOLS_REPO_NAME="${TOOLS_REPO_NAME:-student-repo-management}"
readonly REGISTRY_REPO_NAME TOOLS_REPO_NAME
readonly STUDENT_ID_PATTERN='^k[0-9]{2}(rs|jk|gjk)[0-9]+$'

# ================================
# ユーティリティ関数
# ================================

# ログ出力（統一フォーマット）
log_info() { echo -e "${GREEN}✓ $*${NC}" >&2; }
log_warn() { echo -e "${YELLOW}⚠️ $*${NC}" >&2; }
log_error() { echo -e "${RED}❌ $*${NC}" >&2; }
log_debug() { echo -e "${BLUE}🔍 $*${NC}" >&2; }

# エラー終了
die() { log_error "$*"; exit 1; }

# コマンド存在確認
command_exists() { command -v "$1" >/dev/null 2>&1; }

# INDIVIDUAL_MODE 判定（真なら 0 を返す）
# 各所に散在する [[ "$INDIVIDUAL_MODE" =~ ... ]] と同一の判定（Issue #516）
is_individual_mode() { [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; }

# ASSUME_YES 判定（真なら 0 を返す）
# 確認プロンプト（confirm_creation）を自動承認する非対話フラグ。個人アカウント
# 作成を意味する INDIVIDUAL_MODE とは独立で、組織フローの非対話実行にも使う
# （Issue #527）。setup.sh が docker run 時に -e ASSUME_YES=true を注入する。
is_assume_yes() { [[ "$ASSUME_YES" =~ ^(true|TRUE|1|yes|YES)$ ]]; }

# ================================
# 初期化・設定関数
# ================================

# スクリプト共通初期化
init_script_common() {
    local script_name="$1"
    local script_emoji="$2"
    
    echo "$script_emoji $script_name"
    echo "=============================================="
    
    # 依存関数の呼び出し
    check_github_auth_docker || exit 1
    setup_operation_mode
    get_current_user || exit 1
    
    # グローバル変数として設定
    export OPERATION_MODE INDIVIDUAL_MODE CURRENT_USER
}

# 動作モード設定
setup_operation_mode() {
    # 環境変数 INDIVIDUAL_MODE が既に設定されている場合は優先
    if [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        log_info "👤 個人ユーザーモード有効（環境変数指定）"
        OPERATION_MODE="individual"
        INDIVIDUAL_MODE=true
        return
    fi

    local user_type="${USER_TYPE:-organization_member}"

    if [ "$user_type" = "individual_user" ]; then
        log_info "👤 個人ユーザーモード有効"
        OPERATION_MODE="individual"
        INDIVIDUAL_MODE=true
    else
        log_info "🏢 組織ユーザーモード（従来通り）"
        OPERATION_MODE="organization"
        INDIVIDUAL_MODE=false
    fi
}

# 現在ユーザー取得
get_current_user() {
    log_debug "GitHub認証情報を確認中..."
    
    if ! CURRENT_USER=$(gh api user --jq .login 2>/dev/null); then
        log_error "GitHub APIアクセスに失敗しました"
        echo "認証トークンを更新してください："
        echo "  gh auth refresh"
        return 1
    fi
    
    log_info "GitHubユーザー: $CURRENT_USER"
}

# ================================
# 認証関連関数
# ================================

# GitHub認証確認（統合版）
check_github_auth_docker() {
    log_debug "GitHub認証を確認中..."
    
    # 環境変数認証（Git Bashからの受け渡し含む）
    if validate_token_env; then
        log_info "GitHub認証済み（環境変数認証）"
        return 0
    else
        log_debug "環境変数GH_TOKENが未設定または無効。セキュアファイル認証を試みます。"
    fi
    
    # セキュアファイル認証
    if validate_token_file "/tmp/gh_token"; then
        log_info "GitHub認証済み（セキュアファイル認証）"
        return 0
    fi
    
    # インタラクティブ認証
    if ! gh auth status &>/dev/null; then
        perform_interactive_auth || return 1
    else
        log_info "GitHub認証済み"
    fi
}

# トークンファイル検証
validate_token_file() {
    local token_file="$1"
    
    [ -f "$token_file" ] || return 1
    
    log_info "ホストからセキュアトークンを取得しました"
    export GH_TOKEN=$(cat "$token_file")
    
    if gh auth status &>/dev/null; then
        return 0
    else
        log_error "提供されたトークンが無効です"
        return 1
    fi
}

# 環境変数トークン検証
validate_token_env() {
    [ -n "$GH_TOKEN" ] || return 1
    
    log_info "ホストから認証トークンを取得しました（環境変数）"
    export GH_TOKEN
    
    if gh auth status &>/dev/null; then
        return 0
    else
        log_error "提供されたトークンが無効です"
        return 1
    fi
}

# インタラクティブ認証実行
perform_interactive_auth() {
    log_warn "GitHub認証が必要です"
    echo ""
    echo "=== ブラウザ認証手順 ==="
    echo "1. ブラウザで https://github.com/login/device が開いているはずです"
    echo -e "2. ${GREEN}Continue${NC} ボタンをクリック"
    echo -e "3. 下から2行目の以下のような行の ${YELLOW}XXXX-XXXX${NC} をコピーしてブラウザに入力:"
    echo -e "   ${YELLOW}!${NC} First copy your one-time code: ${BRIGHT_WHITE}XXXX-XXXX${NC}"
    echo -e "4. ${GREEN}Authorize github${NC} ボタンをクリックする"
    echo ""

    if echo -e "Y\n" | gh auth login --hostname github.com --git-protocol https --web --skip-ssh-key --scopes "repo,workflow,read:org,gist"; then
        log_info "GitHub認証完了"
    else
        log_error "GitHub認証に失敗しました"
        return 1
    fi
}

# Git認証設定
setup_git_auth() {
    log_debug "Git認証を設定中..."
    
    if ! gh auth setup-git; then
        log_error "Git認証設定に失敗しました"
        log_error "GitHub CLIの認証が正しく設定されているか確認してください"
        return 1
    fi
    
    log_info "Git認証設定完了"
}

# Gitユーザー設定
# コミット作者のメールドメインは SETUP_GIT_EMAIL_DOMAIN で上書き可能（既定 smkwlab.github.io）。
setup_git_user() {
    local email="${1:-setup@${SETUP_GIT_EMAIL_DOMAIN:-smkwlab.github.io}}"
    local name="${2:-Setup Tool}"
    
    git config user.email "$email"
    git config user.name "$name"
}

# ================================
# 学籍番号・組織関連関数
# ================================

# 学籍番号正規化（改良版）
normalize_student_id() {
    local student_id="$1"
    
    # 入力検証
    [ -n "$student_id" ] || die "学籍番号が指定されていません"
    
    # 小文字化
    student_id=$(echo "$student_id" | tr '[:upper:]' '[:lower:]')
    
    # k プリフィックスの自動追加
    if echo "$student_id" | grep -qE '^[0-9]{2}(rs|jk|gjk)[0-9]+$'; then
        local original="$student_id"
        student_id="k${student_id}"
        log_warn "学籍番号を正規化しました: $original → $student_id"
    fi
    
    # 形式検証
    if ! echo "$student_id" | grep -qE "$STUDENT_ID_PATTERN"; then
        log_error "学籍番号の形式が正しくありません: $student_id"
        echo "   正しい形式: k21rs001, k22gjk01 など" >&2
        return 1
    fi
    
    echo "$student_id"
}

# 学籍番号入力
read_student_id() {
    local input_id="$1"
    local examples="${2:-k21rs001, k21gjk01}"
    
    if [ -n "$input_id" ]; then
        echo "$input_id"
        return 0
    fi
    
    echo "" >&2
    echo "学籍番号を入力してください" >&2
    echo "  例: $examples" >&2
    echo "" >&2
    read -p "学籍番号: " student_id
    
    # 無入力の場合、GitHubユーザー名を自動使用
    if [ -z "$student_id" ]; then
        # GitHub CLIの存在確認とユーザー名取得
        if command -v gh >/dev/null 2>&1; then
            local github_username=$(gh api user --jq .login 2>/dev/null || echo "")
            if [ -n "$github_username" ]; then
                # GitHubユーザー名を使用することを通知（開発者向け機能として控えめに）
                echo -e "${BLUE}→ GitHub ユーザー名を使用: $github_username${NC}" >&2
                student_id="$github_username"
            else
                # GitHub CLIは存在するが認証されていない場合
                log_debug "GitHub ユーザー名の取得に失敗しました"
            fi
        else
            # GitHub CLIがインストールされていない場合
            log_debug "GitHub CLIがインストールされていません"
        fi
    fi
    
    echo "$student_id"
}

# INDIVIDUAL_MODE を考慮した学籍番号の取得
# - INDIVIDUAL_MODE が真のときは入力をスキップして空文字を返す
# - それ以外は read_student_id → normalize_student_id を通した学籍番号を返す
# ログ類は stderr に出力されるため、STUDENT_ID=$(read_student_id_if_needed "$1") の
# ように stdout を捕捉しても汚染されない。正規化に失敗した場合は 1 を返す。
# 呼び出し側は必ず `|| exit 1` を付けて使うこと（set -e 下の bare 代入でも停止するが、
# 明示しておくことで set -e 無効時や local 代入時にも確実に停止できる）。
# 使い方: STUDENT_ID=$(read_student_id_if_needed "$1" "卒業論文の例: k21rs001 ...") || exit 1
read_student_id_if_needed() {
    local input_id="$1"
    local examples="$2"

    if [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        log_debug "個人モード: 学籍番号の入力をスキップします"
        echo ""
        return 0
    fi

    local student_id
    student_id=$(read_student_id "$input_id" "$examples")
    student_id=$(normalize_student_id "$student_id") || return 1
    log_info "学籍番号: $student_id"
    echo "$student_id"
}

# 組織設定決定
determine_organization() {
    local default_org="${1:-$DEFAULT_ORG}"
    
    if [ -n "$TARGET_ORG" ]; then
        echo "$TARGET_ORG"
        log_info "指定された組織: $TARGET_ORG"
    elif [ -n "$GITHUB_REPOSITORY" ]; then
        local org=$(echo "$GITHUB_REPOSITORY" | cut -d'/' -f1)
        echo "$org"
        log_info "自動検出された組織: $org"
    else
        echo "$default_org"
        log_warn "デフォルト組織を使用: $default_org"
    fi
}

# 組織メンバーシップ確認
check_organization_membership() {
    local org="$1"
    local user="$2"
    
    log_debug "🏢 組織アクセス権限を確認中..."
    
    if ! gh api "orgs/${org}/members/${user}" >/dev/null 2>&1; then
        log_error "${org} 組織のメンバーではありません"
        echo ""
        echo "以下を確認してください："
        echo "  1. GitHub 組織への招待メールを確認"
        echo "  2. 組織のメンバーシップが有効化されているか確認"
        echo "  3. 正しいGitHubアカウントでログインしているか確認"
        echo ""
        echo "招待が届いていない場合は、担当教員にお問い合わせください。"
        return 1
    fi
    
    log_info "${org} 組織のメンバーシップ確認済み"
}

# 組織アクセス確認（条件付き）
check_organization_access() {
    local organization="$1"
    
    # INDIVIDUAL_MODEが有効でない場合のみ組織メンバーシップをチェック
    if ! [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        check_organization_membership "$organization" "$CURRENT_USER" || exit 1
    fi
}

# ================================
# リポジトリ操作関数
# ================================

# リポジトリパス決定
determine_repository_path() {
    local organization="$1"
    local repo_name="$2"
    
    if [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        echo "${CURRENT_USER}/${repo_name}"
    else
        echo "${organization}/${repo_name}"
    fi
}

# ユーザー確認プロンプト
confirm_creation() {
    local repo_path="$1"
    
    echo ""
    echo -e "${BRIGHT_WHITE}🎯 作成予定リポジトリ: $repo_path${NC}"
    echo ""
    
    # INDIVIDUAL_MODEの場合は自動承認（柔軟な値判定）
    if [[ "$INDIVIDUAL_MODE" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
        echo "📋 個人モード: 自動的に続行します"
        return 0
    fi

    # ASSUME_YES の場合も自動承認（組織フローの非対話実行。Issue #527）
    if is_assume_yes; then
        echo "📋 ASSUME_YES: 確認を省略して続行します"
        return 0
    fi

    read -p "続行しますか? [Y/n]: " -n 1 -r
    echo ""
    
    if [[ ! $REPLY =~ ^[Yy]$ ]] && [[ ! -z $REPLY ]]; then
        log_warn "キャンセルしました"
        return 1
    fi
    
    return 0
}

# リポジトリ作成（統一インターフェース）
create_repository() {
    local repo_path="$1"
    local template_repo="$2"
    local visibility="${3:-private}"
    local clone_flag="${4:-true}"
    local description="${5:-}"
    
    local create_args=("$repo_path" "--template=$template_repo")
    
    # 可視性設定
    if [ "$visibility" = "public" ]; then
        create_args+=("--public")
    else
        create_args+=("--private")
    fi
    
    # Description設定
    [ -n "$description" ] && create_args+=("--description" "$description")
    
    # クローン設定
    [ "$clone_flag" = "true" ] && create_args+=("--clone")
    
    if gh repo create "${create_args[@]}"; then
        log_info "リポジトリを作成しました: https://github.com/$repo_path"
        return 0
    else
        log_error "リポジトリの作成に失敗しました"
        echo "- 既に同名のリポジトリが存在する可能性があります" >&2
        echo "- 組織への権限が不足している可能性があります" >&2
        return 1
    fi
}

# リポジトリクローン
clone_repository() {
    local repo_url="$1"
    local repo_name="${2:-$(basename "$repo_url" .git)}"
    
    log_debug "📦 リポジトリをクローン中..."
    
    if ! git clone "$repo_url"; then
        log_error "リポジトリのクローンに失敗しました"
        echo "リポジトリ: $repo_url"
        return 1
    fi
    
    log_info "リポジトリクローン完了"
    cd "$repo_name" || return 1
}

# Git操作（コミット・プッシュ）
# Note: git add . を使用するのは、セットアップ時に新規作成されるファイル
# （.devcontainer/, .github/ 等）も含めてステージングする必要があるため。
# 呼び出し元で git add -u を使用する場合は、事前にステージングを行うこと。
# git push をリトライする共通ヘルパー（Issue #511）。
# 一斉作成時の一過性エラー（push 競合・API レート制限・ネットワーク瞬断）を吸収し、
# ブランチの取りこぼしを防ぐ。線形バックオフ（1 秒, 2 秒, ...）で再試行する。
# Args:
#   $1: branch       - push するブランチ名
#   $2: max_attempts - 最大試行回数（既定 3）
push_with_retry() {
    local branch="$1"
    local max_attempts="${2:-3}"
    local attempt=1
    local err

    while true; do
        # stderr を捨てずに捕捉し、失敗時の原因（rejected / permission / protected
        # branch など）をログに残す。永続的エラーの事後調査を可能にする（Issue #511）。
        if err=$(git push origin "$branch" 2>&1); then
            return 0
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            log_error "push に ${max_attempts} 回失敗しました（${branch}）"
            log_error "  最後のエラー: ${err}"
            return 1
        fi
        log_warn "push 失敗（${branch}, ${attempt}/${max_attempts} 回目）。${attempt} 秒後に再試行します"
        log_warn "  エラー詳細: ${err}"
        sleep "$attempt"
        attempt=$((attempt + 1))
    done
}

commit_and_push() {
    local commit_message="$1"
    local branch="${2:-main}"

    echo "📤 変更をコミット中..."
    git add . >/dev/null 2>&1
    git commit -m "$commit_message" >/dev/null 2>&1
    
    if push_with_retry "$branch"; then
        log_info "変更をプッシュしました"
        return 0
    else
        log_error "プッシュに失敗しました"
        return 1
    fi
}

# ================================
# Issue・レポート関連関数
# ================================

# リポジトリ作成Issue生成
create_repository_issue() {
    local repo_name="$1"
    local student_id="$2"
    local repo_type="${3:-latex}"
    local organization="${4:-$DEFAULT_ORG}"
    
    log_info "Registry Manager登録中..."
    
    local issue_body
    issue_body=$(generate_issue_body "$organization" "$repo_name" "$student_id" "$repo_type")
    
    local issue_number
    if issue_number=$(gh issue create \
        --repo "${organization}/${TOOLS_REPO_NAME}" \
        --title "📋 リポジトリ登録依頼: ${organization}/${repo_name}" \
        --body "$issue_body" 2>&1 | grep -oE '[0-9]+$'); then
        
        # Issue作成成功時は何も出力しない（簡潔にする）
        return 0
    else
        log_warn "Registry Manager登録に失敗しました（続行します）"
        return 1
    fi
}

# Issue本文生成
generate_issue_body() {
    local organization="$1"
    local repo_name="$2"
    local student_id="$3"
    local repo_type="${4:-latex}"  # デフォルトは最も汎用的な latex タイプ

    # latex は作成時オプトイン（REVIEW_FLOW）でレビューフローの有無が分かれるため、
    # 有効時のみ Issue に記録し、process-pending-issues がブランチ保護の要否を
    # 判定できるようにする（他タイプはタイプ自体で要否が決まるため記載しない）。
    # USE_DRAFT_FLOW は main.sh のグローバル。未定義の呼び出し元では従来どおり空
    local review_flow_line=""
    if [ "$repo_type" = "latex" ] && [ "${USE_DRAFT_FLOW:-false}" = true ]; then
        review_flow_line="- **レビューフロー**: on"
    fi

    cat << EOF
## リポジトリ登録依頼

### リポジトリ情報
- **リポジトリ**: [${organization}/${repo_name}](https://github.com/${organization}/${repo_name})
- **学生ID**: ${student_id}
- **リポジトリタイプ**: ${repo_type}${review_flow_line:+
$review_flow_line}
- **作成日時**: $(date '+%Y-%m-%d %H:%M') JST

### 処理内容
- [ ] リポジトリをシステムに登録
- [ ] ブランチ保護設定（論文リポジトリのみ）
- [ ] 設定完了を確認: [リポジトリ設定](https://github.com/${organization}/${repo_name}/settings/branches)

### 一括処理オプション
複数の学生を一括処理する場合：
\`\`\`bash
cd ${TOOLS_REPO_NAME}/scripts
# GitHub Actionsの自動処理を利用
# または手動で一括実行
./bulk-setup-protection.sh
\`\`\`

### ブランチ保護ルール（論文リポジトリのみ）
- 1つ以上の承認レビューが必要
- 新しいコミット時に古いレビューを無効化
- フォースプッシュとブランチ削除を禁止

---
*この Issue は学生の setup.sh 実行時に自動生成されました*
*学生ID: ${student_id} | リポジトリ: ${repo_name} | 作成: $(date '+%Y-%m-%d %H:%M') JST*
EOF
}

# ================================
# レビューワークフロー管理関数
# ================================

#
# レビューワークフロー設定
#
# Args:
#   $1: draft_branch - ドラフトブランチ名（例: 0th-draft）
#
setup_review_workflow() {
    local draft_branch="$1"

    if [ -z "$draft_branch" ]; then
        log_error "setup_review_workflow: ドラフトブランチ名が指定されていません"
        return 1
    fi

    log_info "🌿 ドラフトブランチを作成中: $draft_branch"

    if ! git checkout -b "$draft_branch" >/dev/null 2>&1; then
        log_error "$draft_branch ブランチの作成に失敗しました"
        return 1
    fi

    log_info "✅ ドラフトブランチ作成完了"
    return 0
}

#
# main ブランチ確定 + draft PR サイクル開始
#
# main-thesis.sh / main-ise.sh で完全に重複していた「main へのセットアップ
# コミット → push → 0th-draft ブランチ作成 → 初期ドラフト commit/push」を
# 逐語で吸収した関数（Issue #516）。
#
# 重要: 必ず bare call（`finalize_with_draft_flow "$msg"`）で呼ぶこと。
# `finalize_with_draft_flow "$msg" || exit 1` のように || / && / if の文脈で
# 呼ぶと、bash の仕様で関数本体内の set -e が無効化され、git add -u 失敗時の
# 「即時中断」（旧実装のトップレベル bare call の挙動）が「継続して成功報告」
# に変わってしまう。bare call なら set -e が関数内にも効き、旧実装と終了
# コードまで一致する。
#
# main コミットのステージングは git add -u + .github/ + .devcontainer/ に
# 限定する（git add . ではない）。これ以外の未追跡ファイルは 0th-draft 側の
# commit_and_push（git add .）で初めてコミットされるのが現行挙動。
# `git commit ... || true` の || true も既存挙動（変更なし等の失敗を許容）の
# 温存であり、外さないこと。
#
# Args:
#   $1: commit_message - main / 0th-draft 双方のコミットメッセージ
#
finalize_with_draft_flow() {
    local commit_message="$1"

    # main ブランチでの初期セットアップコミット
    git add -u
    git add .github/ 2>/dev/null || true
    git add .devcontainer/ 2>/dev/null || true
    git commit -m "$commit_message" >/dev/null 2>&1 || true

    if push_with_retry main; then
        log_info "main ブランチセットアップ完了"
    else
        die "main ブランチのプッシュに失敗しました"
    fi

    # ドラフトブランチを作成
    # 内部呼び出しの `|| return 1` は意図的（旧 main-thesis.sh L86/L89 の
    # `|| exit 1` と同じ「|| 文脈」を保つ）。これらを bare call に「修正」すると
    # 挙動が変わる: 特に commit_and_push は内部の bare な git commit が変更なしで
    # 失敗し得るが、|| 文脈では set -e が無効化され push_with_retry へ進む——これが
    # 旧挙動。bare 化すると git commit 失敗で即中断してしまう。関数の戻り値 1 は
    # bare 呼び出し元（メインフロー）の set -e で拾われ、旧実装と終了コードも一致する。
    setup_review_workflow "0th-draft" || return 1

    # 初期ドラフトをコミット・プッシュ
    commit_and_push "$commit_message" "0th-draft" || return 1
}

#
# LaTeX環境セットアップ関数
#
setup_latex_environment() {
    log_info "LaTeX環境をセットアップ中..."
    
    # aldc の取得元。既定は smkwlab の公開 aldc。他 org で独自 aldc を使う場合は
    # ALDC_URL で上書きする（setup.sh がコンテナへ転送する）。
    local aldc_url="${ALDC_URL:-https://raw.githubusercontent.com/smkwlab/aldc/main/aldc}"

    # curlでaldcスクリプトを実行（メッセージ抑制）
    if ALDC_QUIET=1 /bin/bash -c "$(curl -fsSL "$aldc_url")" 2>/dev/null; then
        log_info "LaTeX環境のセットアップ完了"
        return 0
    else
        log_warn "LaTeX環境は手動設定が必要"
        log_info "手動セットアップ手順:"
        log_info "  /bin/bash -c \"\$(curl -fsSL \"${aldc_url}\")\""
        return 1
    fi
}

# テンプレートファイルの整理
#
# 自動生成リポジトリに不要なファイルを削除します。
# - CLAUDE.md      : テンプレート／latex-environment 由来の開発者向け説明（学生リポジトリには不要）
# - docs/          : テンプレート／latex-environment 由来のドキュメント
# - *-aldc         : aldc が統合時に生成する衝突ファイルのバックアップ
# - .github/README.md : テンプレートの使い方説明（学生リポジトリでは root の
#                       著者情報 README をトップに出すために削除する）
#
# 重要: この関数は aldc 実行（setup_latex_environment）の **後** に呼ぶ必要があります。
# aldc は latex-environment 由来の CLAUDE.md / docs/ を持ち込み、既存ファイルと衝突した
# 場合は <元ファイル名>-aldc としてバックアップを残すため、aldc 実行前に削除しても
# これらは再生成・残存してしまいます（Issue #433）。
#
# 戻り値:
#   0 - 常に成功
cleanup_template_files() {
    log_info "テンプレートファイルを整理中..."
    rm -f CLAUDE.md 2>/dev/null || true
    rm -rf docs/ 2>/dev/null || true
    find . -name '*-aldc' -exec rm -rf {} + 2>/dev/null || true
    # 学生リポジトリでは依存の自動更新は不要（最新化はテンプレート側で管理）。誤マージ
    # 防止 CI（prevent-draft-merge）や review 必須保護と bot の PR が干渉して溜まるため、
    # 生成時に削除する（#514）。
    #
    # renovate.json も同じ理由で消す。こちらは aldc が latex-environment の release
    # ブランチから持ち込む。Renovate App が学生リポジトリに入っていないので現状は何も
    # 起きないが、それは App のインストール範囲というコード管理外の設定に安全性を
    # 預けている状態であり、範囲が広がれば全学生リポジトリで動き出す。
    rm -f .github/dependabot.yml 2>/dev/null || true
    rm -f .github/renovate.json 2>/dev/null || true
    # GitHub は README を .github/ → root → docs/ の順に探して最初の 1 つを表示する。
    # テンプレート側はこの性質を使い、テンプレートの使い方を .github/README.md に、
    # 学生が記入する著者情報を root の README.md に置いている。ここで前者を削除する
    # ことで、学生リポジトリのトップに著者情報 README が表示される
    # （smkwlab/latex-ecosystem#140）。
    rm -f .github/README.md 2>/dev/null || true
    return 0
}

# smkwlab 組織メンバー用の auto-assign 設定追加
#
# 組織メンバーの場合のみ、PR自動レビュワー割り当て設定を追加します。
# テンプレートリポジトリには含めず、setup時に動的に追加することで
# セキュアバイデフォルトを実現します。
#
# 環境変数:
#   USER_TYPE - "organization_member" または "individual_user"
#   SCRIPT_DIR - スクリプトのディレクトリパス（templates/ を参照）
#
# 戻り値:
#   0 - 成功（設定追加完了または不要）
setup_auto_assign_for_organization_members() {
    # 組織メンバーの場合のみ auto-assign 設定を追加
    if [ "$USER_TYPE" = "organization_member" ]; then
        log_info "組織メンバー: auto-assign設定を追加します"

        # .github/workflows ディレクトリが存在することを確認
        mkdir -p .github/workflows

        # スクリプトディレクトリを特定（SCRIPT_DIR が未定義の場合）
        local script_dir="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
        local template_dir="${script_dir}/templates"

        # テンプレートディレクトリの存在確認
        if [ ! -d "${template_dir}" ]; then
            log_error "テンプレートディレクトリが見つかりません: ${template_dir}"
            return 1
        fi

        # テンプレートファイルをコピー
        if [ -f "${template_dir}/autoassignees.yml" ]; then
            cp "${template_dir}/autoassignees.yml" .github/workflows/
            log_info "  ✓ .github/workflows/autoassignees.yml を追加"
        else
            log_warn "  ⚠️ テンプレートファイルが見つかりません: ${template_dir}/autoassignees.yml"
        fi

        # auto-assign の reviewer/assignee。既定は smkwlab の担当者。他 org では
        # AUTO_ASSIGN_REVIEWER で上書きする（setup.sh がコンテナへ転送する）。
        # プレースホルダを sed 置換するため、GitHub ログイン文字種のみ許可する。
        # このコンテナ側チェックは、コンテナを setup.sh 経由せず直接実行する場合にも
        # 効かせるための防御（setup.sh 側にも同等の検証がある）。
        local reviewer="${AUTO_ASSIGN_REVIEWER:-toshi0806}"
        case "$reviewer" in
            ""|*[!A-Za-z0-9-]*)
                log_error "AUTO_ASSIGN_REVIEWER が不正です（英数字とハイフンのみ）: $reviewer"
                return 1 ;;
        esac
        if [ -f "${template_dir}/auto_assign_myteams.yml" ]; then
            sed "s/__AUTO_ASSIGN_REVIEWER__/${reviewer}/g" \
                "${template_dir}/auto_assign_myteams.yml" > .github/auto_assign_myteams.yml
            log_info "  ✓ .github/auto_assign_myteams.yml を追加 (reviewer: ${reviewer})"
        else
            log_warn "  ⚠️ テンプレートファイルが見つかりません: ${template_dir}/auto_assign_myteams.yml"
        fi
    else
        log_info "外部ユーザー: auto-assign設定はスキップします"
    fi
    return 0
}

# 組織専用ワークフローの削除
#
# 組織外ユーザーの場合、Organization Secretsに依存するワークフローを削除します。
# これにより、ワークフロー実行時のエラーを防ぎます。
#
# 環境変数:
#   USER_TYPE - "organization_member" または "individual_user"
#
# 削除対象:
#   - .github/workflows/notify-ml-on-pr.yml (組織MLへのPR通知)
#
# 戻り値:
#   0 - 成功（削除完了または不要）
remove_org_specific_workflows() {
    if [ "$USER_TYPE" = "individual_user" ]; then
        log_info "組織外ユーザー: ML通知ワークフローを削除"
        rm -f .github/workflows/notify-ml-on-pr.yml 2>/dev/null || true
    fi
    return 0
}

# ================================
# 高レベルセットアップ関数
# ================================

#
# 標準セットアップフロー
#
# 共通的なリポジトリセットアップ処理を実行します。
# - 組織アクセス確認
# - リポジトリ存在確認
# - 作成確認プロンプト
# - リポジトリ作成
# - Git認証設定
# - 共通ファイル整理
#
# 前提条件（呼び出し前に設定が必要）:
#   ORGANIZATION - 組織名
#   REPO_NAME - リポジトリ名
#   TEMPLATE_REPOSITORY - テンプレートリポジトリパス
#   VISIBILITY - "private" または "public"
#
# Args:
#   $1: doc_type - ドキュメントタイプ（thesis, wr, latex, ise, poster）
#
# 結果:
#   REPO_PATH - 作成されたリポジトリのパス（グローバル変数として設定）
#
# 戻り値:
#   0 - 成功
#   1 - 失敗
#
run_standard_setup() {
    local doc_type="$1"

    # ドキュメントタイプの表示名マッピング（略語は大文字）
    local display_name
    case "$doc_type" in
        ise)    display_name="ISE" ;;
        wr)     display_name="WR" ;;
        thesis) display_name="Thesis" ;;
        latex)  display_name="LaTeX" ;;
        poster) display_name="Poster" ;;
        *)      display_name="$doc_type" ;;
    esac

    # 組織アクセス確認
    check_organization_access "$ORGANIZATION"

    # リポジトリパス決定
    REPO_PATH=$(determine_repository_path "$ORGANIZATION" "$REPO_NAME")

    # リポジトリの存在確認
    if gh repo view "$REPO_PATH" >/dev/null 2>&1; then
        die "リポジトリ $REPO_PATH は既に存在します"
    fi

    # 作成確認
    confirm_creation "$REPO_PATH" || exit 0

    # リポジトリ作成
    echo ""
    echo "📁 リポジトリを作成中..."
    create_repository "$REPO_PATH" "$TEMPLATE_REPOSITORY" "$VISIBILITY" "true" || exit 1
    cd "$REPO_NAME" || exit 1

    # Git設定
    setup_git_auth || exit 1
    setup_git_user "setup-${doc_type}@${SETUP_GIT_EMAIL_DOMAIN:-smkwlab.github.io}" "${display_name} Setup Tool"

    # 注意: テンプレートファイルの整理（CLAUDE.md / docs/ / *-aldc 削除）は
    # ここでは行わない。aldc（setup_latex_environment）が latex-environment 由来の
    # CLAUDE.md / docs/ を持ち込み、衝突ファイルを *-aldc として生成するため、
    # 整理は aldc 実行後に cleanup_template_files() で行う必要がある（Issue #433）。
}

#
# Registry Manager連携
#
# 組織ユーザーの場合、リポジトリをRegistry Managerに登録します。
# thesis-student-registry リポジトリにアクセス可能な場合のみ登録を実行します。
#
# 注意: INDIVIDUAL_MODE のチェックは呼び出し側の責任です。
#       呼び出し側で INDIVIDUAL_MODE でないことを確認してから呼び出してください。
#
# 前提条件:
#   STUDENT_ID - 学籍番号
#   ORGANIZATION - 組織名
#   REPO_NAME - リポジトリ名
#
# Args:
#   $1: doc_type - ドキュメントタイプ（thesis, wr, latex, ise, poster）
#
run_registry_integration() {
    local doc_type="$1"

    # 条件: Registryリポジトリがアクセス可能
    # 注: INDIVIDUAL_MODE のチェックは呼び出し側の責任
    if gh repo view "${ORGANIZATION}/${REGISTRY_REPO_NAME}" &>/dev/null; then
        if ! create_repository_issue "$REPO_NAME" "$STUDENT_ID" "$doc_type" "$ORGANIZATION"; then
            log_warn "Registry Manager登録でエラーが発生しました。手動で登録が必要な場合があります。"
        fi
    else
        # 従来はここで無言 return しており、登録漏れに誰も気づけなかった
        log_warn "レジストリ ${ORGANIZATION}/${REGISTRY_REPO_NAME} にアクセスできないため、登録依頼をスキップしました。手動登録が必要です。"
    fi
}

#
# 完了メッセージ表示
#
# 標準的な完了メッセージを表示します。
#
# 前提条件:
#   REPO_PATH - リポジトリパス
#
# Args:
#   $1: additional_message - 追加メッセージ（オプション、改行区切り）
#
print_completion_message() {
    local additional_message="$1"

    echo ""
    echo "=============================================="
    echo -e "${GREEN}✅ セットアップが完了しました！${NC}"
    echo ""
    echo "リポジトリ: https://github.com/${REPO_PATH}"

    if [ -n "$additional_message" ]; then
        echo ""
        echo "$additional_message"
    fi

    echo ""
    echo "=============================================="
}
