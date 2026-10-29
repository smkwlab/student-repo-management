#!/bin/bash
#
# 未処理Issue一括処理スクリプト
# Usage: ./process-pending-issues.sh [options]
#
# 蓄積された「リポジトリ登録依頼」Issueを効率的に処理します
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# デフォルト設定
DEFAULT_REPO="smkwlab/student-repo-management"
# レジストリリポジトリ名の規約（org 部分は実行時に導出する。ECOSYSTEM.md の
# Organization-Scoped Deployment 原則を参照）
REGISTRY_REPO_NAME="thesis-student-registry"
DEFAULT_LOG_DIR="$PROJECT_ROOT/logs"
DEFAULT_BACKUP_DIR="$PROJECT_ROOT/backups"

# 実行時設定
# Actions では GITHUB_REPOSITORY（自 repo）から導出、ローカルのみ既定値へ fallback
REPO="${REPO:-${GITHUB_REPOSITORY:-$DEFAULT_REPO}}"
# 空 = 規約で解決（resolve_registry_repo）。env / --registry-repo は明示 override
REGISTRY_REPO="${REGISTRY_REPO:-}"
LOG_DIR="${LOG_DIR:-$DEFAULT_LOG_DIR}"
BACKUP_DIR="${BACKUP_DIR:-$DEFAULT_BACKUP_DIR}"

#
# デプロイ org の解決（Organization-Scoped Deployment: 1 org = 1 デプロイ単位）
# 学生リポジトリ操作とレジストリ規約の両方がこの単一の org 文脈を参照する。
# GitHub Actions では GITHUB_REPOSITORY_OWNER、ローカルでは --repo の owner 部分
#
DEPLOY_ORG=""
resolve_deploy_org() {
    [ -n "$DEPLOY_ORG" ] && return 0

    DEPLOY_ORG="${GITHUB_REPOSITORY_OWNER:-${REPO%%/*}}"

    if [ -z "$DEPLOY_ORG" ]; then
        log_error "デプロイ org を解決できません（GITHUB_REPOSITORY_OWNER / --repo を確認してください）"
        exit 1
    fi
}

#
# レジストリリポジトリの解決
# 優先順位: --registry-repo フラグ / env REGISTRY_REPO > 規約 <org>/thesis-student-registry
#
resolve_registry_repo() {
    if [ -n "$REGISTRY_REPO" ]; then
        return 0
    fi

    # 呼び出し順に依存しないよう、未解決なら先に deploy org を解決する
    resolve_deploy_org
    REGISTRY_REPO="${DEPLOY_ORG}/${REGISTRY_REPO_NAME}"
}

# 著者 README を記入できたか。fill_author_readme が設定し、
# print_author_readme_operation が読む。既定を false にしておくのは、記入の前に
# 一覧を出す経路ができたときに「記入した」と嘘をつかないため
AUTHOR_README_FILLED=false

# モード設定
INTERACTIVE_MODE=false
DRY_RUN_MODE=false
DEBUG_MODE=false
BATCH_CONFIRM_MODE=false

# フィルター設定
FILTER_TYPE=""
LIMIT_COUNT=""
# 特定Issue指定（Bug #495: トリガーIssueを確実に処理。未指定なら従来の pending スキャン）
TARGET_ISSUE_NUMBER=""

# ログ設定
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/process-pending-issues-$TIMESTAMP.log"
BACKUP_PATH="$BACKUP_DIR/$TIMESTAMP"

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# 統計変数
TOTAL_ISSUES=0
PROCESSED_COUNT=0
SKIPPED_COUNT=0
FAILED_COUNT=0
EXTRACTION_ERROR_COUNT=0
declare -a FAILED_ISSUES=()
declare -a EXTRACTION_ERROR_ISSUES=()

#
# ログ関数
#
log_raw() {
    echo "$1" | tee -a "$LOG_FILE"
}

log_info() {
    local msg="[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${BLUE}$msg${NC}" | tee -a "$LOG_FILE" >&2
}

log_warn() {
    local msg="[WARN] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${YELLOW}$msg${NC}" | tee -a "$LOG_FILE" >&2
}

log_error() {
    local msg="[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${RED}$msg${NC}" | tee -a "$LOG_FILE" >&2
}

log_success() {
    local msg="[SUCCESS] $(date '+%Y-%m-%d %H:%M:%S') $1"
    echo -e "${GREEN}$msg${NC}" | tee -a "$LOG_FILE" >&2
}

log_debug() {
    if [ "$DEBUG_MODE" = true ]; then
        local msg="[DEBUG] $(date '+%Y-%m-%d %H:%M:%S') $1"
        echo -e "${CYAN}$msg${NC}" | tee -a "$LOG_FILE" >&2
    fi
}

#
# ヘルプ表示
#
show_help() {
    cat <<EOF
未処理Issue一括処理スクリプト

Usage: $0 [options]

OPTIONS:
    -i, --interactive       インタラクティブモード
    -d, --dry-run          ドライランモード（変更なし）
    --debug                デバッグモード
    --batch-confirm        バッチ確認モード（インタラクティブ+一括確認）
    --type TYPE            処理対象タイプ指定 (wr|sotsuron|thesis)
    --limit NUM            最大処理数制限
    --issue NUM            特定Issue番号のみ処理（未指定時は従来通り未処理Issueを走査）
    --repo REPO            対象リポジトリ (default: $DEFAULT_REPO)
    --registry-repo REPO   レジストリリポジトリ (default: <org>/thesis-student-registry、
                           org は GITHUB_REPOSITORY_OWNER または --repo の owner 部分)
    --log-dir DIR          ログディレクトリ (default: $DEFAULT_LOG_DIR)
    --backup-dir DIR       バックアップディレクトリ (default: $DEFAULT_BACKUP_DIR)
    -h, --help             このヘルプを表示

EXAMPLES:
    # 自動モード
    $0

    # インタラクティブモード
    $0 --interactive

    # 特定タイプのみ処理
    $0 --type wr       # 週報リポジトリ
    $0 --type ise      # 情報科学演習レポート
    $0 --type latex    # 汎用LaTeXリポジトリ
    $0 --type thesis   # 論文リポジトリ

    # ドライラン
    $0 --dry-run

    # デバッグモード
    $0 --debug --dry-run
EOF
}

#
# オプション解析
#
parse_options() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -i|--interactive)
                INTERACTIVE_MODE=true
                shift
                ;;
            -d|--dry-run)
                DRY_RUN_MODE=true
                shift
                ;;
            --debug)
                DEBUG_MODE=true
                shift
                ;;
            --batch-confirm)
                BATCH_CONFIRM_MODE=true
                INTERACTIVE_MODE=true
                shift
                ;;
            --type)
                FILTER_TYPE="$2"
                if [[ ! "$FILTER_TYPE" =~ ^(wr|sotsuron|thesis|ise|latex|sotsuron-report)$ ]]; then
                    log_error "無効なタイプ: $FILTER_TYPE (有効: wr, sotsuron, thesis, ise, latex, sotsuron-report)"
                    exit 1
                fi
                shift 2
                ;;
            --limit)
                LIMIT_COUNT="$2"
                if ! [[ "$LIMIT_COUNT" =~ ^[0-9]+$ ]]; then
                    log_error "無効な制限数: $LIMIT_COUNT"
                    exit 1
                fi
                shift 2
                ;;
            --issue)
                TARGET_ISSUE_NUMBER="$2"
                if ! [[ "$TARGET_ISSUE_NUMBER" =~ ^[0-9]+$ ]]; then
                    log_error "無効なIssue番号: $TARGET_ISSUE_NUMBER"
                    exit 1
                fi
                shift 2
                ;;
            --repo)
                REPO="$2"
                shift 2
                ;;
            --registry-repo)
                REGISTRY_REPO="$2"
                shift 2
                ;;
            --log-dir)
                LOG_DIR="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            -h|--help)
                show_help
                exit 0
                ;;
            *)
                log_error "不明なオプション: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

#
# 前提条件チェック
#
check_prerequisites() {
    log_info "前提条件をチェック中..."

    # 必要なコマンドの確認
    local required_commands=("gh" "jq" "git")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "必要なコマンドが見つかりません: $cmd"
            return 1
        fi
        log_debug "✓ $cmd コマンド確認済み"
    done

    # GitHub CLI認証確認
    if ! gh auth status >/dev/null 2>&1; then
        log_error "GitHub CLI認証が必要です: gh auth login"
        return 1
    fi
    log_debug "✓ GitHub CLI認証確認済み"

    # ディレクトリ作成
    for dir in "$LOG_DIR" "$BACKUP_DIR"; do
        if [ ! -d "$dir" ]; then
            mkdir -p "$dir"
            log_debug "ディレクトリを作成: $dir"
        fi
    done

    # プロジェクトルートの確認（スクリプトディレクトリの存在確認に変更）
    if [ ! -d "$PROJECT_ROOT/scripts" ]; then
        log_error "プロジェクトルートが正しくありません: $PROJECT_ROOT"
        return 1
    fi

    log_success "前提条件チェック完了"
    return 0
}

#
# バックアップ作成
#
create_backup() {
    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "[DRY-RUN] バックアップ作成をスキップ"
        return 0
    fi

    log_info "データファイルをバックアップ中..."

    mkdir -p "$BACKUP_PATH"

    # データは thesis-student-registry で管理されるため、ローカルバックアップは不要
    log_debug "データ管理は thesis-student-registry に統合済み"

    log_success "バックアップ作成完了: $BACKUP_PATH"
    return 0
}

#
# thesis-student-registry の準備（GitHub API使用時は不要）
#
prepare_registry() {
    log_info "GitHub API経由で $REGISTRY_REPO を更新します"
    
    # GitHub APIアクセステスト（read 系 + リポジトリ push 権限の確認。
    # fine-grained PAT の Contents write スコープ欠落までは検出できない点に注意）
    if ! gh api "repos/$REGISTRY_REPO" >/dev/null 2>&1; then
        log_error "$REGISTRY_REPO へのアクセスに失敗しました"
        log_error "GitHub CLI認証またはリポジトリ権限を確認してください"
        return 1
    fi
    
    # 書き込み権限の具体的確認（registry.jsonファイルアクセステスト）
    if ! gh api "repos/$REGISTRY_REPO/contents/data/registry.json" >/dev/null 2>&1; then
        log_error "registry.jsonへのアクセスに失敗しました"
        log_error "ファイルの読み取り権限を確認してください"
        return 1
    fi
    
    # 書き込み権限の目安確認（参考情報。実際の write は下流の API 呼び出しで検証される）。
    # 注意: .permissions.push は collaborator（ユーザー）権限を表すフィールドで、
    # GitHub App の installation token では true を返さない（App は installation 権限で
    # 書き込むため）。したがって非 true を「権限なし」と断定できない。非 true は警告に留め、
    # 実書き込みの成否に判定を委ねる（失敗すれば下流でエラーになり run が赤くなる）。
    local push_permission
    if push_permission=$(gh api "repos/$REGISTRY_REPO" --jq '.permissions.push' 2>/dev/null); then
        if [ "$push_permission" != "true" ]; then
            log_warn "push 権限フラグが true ではありません（GitHub App トークンでは通常この表示になります）。実際の書き込み権限は下流の API 呼び出しで検証されます"
        fi
    else
        log_warn "権限レベルの確認に失敗しましたが、処理を続行します"
    fi
    
    log_success "レジストリ $REGISTRY_REPO のアクセス確認完了（read 確認済み。write は実書き込みで検証）"
    return 0
}

#
# Issue取得（リトライ機能付き）
#
fetch_pending_issues() {
    log_info "未処理Issueを検索中..."
    log_debug "対象リポジトリ: $REPO"
    
    # 特定Issue指定時は list 走査ではなく番号で直接取得する（Bug #495/#496）。
    # gh issue list は index の eventual consistency で開いた直後の Issue を
    # 取りこぼすことがあるため、強整合な gh issue view で対象を確実に取得する。
    if [ -n "$TARGET_ISSUE_NUMBER" ]; then
        log_debug "特定Issue直接取得: #$TARGET_ISSUE_NUMBER"
        local issue_json
        if ! issue_json=$(gh issue view "$TARGET_ISSUE_NUMBER" \
            --repo "$REPO" \
            --json number,title,body,createdAt,url,author 2>&1); then
            log_error "Issue #$TARGET_ISSUE_NUMBER の取得に失敗: $issue_json"
            return 1
        fi

        # 登録依頼/ブランチ保護設定依頼のタイトルに一致するもののみ処理対象。
        # gh issue view は単一オブジェクトを返すため、タイトルを取り出して判定し、
        # 後続処理が期待する配列形式へ jq '[.]' で包む。
        local title
        title=$(echo "$issue_json" | jq -r '.title')
        if ! echo "$title" | grep -qE 'リポジトリ登録依頼|ブランチ保護設定依頼'; then
            log_error "Issue #$TARGET_ISSUE_NUMBER は登録依頼Issueではありません（タイトル: $title）"
            return 1
        fi
        local target_json
        target_json=$(echo "$issue_json" | jq '[.]')
        echo "$target_json"
        return 0
    fi

    local issues_json
    local gh_error_output
    local retry_count=0
    local max_retries=3
    
    while [ $retry_count -lt $max_retries ]; do
        log_debug "Issue取得試行 $((retry_count + 1))/$max_retries"
        
        # GitHub CLI でサポートされているフィールドのみを使用（author情報も含める）
        if gh_error_output=$(gh issue list \
            --repo "$REPO" \
            --state open \
            --json number,title,body,createdAt,url,author \
            --limit 100 2>&1); then
            issues_json="$gh_error_output"
            log_debug "GitHub CLI コマンド実行成功"
            break
        else
            retry_count=$((retry_count + 1))
            log_warn "Issue取得試行 $retry_count 失敗: $gh_error_output"
            
            if [ $retry_count -lt $max_retries ]; then
                local wait_time=$((retry_count * 2))
                log_info "${wait_time}秒待機後に再試行します..."
                sleep $wait_time
            else
                log_error "Issue取得に失敗しました (全${max_retries}回の試行):"
                log_error "最終エラー: $gh_error_output"
                log_error "考えられる原因:"
                log_error "  - GitHub APIレート制限"
                log_error "  - ネットワーク接続問題"
                log_error "  - GitHub CLI認証期限切れ"
                log_error "  - リポジトリアクセス権限不足"
                return 1
            fi
        fi
    done
    
    # タイトルでフィルター
    log_debug "タイトルフィルターを適用中..."
    local all_issues_count=$(echo "$issues_json" | jq length)
    log_debug "取得したIssue総数: $all_issues_count"
    
    issues_json=$(echo "$issues_json" | jq '[.[] | select(.title | test("リポジトリ登録依頼|ブランチ保護設定依頼"))]')
    local filtered_count=$(echo "$issues_json" | jq length)
    log_debug "フィルター後のIssue数: $filtered_count"
    
    # フィルター適用
    if [ -n "$FILTER_TYPE" ]; then
        log_debug "タイプフィルター適用: $FILTER_TYPE"
        case "$FILTER_TYPE" in
            wr)
                issues_json=$(echo "$issues_json" | jq '[.[] | select(.title | contains("-wr"))]')
                ;;
            ise)
                issues_json=$(echo "$issues_json" | jq '[.[] | select(.title | contains("-ise-report"))]')
                ;;
            latex)
                issues_json=$(echo "$issues_json" | jq '[.[] | select(.title | contains("-latex"))]')
                ;;
            sotsuron)
                # -sotsuron-report を巻き込まないよう除外する（#559）
                issues_json=$(echo "$issues_json" | jq '[.[] | select((.title | contains("-sotsuron")) and (.title | contains("-sotsuron-report") | not))]')
                ;;
            thesis)
                issues_json=$(echo "$issues_json" | jq '[.[] | select(.title | contains("-thesis"))]')
                ;;
            sotsuron-report)
                issues_json=$(echo "$issues_json" | jq '[.[] | select(.title | contains("-sotsuron-report"))]')
                ;;
        esac
    fi
    
    # 制限数適用
    if [ -n "$LIMIT_COUNT" ]; then
        log_debug "制限数適用: $LIMIT_COUNT"
        issues_json=$(echo "$issues_json" | jq ".[0:$LIMIT_COUNT]")
        local final_count=$(echo "$issues_json" | jq length)
        log_debug "制限適用後のIssue数: $final_count"
    fi
    
    echo "$issues_json"
    return 0
}

#
# Issue情報抽出
#
extract_issue_info() {
    local issue_json="$1"
    
    # グローバル変数に設定（関数間でのデータ共有用）
    CURRENT_ISSUE_NUMBER=$(echo "$issue_json" | jq -r '.number')
    CURRENT_ISSUE_TITLE=$(echo "$issue_json" | jq -r '.title')
    CURRENT_ISSUE_BODY=$(echo "$issue_json" | jq -r '.body')
    CURRENT_ISSUE_URL=$(echo "$issue_json" | jq -r '.url')
    CURRENT_ISSUE_CREATED=$(echo "$issue_json" | jq -r '.createdAt')
    CURRENT_ISSUE_AUTHOR=$(echo "$issue_json" | jq -r '.author.login // "unknown"')
    
    # リポジトリ名抽出（org 非依存。<org>/<k##...-repo> 形式を title → body の順で探す）
    CURRENT_REPO_NAME=""
    CURRENT_ISSUE_ORG=""

    # org の直前が英数・ドット・ハイフンの場合は除外し、URL のドメイン断片
    # （example.com/k22... の "com" 等）を org として誤捕捉しない
    local org_repo_re='(^|[^A-Za-z0-9.-])([A-Za-z0-9][A-Za-z0-9-]*)/([k][0-9]{2}[a-z0-9]+-[a-zA-Z0-9_-]+)'

    # パターン1: タイトルの <org>/k##xxx-yyy 形式
    if [[ "$CURRENT_ISSUE_TITLE" =~ $org_repo_re ]]; then
        CURRENT_ISSUE_ORG="${BASH_REMATCH[2]}"
        CURRENT_REPO_NAME="${BASH_REMATCH[3]}"
    # パターン2: Issue本文から抽出
    elif [[ "$CURRENT_ISSUE_BODY" =~ $org_repo_re ]]; then
        CURRENT_ISSUE_ORG="${BASH_REMATCH[2]}"
        CURRENT_REPO_NAME="${BASH_REMATCH[3]}"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: 本文からリポジトリ名を抽出: $CURRENT_ISSUE_ORG/$CURRENT_REPO_NAME"
    # 旧パターン3（バックティック囲み）は org を持てず、自動生成 Issue では
    # 一度も emit されない死にパターンだったため削除（issue #475）
    else
        log_error "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名を抽出できませんでした"
        log_debug "タイトル: $CURRENT_ISSUE_TITLE"
        log_debug "本文（先頭200文字）: ${CURRENT_ISSUE_BODY:0:200}"
        return 2  # 情報抽出エラーとして区別
    fi

    # org 検証: パイプラインはデプロイ org 内のみを操作する
    # （Organization-Scoped Deployment。他 org を指す依頼は抽出エラー扱い）
    if [ "$CURRENT_ISSUE_ORG" != "$DEPLOY_ORG" ]; then
        log_error "Issue #${CURRENT_ISSUE_NUMBER}: org 不一致のため処理しません（依頼: $CURRENT_ISSUE_ORG, デプロイ: $DEPLOY_ORG）"
        return 2
    fi
    
    # 学生ID抽出（Issue本文とリポジトリ名の両方から試行）
    CURRENT_STUDENT_ID=""
    
    # パターン1: Issue本文から抽出
    if [[ "$CURRENT_ISSUE_BODY" =~ (k[0-9]{2}(rs|jk|gjk)[0-9]+) ]]; then
        CURRENT_STUDENT_ID="${BASH_REMATCH[1]}"
    # パターン2: リポジトリ名から抽出
    elif [[ "$CURRENT_REPO_NAME" =~ ^(k[0-9]{2}[a-z0-9]+)- ]]; then
        CURRENT_STUDENT_ID="${BASH_REMATCH[1]}"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名から学生IDを抽出: $CURRENT_STUDENT_ID"
    else
        log_error "Issue #${CURRENT_ISSUE_NUMBER}: 学生IDを抽出できませんでした"
        log_debug "Issue本文（先頭200文字）: ${CURRENT_ISSUE_BODY:0:200}"
        log_debug "リポジトリ名: $CURRENT_REPO_NAME"
        return 2  # 情報抽出エラーとして区別
    fi
    
    # リポジトリタイプ判定（優先順位: Issue本文 > リポジトリ名 > 学生IDパターン）
    CURRENT_REPO_TYPE=""
    
    # パターン1: Issue本文から直接抽出（最も信頼性が高い）
    # generate_issue_body の実出力は「**リポジトリタイプ**: <type>」で、ラベル直後に
    # Markdown の ** が挟まるため [*[:space:]]* で許容する（従来の [[:space:]]* のみでは
    # 一度もマッチせず、常に名前パターン以降のフォールバックへ落ちていた）
    # 文字クラスの - は必須: sotsuron-report のようなハイフン入りタイプを
    # 途中で切ると（例: sotsuron）、誤った保護適用・review_flow に波及する（#559）
    if [[ "$CURRENT_ISSUE_BODY" =~ リポジトリタイプ[*[:space:]]*:[[:space:]]*([a-zA-Z0-9-]+) ]]; then
        CURRENT_REPO_TYPE="${BASH_REMATCH[1]}"
        # 旧語彙・別表記を registry の正式語彙へ正規化（issue #471）。
        # poster は registry の正式語彙のためそのまま登録する
        case "$CURRENT_REPO_TYPE" in
            shuuron|thesis) CURRENT_REPO_TYPE="master" ;;
        esac
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: Issue本文から直接タイプを抽出: $CURRENT_REPO_TYPE"
    # パターン2: Issue本文のキーワードから判定
    elif [[ "$CURRENT_ISSUE_BODY" =~ 週報|weekly ]]; then
        CURRENT_REPO_TYPE="wr"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: Issue本文キーワードから週報タイプを判定"
    elif [[ "$CURRENT_ISSUE_BODY" =~ 情報科学演習|ise.report ]]; then
        CURRENT_REPO_TYPE="ise"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: Issue本文キーワードからISEタイプを判定"
    elif [[ "$CURRENT_ISSUE_BODY" =~ 汎用LaTeX|latex.template ]]; then
        CURRENT_REPO_TYPE="latex"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: Issue本文キーワードからlatexタイプを判定"
    elif [[ "$CURRENT_ISSUE_BODY" =~ 卒業論文|undergraduate|sotsuron ]]; then
        CURRENT_REPO_TYPE="sotsuron"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: Issue本文キーワードから卒論タイプを判定"
    elif [[ "$CURRENT_ISSUE_BODY" =~ 修士論文|修論|graduate|thesis ]]; then
        # 英語 thesis も修論キーワードとして受理（type としては master を書く）。
        # 単語 master は「masterブランチ」等で頻出のためキーワードにしない
        CURRENT_REPO_TYPE="master"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: Issue本文キーワードから修論タイプを判定"
    # パターン3: リポジトリ名から判定（フォールバック）
    elif [[ "$CURRENT_REPO_NAME" == *"-wr" ]]; then
        CURRENT_REPO_TYPE="wr"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名から週報タイプを判定"
    elif [[ "$CURRENT_REPO_NAME" == *"-ise-report"* ]]; then
        CURRENT_REPO_TYPE="ise"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名からISEタイプを判定"
    elif [[ "$CURRENT_REPO_NAME" == *"-sotsuron" ]]; then
        CURRENT_REPO_TYPE="sotsuron"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名から卒論タイプを判定"
    elif [[ "$CURRENT_REPO_NAME" == *"-master" || "$CURRENT_REPO_NAME" == *"-thesis" ]]; then
        # 修論 repo の実命名は *-master（*-thesis は防御的別名）。repository_type は
        # master（issue #471: thesis は type の語彙ではない）
        CURRENT_REPO_TYPE="master"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名から修論タイプを判定"
    elif [[ "$CURRENT_REPO_NAME" == *"-latex" ]]; then
        CURRENT_REPO_TYPE="latex"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリ名からlatexタイプを判定"
    # 旧パターン4（学生 ID からの推測 rs→sotsuron / gjk→thesis）は誤分類の
    # 主因だったため廃止（issue #471）。卒論・修論は命名規約 *-sotsuron /
    # *-master（防御的別名 *-thesis）で必ずパターン3までに判定される
    # パターン5: 明示的なタイプ情報がない未知パターンは other として登録する
    # （registry-manager の推論 fallback と同一。latex / poster は Issue 本文の
    # 明示指定でのみ判定し、名前からの推測はしない）
    elif [[ "$CURRENT_REPO_NAME" =~ -[a-zA-Z0-9_-]+$ && ! "$CURRENT_REPO_NAME" == *"-latex" ]]; then
        CURRENT_REPO_TYPE="other"
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: 未知パターンを other として登録: $CURRENT_REPO_NAME"
    else
        CURRENT_REPO_TYPE="unknown"
        log_error "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリタイプを判定できませんでした"
        log_debug "リポジトリ名: $CURRENT_REPO_NAME"
        log_debug "学生ID: $CURRENT_STUDENT_ID"
        log_debug "Issue本文（先頭100文字）: ${CURRENT_ISSUE_BODY:0:100}"
        return 2  # 情報抽出エラーとして区別
    fi
    
    # レビューフロー有無の抽出（latex の作成時オプトイン REVIEW_FLOW。有効時のみ
    # generate_issue_body が「**レビューフロー**: on」を記録する。他タイプはタイプ
    # 自体で要否が決まるためこのフラグは latex 以外では常に false のまま）
    CURRENT_REVIEW_FLOW=false
    if [[ "$CURRENT_ISSUE_BODY" =~ レビューフロー[*[:space:]]*:[[:space:]]*on ]]; then
        CURRENT_REVIEW_FLOW=true
        log_debug "Issue #${CURRENT_ISSUE_NUMBER}: レビューフロー有効を検出"
    fi

    log_debug "Issue #${CURRENT_ISSUE_NUMBER}: $CURRENT_REPO_NAME ($CURRENT_REPO_TYPE) - $CURRENT_STUDENT_ID"
    return 0
}

#
# リポジトリ存在確認
#
check_repository_exists() {
    local repo_name="$1"
    
    if gh repo view "${DEPLOY_ORG}/$repo_name" >/dev/null 2>&1; then
        log_debug "リポジトリ存在確認: ${DEPLOY_ORG}/$repo_name ✓"
        return 0
    else
        log_debug "リポジトリ存在確認: ${DEPLOY_ORG}/$repo_name ✗"
        return 1
    fi
}

#
# ブランチ保護状態確認
#
check_branch_protection() {
    local repo_name="$1"
    
    if gh api "repos/${DEPLOY_ORG}/$repo_name/branches/main/protection" >/dev/null 2>&1; then
        log_debug "ブランチ保護確認: ${DEPLOY_ORG}/$repo_name ✓"
        return 0
    else
        log_debug "ブランチ保護確認: ${DEPLOY_ORG}/$repo_name ✗"
        return 1
    fi
}

#
# Issue処理メイン
#
fetch_and_process_issues() {
    # Issue取得
    local issues_json
    if ! issues_json=$(fetch_pending_issues); then
        log_error "fetch_pending_issues が失敗しました"
        return 1
    fi
    
    log_debug "取得したJSON: ${issues_json:0:100}..."
    
    # Issue数の確認（空の場合を考慮）
    local issue_count_check
    issue_count_check=$(echo "$issues_json" | jq length 2>/dev/null || echo "0")
    
    log_debug "Issue数チェック結果: '$issue_count_check'"
    
    if [ -z "$issue_count_check" ] || [ "$issue_count_check" = "null" ]; then
        TOTAL_ISSUES=0
    else
        TOTAL_ISSUES="$issue_count_check"
    fi
    
    log_debug "最終的なTOTAL_ISSUES: $TOTAL_ISSUES"
    
    if [ "$TOTAL_ISSUES" -eq 0 ]; then
        log_info "未処理のIssueは見つかりませんでした"
        return 0
    fi
    
    log_info "見つかったIssue: ${TOTAL_ISSUES}件"
    
    if [ "$INTERACTIVE_MODE" = true ]; then
        process_issues_interactive "$issues_json"
    else
        process_issues_automatic "$issues_json"
    fi
    
    return $?
}

#
# 自動処理モード
#
process_issues_automatic() {
    local issues_json="$1"
    
    log_info "自動処理モードで実行中..."
    
    for i in $(seq 0 $((TOTAL_ISSUES - 1))); do
        local issue=$(echo "$issues_json" | jq ".[$i]")
        
        # 注意: `if ! f; then rc=$?` では rc が negation 後の 0 になるため、
        # 戻り値は if の外で捕捉する（issue #473 レビューで発覚した既存バグ）
        extract_issue_info "$issue"
        local extract_exit_code=$?

        if [ "$extract_exit_code" -ne 0 ]; then
            if [ "$extract_exit_code" = "2" ]; then
                log_warn "Issue #${CURRENT_ISSUE_NUMBER}: 情報抽出エラー、エラーカウントに追加"
                ((EXTRACTION_ERROR_COUNT++))
                EXTRACTION_ERROR_ISSUES+=("$CURRENT_ISSUE_NUMBER")
                comment_processing_failure "$CURRENT_ISSUE_NUMBER" "Issue から情報を抽出できませんでした"
            else
                log_warn "Issue #${CURRENT_ISSUE_NUMBER}: 一般的な抽出失敗、スキップします"
                ((SKIPPED_COUNT++))
            fi
            continue
        fi
        
        log_info "処理中 ($((i + 1))/$TOTAL_ISSUES): Issue #${CURRENT_ISSUE_NUMBER} - $CURRENT_REPO_NAME"
        
        if ! check_repository_exists "$CURRENT_REPO_NAME"; then
            # 見つからない repo は放置すると green のまま滞留するため失敗として扱う（issue #473）
            log_error "Issue #${CURRENT_ISSUE_NUMBER}: リポジトリが見つかりません: $CURRENT_REPO_NAME"
            add_issue_comment "$CURRENT_ISSUE_NUMBER" "⚠️ リポジトリが見つかりません: ${DEPLOY_ORG}/$CURRENT_REPO_NAME"
            ((FAILED_COUNT++))
            FAILED_ISSUES+=("$CURRENT_ISSUE_NUMBER")
            continue
        fi
        
        if process_single_issue; then
            ((PROCESSED_COUNT++))
            log_success "Issue #${CURRENT_ISSUE_NUMBER}: 処理完了"
        else
            ((FAILED_COUNT++))
            FAILED_ISSUES+=("$CURRENT_ISSUE_NUMBER")
            log_error "Issue #${CURRENT_ISSUE_NUMBER}: 処理失敗"
            comment_processing_failure "$CURRENT_ISSUE_NUMBER" "ブランチ保護またはレジストリ登録の処理でエラー"
        fi
    done
    
    return 0
}

#
# インタラクティブ処理モード
#
process_issues_interactive() {
    local issues_json="$1"
    
    echo
    echo "=== インタラクティブモード ==="
    echo
    
    if [ "$BATCH_CONFIRM_MODE" = true ]; then
        show_batch_confirm_summary "$issues_json"
        return $?
    fi
    
    # 各Issueを順番に処理
    for i in $(seq 0 $((TOTAL_ISSUES - 1))); do
        local issue=$(echo "$issues_json" | jq ".[$i]")
        
        extract_issue_info "$issue"
        local extract_exit_code=$?

        if [ "$extract_exit_code" -ne 0 ]; then
            if [ "$extract_exit_code" = "2" ]; then
                log_warn "Issue #${CURRENT_ISSUE_NUMBER}: 情報抽出エラー、エラーカウントに追加"
                ((EXTRACTION_ERROR_COUNT++))
                EXTRACTION_ERROR_ISSUES+=("$CURRENT_ISSUE_NUMBER")
                comment_processing_failure "$CURRENT_ISSUE_NUMBER" "Issue から情報を抽出できませんでした"
            else
                log_warn "Issue #${CURRENT_ISSUE_NUMBER}: 一般的な抽出失敗、スキップします"
                ((SKIPPED_COUNT++))
            fi
            continue
        fi
        
        process_issue_interactive $((i + 1))
        local result=$?
        
        case $result in
            0) # 処理成功
                ((PROCESSED_COUNT++))
                ;;
            1) # 処理失敗
                ((FAILED_COUNT++))
                FAILED_ISSUES+=("$CURRENT_ISSUE_NUMBER")
                comment_processing_failure "$CURRENT_ISSUE_NUMBER" "ブランチ保護またはレジストリ登録の処理でエラー"
                ;;
            2) # ユーザーが終了を選択
                log_info "ユーザーによる処理終了"
                break
                ;;
            3) # スキップ
                ((SKIPPED_COUNT++))
                ;;
        esac
    done
    
    show_interactive_summary
    return 0
}

#
# バッチ確認モード
#
show_batch_confirm_summary() {
    local issues_json="$1"
    
    echo "以下の${TOTAL_ISSUES}件のIssueが見つかりました:"
    echo
    
    for i in $(seq 0 $((TOTAL_ISSUES - 1))); do
        local issue=$(echo "$issues_json" | jq ".[$i]")
        
        if extract_issue_info "$issue"; then
            echo "  $((i + 1)). Issue #${CURRENT_ISSUE_NUMBER}: $CURRENT_REPO_NAME ($CURRENT_REPO_TYPE)"
            
            if ! check_repository_exists "$CURRENT_REPO_NAME"; then
                echo "     ⚠️  リポジトリが見つかりません"
            else
                echo "     ✅ リポジトリ確認済み"
                if [ "$CURRENT_REPO_TYPE" != "wr" ]; then
                    if check_branch_protection "$CURRENT_REPO_NAME"; then
                        echo "     🔒 ブランチ保護設定済み"
                    else
                        echo "     🔓 ブランチ保護未設定"
                    fi
                fi
            fi
        else
            echo "  $((i + 1)). Issue #${CURRENT_ISSUE_NUMBER}: 情報抽出失敗"
        fi
        echo
    done
    
    echo -n "全てのIssueを処理しますか? [y/N]: "
    read -r batch_confirm
    
    if [[ "$batch_confirm" =~ ^[Yy]$ ]]; then
        log_info "バッチ処理を開始します..."
        process_issues_automatic "$issues_json"
        return $?
    else
        log_info "処理をキャンセルしました"
        return 0
    fi
}

#
# 個別Issue処理（インタラクティブ）
#
process_issue_interactive() {
    local current="$1"
    
    while true; do
        clear
        show_issue_summary "$current"
        
        echo "  処理方法を選択してください:"
        echo "  [p] 処理実行   [c] Issueクローズ   [d] Issue削除   [D] リポジトリ削除   [s] スキップ   [v] 詳細表示   [q] 終了"
        echo -n "  選択: "
        read -r choice
        
        case "$choice" in
            p|P)
                echo
                execute_issue_processing
                return $?
                ;;
            c|C)
                echo
                execute_issue_close_only
                return $?
                ;;
            d)
                echo
                execute_issue_delete
                return $?
                ;;
            D)
                echo
                execute_repository_delete
                return $?
                ;;
            s|S)
                echo
                log_info "Issue #${CURRENT_ISSUE_NUMBER} をスキップしました"
                echo "続行するには Enter を押してください..."
                read -r
                return 3  # スキップシグナル
                ;;
            v|V)
                show_issue_details
                echo
                echo "処理方法を選択してください:"
                echo "[p] 処理実行   [c] Issueクローズ   [d] Issue削除   [D] リポジトリ削除   [s] スキップ   [b] 戻る   [q] 終了"
                echo -n "選択: "
                read -r detail_choice
                
                case "$detail_choice" in
                    p|P)
                        echo
                        execute_issue_processing
                        return $?
                        ;;
                    c|C)
                        echo
                        execute_issue_close_only
                        return $?
                        ;;
                    d)
                        echo
                        execute_issue_delete
                        return $?
                        ;;
                    D)
                        echo
                        execute_repository_delete
                        return $?
                        ;;
                    s|S)
                        echo
                        log_info "Issue #${CURRENT_ISSUE_NUMBER} をスキップしました"
                        echo "続行するには Enter を押してください..."
                        read -r
                        return 3  # スキップシグナル
                        ;;
                    b|B)
                        continue
                        ;;
                    q|Q)
                        return 2  # 終了シグナル
                        ;;
                    *)
                        echo "無効な選択です。"
                        sleep 1
                        continue
                        ;;
                esac
                ;;
            q|Q)
                return 2  # 終了シグナル
                ;;
            *)
                echo "無効な選択です。再度選択してください。"
                sleep 1
                continue
                ;;
        esac
    done
}

#
# Issue情報表示
#
show_issue_summary() {
    local current="$1"
    
    echo "Issue #${CURRENT_ISSUE_NUMBER} (${current}/${TOTAL_ISSUES}): ${CURRENT_ISSUE_TITLE}"
    echo
    
    # リポジトリタイプ表示
    case "$CURRENT_REPO_TYPE" in
        wr)
            echo "  種別: 週報リポジトリ"
            ;;
        ise)
            echo "  種別: 情報科学演習レポート"
            ;;
        latex)
            echo "  種別: 汎用LaTeXリポジトリ"
            ;;
        sotsuron)
            echo "  種別: 論文リポジトリ（卒業論文）"
            ;;
        master)
            echo "  種別: 論文リポジトリ（修士論文）"
            ;;
        poster)
            echo "  種別: 学会ポスターリポジトリ"
            ;;
        sotsuron-report)
            echo "  種別: 卒業論文調査報告リポジトリ"
            ;;
        *)
            echo "  種別: 不明 (${CURRENT_REPO_TYPE})"
            ;;
    esac
    
    echo "  発行者: ${CURRENT_ISSUE_AUTHOR:-'不明'}"
    echo "  学生ID: ${CURRENT_STUDENT_ID:-'不明'}"
    echo "  リポジトリ: ${DEPLOY_ORG}/${CURRENT_REPO_NAME}"
    
    # リポジトリ存在確認
    if check_repository_exists "$CURRENT_REPO_NAME"; then
        echo "  リポジトリ状態: ✅ 存在確認済み"
        
        # ブランチ保護状態確認（論文リポジトリのみ）
        if [ "$CURRENT_REPO_TYPE" != "wr" ]; then
            if check_branch_protection "$CURRENT_REPO_NAME"; then
                echo "  ブランチ保護状態: ✅ 設定済み"
            else
                echo "  ブランチ保護状態: ❌ 未設定"
            fi
        fi
    else
        echo "  リポジトリ状態: ❌ 見つかりません"
    fi
    
    echo
}

#
# Issue詳細情報表示
#
show_issue_details() {
    clear
    echo "=== Issue #${CURRENT_ISSUE_NUMBER} 詳細情報 ==="
    echo
    echo "タイトル: $CURRENT_ISSUE_TITLE"
    echo "URL: $CURRENT_ISSUE_URL"
    echo "作成日: $(echo "$CURRENT_ISSUE_CREATED" | sed 's/T/ /' | sed 's/Z/ UTC/')"
    echo
    echo "本文:"
    echo "$CURRENT_ISSUE_BODY" | head -20 | sed 's/^/  /'
    if [ $(echo "$CURRENT_ISSUE_BODY" | wc -l) -gt 20 ]; then
        echo "  ... (省略)"
    fi
    echo
    
    echo "実行される処理:"
    case "$CURRENT_REPO_TYPE" in
        wr)
            echo "  1. thesis-student-registry への登録"
            echo "  2. Issue クローズ"
            ;;
        latex)
            if [ "$CURRENT_REVIEW_FLOW" = true ]; then
                echo "  1. ブランチ保護設定 (main)（レビューフロー有効）"
                echo "  2. thesis-student-registry への登録"
                echo "  3. Issue クローズ"
            else
                echo "  1. thesis-student-registry への登録"
                echo "  2. Issue クローズ"
            fi
            ;;
        ise|sotsuron|master|poster)
            echo "  1. ブランチ保護設定 (main)"
            echo "  2. thesis-student-registry への登録"
            echo "  3. Issue クローズ"
            ;;
        *)
            echo "  1. thesis-student-registry への登録"
            echo "  2. Issue クローズ"
            ;;
    esac
    echo
}

#
# 処理実行とフィードバック
#
execute_issue_processing() {
    echo "処理を実行中..."
    echo
    
    # リポジトリ存在確認
    if ! check_repository_exists "$CURRENT_REPO_NAME"; then
        echo "❌ リポジトリが見つかりません: ${DEPLOY_ORG}/$CURRENT_REPO_NAME"
        add_issue_comment "$CURRENT_ISSUE_NUMBER" "⚠️ リポジトリが見つかりません: ${DEPLOY_ORG}/$CURRENT_REPO_NAME"
        echo
        echo "続行するには Enter を押してください..."
        read -r
        return 3  # スキップとして扱う
    fi
    
    case "$CURRENT_REPO_TYPE" in
        wr)
            echo "→ 週報リポジトリの登録処理を実行中..."
            if process_weekly_report_with_feedback; then
                echo "✅ 処理が完了しました"
            else
                echo "❌ 処理に失敗しました"
                echo
                echo "続行するには Enter を押してください..."
                read -r
                return 1
            fi
            ;;
        ise)
            echo "→ 情報科学演習レポートの処理を実行中..."
            if process_ise_with_feedback; then
                echo "✅ 処理が完了しました"
            else
                echo "❌ 処理に失敗しました"
                echo
                echo "続行するには Enter を押してください..."
                read -r
                return 1
            fi
            ;;
        latex|other)
            # other は「ブランチ保護なしで登録のみ」という処理内容が latex
            # （レビューフロー無効時）と同一のため、latex 経路を共用する
            echo "→ 汎用LaTeX/その他リポジトリの登録処理を実行中..."
            if run_latex_with_feedback; then
                echo "✅ 処理が完了しました"
            else
                echo "❌ 処理に失敗しました"
                echo
                echo "続行するには Enter を押してください..."
                read -r
                return 1
            fi
            ;;
        sotsuron|master)
            echo "→ 論文リポジトリの処理を実行中..."
            if process_thesis_with_feedback; then
                echo "✅ 処理が完了しました"
            else
                echo "❌ 処理に失敗しました"
                echo
                echo "続行するには Enter を押してください..."
                read -r
                return 1
            fi
            ;;
        poster)
            echo "→ 学会ポスターリポジトリの処理を実行中..."
            if process_poster_with_feedback; then
                echo "✅ 処理が完了しました"
            else
                echo "❌ 処理に失敗しました"
                echo
                echo "続行するには Enter を押してください..."
                read -r
                return 1
            fi
            ;;
        *)
            echo "→ 不明なリポジトリタイプの処理 ($CURRENT_REPO_TYPE)..."
            echo "❌ サポートされていないリポジトリタイプです"
            echo
            echo "続行するには Enter を押してください..."
            read -r
            return 1
            ;;
    esac
    
    echo
    echo -n "続行しますか? [Enter] で次へ、[q] で終了: "
    read -r continue_choice
    if [ "$continue_choice" = "q" ] || [ "$continue_choice" = "Q" ]; then
        return 2  # 終了シグナル
    fi
    
    return 0
}

#
# Issueクローズのみ実行
#
execute_issue_close_only() {
    echo "Issueをクローズ中..."
    echo
    
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ Issue手動クローズ

Issue #${CURRENT_ISSUE_NUMBER} を手動でクローズしました。
リポジトリ登録やブランチ保護設定は実行されていません。

必要に応じて個別に処理を実行してください。"; then
        echo "✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "❌ Issue クローズに失敗しました"
        echo
        echo "続行するには Enter を押してください..."
        read -r
        return 1
    fi
    
    echo
    echo -n "続行しますか? [Enter] で次へ、[q] で終了: "
    read -r continue_choice
    if [ "$continue_choice" = "q" ] || [ "$continue_choice" = "Q" ]; then
        return 2  # 終了シグナル
    fi
    
    return 0
}

#
# Issue削除実行
#
execute_issue_delete() {
    echo "⚠️  警告: Issue削除は取り消しできません"
    echo
    echo "削除対象Issueの詳細情報:"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Issue番号: #${CURRENT_ISSUE_NUMBER}"
    echo "  タイトル: ${CURRENT_ISSUE_TITLE}"
    echo "  作成者: ${CURRENT_ISSUE_AUTHOR}"
    echo "  作成日時: $(echo "$CURRENT_ISSUE_CREATED" | sed 's/T/ /' | sed 's/Z/ UTC/')"
    echo "  URL: ${CURRENT_ISSUE_URL}"
    echo
    echo "  関連リポジトリ: ${DEPLOY_ORG}/${CURRENT_REPO_NAME}"
    echo "  リポジトリタイプ: ${CURRENT_REPO_TYPE}"
    echo "  学生ID: ${CURRENT_STUDENT_ID}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo
    echo -n "本当に削除しますか? [yes/NO]: "
    read -r confirm_delete
    
    if [ "$confirm_delete" = "yes" ]; then
        echo "Issue削除中..."
        echo
        
        # GitHub CLIでIssue削除（要管理者権限）
        if gh issue delete "$CURRENT_ISSUE_NUMBER" --repo "$REPO" --confirm >/dev/null 2>&1; then
            echo "✅ Issue #${CURRENT_ISSUE_NUMBER} を削除しました"
        else
            echo "❌ Issue削除に失敗しました"
            echo "  削除には管理者権限が必要です"
            echo
            echo "続行するには Enter を押してください..."
            read -r
            return 1
        fi
    else
        echo "Issue削除をキャンセルしました"
    fi
    
    echo
    echo -n "続行しますか? [Enter] で次へ、[q] で終了: "
    read -r continue_choice
    if [ "$continue_choice" = "q" ] || [ "$continue_choice" = "Q" ]; then
        return 2  # 終了シグナル
    fi
    
    return 0
}

#
# リポジトリ削除実行
#
execute_repository_delete() {
    echo "🚨 危険: リポジトリ完全削除"
    echo "⚠️  この操作は取り消しできません"
    echo
    echo "削除対象リポジトリ: ${DEPLOY_ORG}/${CURRENT_REPO_NAME}"
    echo "Issue: #${CURRENT_ISSUE_NUMBER} - ${CURRENT_ISSUE_TITLE}"
    echo "発行者: ${CURRENT_ISSUE_AUTHOR}"
    echo
    
    # リポジトリ情報の詳細確認
    echo "リポジトリの詳細情報を確認中..."
    if gh --no-pager repo view "${DEPLOY_ORG}/$CURRENT_REPO_NAME" --json name,description,createdAt,isPrivate --jq '{name: .name, description: .description, created: .createdAt, private: .isPrivate}' 2>/dev/null; then
        echo
    else
        echo "❌ リポジトリ情報の取得に失敗しました"
    fi
    
    echo "🔴 リポジトリを削除すると以下の内容が失われます:"
    echo "  • すべてのコード履歴"
    echo "  • Issues、Pull Requests"
    echo "  • Wiki、Releases"
    echo "  • すべての設定とコラボレーター"
    echo
    
    # 最初の確認：テスト用リポジトリかどうか
    echo -n "これはテスト用リポジトリですか? [yes/NO]: "
    read -r is_test_repo
    
    if [ "$is_test_repo" = "yes" ]; then
        # 二重確認：リポジトリ名の入力
        echo
        echo "⚠️  最終確認: リポジトリを完全に削除します"
        echo "確認のため、リポジトリ名を正確に入力してください"
        echo -n "リポジトリ名 '${CURRENT_REPO_NAME}' を入力: "
        read -r confirm_repo_name
        
        # 空文字チェック
        if [ -z "$confirm_repo_name" ]; then
            echo "❌ リポジトリ名が入力されていません。削除をキャンセルしました"
            echo
            echo "続行するには Enter を押してください..."
            read -r
            return 0
        fi
        
        # リポジトリ名一致チェック
        if [ "$confirm_repo_name" != "$CURRENT_REPO_NAME" ]; then
            echo "❌ リポジトリ名が一致しません。削除をキャンセルしました"
            echo
            echo "続行するには Enter を押してください..."
            read -r
            return 0
        fi
        
        echo
        echo "リポジトリ削除中..."
        echo
        
        # GitHub CLIでリポジトリ削除（要管理者権限）
        if gh repo delete "${DEPLOY_ORG}/$CURRENT_REPO_NAME" --confirm >/dev/null 2>&1; then
            echo "✅ リポジトリ ${DEPLOY_ORG}/${CURRENT_REPO_NAME} を削除しました"
            
            # Issueも自動的にクローズ
            echo "📝 関連Issueをクローズ中..."
            if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ テストリポジトリ削除完了

リポジトリ **${DEPLOY_ORG}/${CURRENT_REPO_NAME}** を削除しました。

## 削除内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **削除日時**: $(date '+%Y-%m-%d %H:%M:%S JST')
- **操作者**: 管理者による手動削除

テスト用リポジトリの削除が完了しました。"; then
                echo "✅ Issue #${CURRENT_ISSUE_NUMBER} もクローズしました"
            else
                echo "⚠️  Issue クローズに失敗しましたが、リポジトリ削除は完了しています"
            fi
        else
            echo "❌ リポジトリ削除に失敗しました"
            echo "  考えられる原因:"
            echo "  - 管理者権限が不足"
            echo "  - リポジトリが既に削除されている"
            echo "  - ネットワーク接続問題"
            echo
            echo "続行するには Enter を押してください..."
            read -r
            return 1
        fi
    else
        echo "❌ テスト用リポジトリ以外の削除はキャンセルされました"
        echo
        echo "続行するには Enter を押してください..."
        read -r
        return 0
    fi
    
    echo
    echo -n "続行しますか? [Enter] で次へ、[q] で終了: "
    read -r continue_choice
    if [ "$continue_choice" = "q" ] || [ "$continue_choice" = "Q" ]; then
        return 2  # 終了シグナル
    fi
    
    return 0
}

#
# 著者 README の記入
#
# テンプレートの README.md は著者情報をプレースホルダで持つ。学生に書かせると
# draft サイクルのリポジトリでは main に届かないため（smkwlab/latex-ecosystem#191）、
# 作成直後のここで埋める。
#
# **ブランチ保護を掛ける前に呼ぶこと。** 保護後に main へ書くには、#577 が
# 「Actions がバイパスする必要は無い」として消したレビュー要件のバイパスを
# 復活させる必要がある。保護前なら、その概念自体が登場しない。
#
# 失敗しても処理は続け、警告だけ出す。著者情報が入らないのは README の見た目の
# 問題で、ブランチ保護とレジストリ登録のほうが重い。入らなかったリポジトリは
# 後から scripts/sync-author-readme.sh で埋められる。
#
fill_author_readme() {
    local script="$SCRIPT_DIR/fill-author-readme.sh"
    local ok=true

    echo "  README.md に著者情報を記入中..."
    # --dry-run の有無で呼び分ける。配列で引数を組むと、空のときの展開が
    # bash のバージョンで揺れる
    if [ "$DRY_RUN_MODE" = true ]; then
        REPO_OWNER="$DEPLOY_ORG" "$script" --dry-run "$CURRENT_REPO_NAME" || ok=false
    else
        REPO_OWNER="$DEPLOY_ORG" "$script" "$CURRENT_REPO_NAME" || ok=false
    fi

    if [ "$ok" = true ]; then
        echo "  ✅ 著者情報の記入完了"
        AUTHOR_README_FILLED=true
    else
        echo "  ⚠️  著者情報を記入できませんでした"
        echo "     後から ./scripts/sync-author-readme.sh ${CURRENT_REPO_NAME} で埋められます"
        AUTHOR_README_FILLED=false
    fi
}

#
# 「実行された操作」の一覧に出す行。
#
# 記入は失敗しても処理を止めないので、成功した体で一覧に並べると、ログを
# 遡らないと埋まっていないことに気付けない。
#
print_author_readme_operation() {
    if [ "$AUTHOR_README_FILLED" = true ]; then
        echo "  • README.md への著者情報の記入"
    else
        echo "  • README.md への著者情報の記入（失敗・後追いが必要）"
    fi
}

#
# 週報リポジトリ処理（詳細フィードバック付き）
#
process_weekly_report_with_feedback() {
    echo "  📝 週報リポジトリの処理を開始..."
    
    # 1. 著者 README の記入
    fill_author_readme
    
    # 2. thesis-student-registry 更新
    echo "  thesis-student-registry への登録中..."
    if update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "wr"; then
        echo "  ✅ thesis-student-registry への登録完了"
    else
        echo "  ❌ thesis-student-registry への登録失敗"
        return 1
    fi
    
    
    # 3. Issue クローズ
    echo "  Issue クローズ中..."
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 週報リポジトリの登録が完了しました

## 登録内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **登録日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

週報リポジトリは登録のみで管理されます。ブランチ保護設定は不要です。"; then
        echo "  ✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "  ❌ Issue クローズに失敗しました"
        return 1
    fi
    
    return 0
}

#
# 論文リポジトリ処理（詳細フィードバック付き）
#
process_thesis_with_feedback() {
    echo "  📚 論文リポジトリの処理を開始..."
    echo ""
    
    # 1. 著者 README の記入
    fill_author_readme
    
    # 2. ブランチ保護設定
    echo "  ブランチ保護設定を適用中..."
    if REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        echo "  ✅ ブランチ保護設定完了"
    else
        echo "  ❌ ブランチ保護設定失敗"
        return 1
    fi
    
    # 3. thesis-student-registry 更新
    echo "  thesis-student-registry への登録中..."
    if update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        echo "  ✅ thesis-student-registry への登録完了"
    else
        echo "  ❌ thesis-student-registry への登録失敗"
        return 1
    fi
    
    # 4. Issue クローズ
    echo "  Issue クローズ中..."
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 論文リポジトリの設定が完了しました

## 設定内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## 確認
リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches"; then
        echo "  ✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "  ❌ Issue クローズに失敗しました"
        return 1
    fi
    
    echo ""
    echo "📋 実行された操作:"
    print_author_readme_operation
    echo "  • ブランチ保護設定 (main)"
    echo "  • thesis-student-registry への登録"
    echo "  • Issue #$CURRENT_ISSUE_NUMBER のクローズ"
    echo ""
    
    return 0
}

#
# 情報科学演習レポート処理（詳細フィードバック付き）
#
process_ise_with_feedback() {
    echo "  📝 情報科学演習レポートの処理を開始..."
    echo ""
    
    # 1. 著者 README の記入
    fill_author_readme
    
    # 2. ブランチ保護設定（PR学習目的）
    echo "  ブランチ保護設定を適用中..."
    if REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        echo "  ✅ ブランチ保護設定完了"
    else
        echo "  ❌ ブランチ保護設定失敗"
        return 1
    fi
    
    # 3. thesis-student-registry 更新
    echo "  thesis-student-registry への登録中..."
    if update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        echo "  ✅ thesis-student-registry への登録完了"
    else
        echo "  ❌ thesis-student-registry への登録失敗"
        return 1
    fi
    
    # 4. Issue クローズ
    echo "  Issue クローズ中..."
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 情報科学演習レポートの設定が完了しました

## 設定内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要（PR学習目的）
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## Pull Request学習について
1. 作業用ブランチ（1st-draft など）を作成
2. index.html を編集してレポート作成
3. Pull Request を作成して提出
4. レビューフィードバックを確認・対応

リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches"; then
        echo "  ✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "  ❌ Issue クローズに失敗しました"
        return 1
    fi
    
    echo ""
    echo "📋 実行された操作:"
    print_author_readme_operation
    echo "  • ブランチ保護設定 (main)"
    echo "  • thesis-student-registry への登録"
    echo "  • Issue #$CURRENT_ISSUE_NUMBER のクローズ"
    echo ""
    
    return 0
}

#
# 学会ポスターリポジトリ処理（詳細フィードバック付き）
#
# draft PR サイクル（poster-template）を使うためブランチ保護を設定する。
#
process_poster_with_feedback() {
    echo "  📊 学会ポスターリポジトリの処理を開始..."
    echo ""

    # 1. 著者 README の記入
    fill_author_readme

    # 2. ブランチ保護設定（draft PR レビュー用）
    echo "  ブランチ保護設定を適用中..."
    if REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        echo "  ✅ ブランチ保護設定完了"
    else
        echo "  ❌ ブランチ保護設定失敗"
        return 1
    fi

    # 3. thesis-student-registry 更新
    echo "  thesis-student-registry への登録中..."
    if update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        echo "  ✅ thesis-student-registry への登録完了"
    else
        echo "  ❌ thesis-student-registry への登録失敗"
        return 1
    fi

    # 4. Issue クローズ
    echo "  Issue クローズ中..."
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 学会ポスターリポジトリの設定が完了しました

## 設定内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## ポスター添削フローについて
1. 0th-draft ブランチで a0poster.tex を編集
2. Pull Request を作成して添削を依頼
3. レビューフィードバックを確認・対応
4. 次稿ブランチ（1st-draft など、自動作成）で改稿を継続

リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches"; then
        echo "  ✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "  ❌ Issue クローズに失敗しました"
        return 1
    fi

    echo ""
    echo "📋 実行された操作:"
    print_author_readme_operation
    echo "  • ブランチ保護設定 (main)"
    echo "  • thesis-student-registry への登録"
    echo "  • Issue #$CURRENT_ISSUE_NUMBER のクローズ"
    echo ""

    return 0
}

#
# 汎用LaTeXリポジトリ処理の振り分け（詳細フィードバック付き）
#
# latex はレビューフロー有効時（作成時オプトイン REVIEW_FLOW、Issue 本文の
# 「レビューフロー: on」で判定）のみブランチ保護付きの処理に分岐する
#
run_latex_with_feedback() {
    if [ "$CURRENT_REVIEW_FLOW" = true ]; then
        process_latex_review_with_feedback
    else
        process_latex_with_feedback
    fi
}

#
# 汎用LaTeXリポジトリ処理・レビューフロー有効（詳細フィードバック付き）
#
# draft PR サイクルを使うためブランチ保護を設定する。registry へはタイプどおり
# latex で登録する（保護の要否は registry ではなく Issue 本文のフラグで決まる）
#
process_latex_review_with_feedback() {
    echo "  📄 汎用LaTeXリポジトリ（レビューフロー有効）の処理を開始..."
    echo ""

    # 1. 著者 README の記入
    fill_author_readme

    # 2. ブランチ保護設定（draft PR レビュー用）
    echo "  ブランチ保護設定を適用中..."
    if REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        echo "  ✅ ブランチ保護設定完了"
    else
        echo "  ❌ ブランチ保護設定失敗"
        return 1
    fi

    # 3. thesis-student-registry 更新
    echo "  thesis-student-registry への登録中..."
    if update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        echo "  ✅ thesis-student-registry への登録完了"
    else
        echo "  ❌ thesis-student-registry への登録失敗"
        return 1
    fi

    # 4. Issue クローズ
    echo "  Issue クローズ中..."
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 汎用LaTeXリポジトリ（レビューフロー有効）の設定が完了しました

## 設定内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## 添削フローについて
1. 0th-draft ブランチで main.tex を編集
2. Pull Request を作成して添削を依頼
3. レビューフィードバックを確認・対応
4. 次稿ブランチ（1st-draft など、自動作成）で改稿を継続

リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches"; then
        echo "  ✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "  ❌ Issue クローズに失敗しました"
        return 1
    fi

    echo ""
    echo "📋 実行された操作:"
    print_author_readme_operation
    echo "  • ブランチ保護設定 (main)"
    echo "  • thesis-student-registry への登録"
    echo "  • Issue #$CURRENT_ISSUE_NUMBER のクローズ"
    echo ""

    return 0
}

#
# 汎用LaTeXリポジトリ処理（詳細フィードバック付き）
#
process_latex_with_feedback() {
    echo "  📄 汎用LaTeXリポジトリの登録処理を開始..."
    echo ""
    
    # 1. 著者 README の記入
    fill_author_readme
    
    # 2. thesis-student-registry 更新（ブランチ保護なし）
    echo "  thesis-student-registry への登録中..."
    if update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        echo "  ✅ thesis-student-registry への登録完了"
    else
        echo "  ❌ thesis-student-registry への登録失敗"
        return 1
    fi
    
    
    # 3. Issue クローズ
    echo "  Issue クローズ中..."
    if close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 汎用LaTeXリポジトリの登録が完了しました

## 設定内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## リポジトリ設定
- **ブランチ保護**: なし（柔軟な利用を優先）
- **作業方法**: main ブランチで直接作業可能
- **用途**: 研究ノート、レポート、実験記録など

## 使用方法
1. main.tex を編集して文書を作成
2. git add, commit, push で変更を保存
3. GitHub Actions で自動的に PDF が生成されます

リポジトリURL: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME"; then
        echo "  ✅ Issue #${CURRENT_ISSUE_NUMBER} をクローズしました"
    else
        echo "  ❌ Issue クローズに失敗しました"
        return 1
    fi
    
    echo ""
    echo "📋 実行された操作:"
    print_author_readme_operation
    echo "  • thesis-student-registry への登録"
    echo "  • Issue #$CURRENT_ISSUE_NUMBER のクローズ"
    echo ""
    
    return 0
}

#
# インタラクティブモード サマリー表示
#
show_interactive_summary() {
    echo
    echo "=== インタラクティブ処理完了 ==="
    echo "処理済み: ${PROCESSED_COUNT}件"
    echo "スキップ: ${SKIPPED_COUNT}件"
    echo "失敗: ${FAILED_COUNT}件"
    echo "情報抽出エラー: ${EXTRACTION_ERROR_COUNT}件"
    
    if [ ${FAILED_COUNT} -gt 0 ]; then
        echo
        echo "失敗したIssue:"
        for failed_issue in "${FAILED_ISSUES[@]}"; do
            echo "  - Issue #${failed_issue}"
        done
    fi
    
    if [ ${EXTRACTION_ERROR_COUNT} -gt 0 ]; then
        echo
        echo "情報抽出エラーのIssue（データ形式確認が必要）:"
        for error_issue in "${EXTRACTION_ERROR_ISSUES[@]}"; do
            echo "  - Issue #${error_issue}"
        done
    fi
}

#
# 単一Issue処理
#
process_single_issue() {
    case "$CURRENT_REPO_TYPE" in
        wr)
            process_weekly_report_issue
            ;;
        sotsuron|master)
            process_thesis_issue
            ;;
        ise)
            process_ise_issue
            ;;
        poster)
            process_poster_issue
            ;;
        latex|other|sotsuron-report)
            # latex はレビューフロー有効時のみブランチ保護付きの処理に分岐する。
            # other / sotsuron-report は常に登録のみ（保護なし・review_flow=false）
            if [ "$CURRENT_REPO_TYPE" = "latex" ] && [ "$CURRENT_REVIEW_FLOW" = true ]; then
                process_latex_review_issue
            else
                process_latex_issue
            fi
            ;;
        *)
            log_error "不明なリポジトリタイプ: $CURRENT_REPO_TYPE"
            return 1
            ;;
    esac
}

#
# 週報リポジトリ処理
#
process_weekly_report_issue() {
    log_info "週報リポジトリ処理: $CURRENT_REPO_NAME"
    
    # 1. thesis-student-registry への登録
    if ! update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "wr"; then
        log_error "thesis-student-registry への登録に失敗: $CURRENT_REPO_NAME"
        return 1
    fi
    
    
    # 2. Issue クローズ
    if ! close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 週報リポジトリの登録が完了しました

## 登録内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **登録日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

週報リポジトリは登録のみで管理されます。ブランチ保護設定は不要です。

論文執筆は以下のガイドを参照してください：
https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/blob/main/WRITING-GUIDE.md"; then
        log_error "Issue クローズに失敗: #$CURRENT_ISSUE_NUMBER"
        return 1
    fi
    
    log_success "週報リポジトリ処理完了: $CURRENT_REPO_NAME"
    return 0
}

#
# 論文リポジトリ処理
#
process_thesis_issue() {
    log_info "論文リポジトリ処理: $CURRENT_REPO_NAME"
    
    # 1. ブランチ保護設定
    if ! REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        log_error "ブランチ保護設定に失敗: $CURRENT_REPO_NAME (学生ID: $CURRENT_STUDENT_ID)"
        return 1
    fi
    
    # 2. thesis-student-registry への登録
    if ! update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        log_error "thesis-student-registry への登録に失敗: $CURRENT_REPO_NAME"
        return 1
    fi
    
    
    # 2. Issue クローズ
    if ! close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 論文リポジトリの設定が完了しました

## 設定内容
- **リポジトリ**: ${DEPLOY_ORG}/$CURRENT_REPO_NAME
- **学生ID**: $CURRENT_STUDENT_ID
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## 確認
リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches

論文執筆は以下のガイドを参照してください：
https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/blob/main/WRITING-GUIDE.md"; then
        log_error "Issue クローズに失敗: #$CURRENT_ISSUE_NUMBER"
        return 1
    fi
    
    log_success "論文リポジトリ処理完了: $CURRENT_REPO_NAME"
    return 0
}

#
# ISEリポジトリ処理
#
process_ise_issue() {
    log_info "ISEリポジトリ処理: $CURRENT_REPO_NAME"
    
    # 1. thesis-student-registry への登録
    if ! update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "ise"; then
        log_error "thesis-student-registry への登録に失敗: $CURRENT_REPO_NAME"
        return 1
    fi
    
    # 2. ブランチ保護設定
    if ! REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        log_error "ブランチ保護設定に失敗: $CURRENT_REPO_NAME (学生ID: $CURRENT_STUDENT_ID)"
        return 1
    fi
    
    # 3. Issue クローズ
    if ! close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ ISEリポジトリの登録とブランチ保護設定が完了しました

## 処理内容
- **リポジトリ登録**: [${DEPLOY_ORG}/$CURRENT_REPO_NAME](https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME) ✓
- **ブランチ保護設定**: 完了 ✓
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## 確認
リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches

Pull Requestベースの学習を開始してください。"; then
        log_error "Issue クローズに失敗: #$CURRENT_ISSUE_NUMBER"
        return 1
    fi
    
    log_success "ISEリポジトリ処理完了: $CURRENT_REPO_NAME"
    return 0
}

#
# 学会ポスターリポジトリ処理
#
# draft PR サイクル（poster-template）を使うためブランチ保護を設定する。
#
process_poster_issue() {
    log_info "学会ポスターリポジトリ処理: $CURRENT_REPO_NAME"

    # 1. thesis-student-registry への登録
    if ! update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        log_error "thesis-student-registry への登録に失敗: $CURRENT_REPO_NAME"
        return 1
    fi

    # 2. ブランチ保護設定
    if ! REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        log_error "ブランチ保護設定に失敗: $CURRENT_REPO_NAME (学生ID: $CURRENT_STUDENT_ID)"
        return 1
    fi

    # 3. Issue クローズ
    if ! close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 学会ポスターリポジトリの登録とブランチ保護設定が完了しました

## 処理内容
- **リポジトリ登録**: [${DEPLOY_ORG}/$CURRENT_REPO_NAME](https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME) ✓
- **ブランチ保護設定**: 完了 ✓
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## 確認
リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches

0th-draft ブランチから Pull Request ベースの添削を開始してください。"; then
        log_error "Issue クローズに失敗: #$CURRENT_ISSUE_NUMBER"
        return 1
    fi

    log_success "学会ポスターリポジトリ処理完了: $CURRENT_REPO_NAME"
    return 0
}

#
# LaTeXリポジトリ処理・レビューフロー有効
#
# 作成時オプトイン REVIEW_FLOW 付きで作られた latex リポジトリ（Issue 本文の
# 「レビューフロー: on」で判定）。draft PR サイクルを使うためブランチ保護を設定する
process_latex_review_issue() {
    log_info "LaTeXリポジトリ（レビューフロー有効）処理: $CURRENT_REPO_NAME"

    # 1. thesis-student-registry への登録（タイプどおり latex で登録。保護の要否は
    #    registry ではなく Issue 本文のフラグで決まる）
    if ! update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        log_error "thesis-student-registry への登録に失敗: $CURRENT_REPO_NAME"
        return 1
    fi

    # 2. ブランチ保護設定
    if ! REPO_OWNER="$DEPLOY_ORG" REGISTRY_OWNER="${REGISTRY_REPO%%/*}" "$SCRIPT_DIR/setup-branch-protection.sh" "${DEPLOY_ORG}/${CURRENT_REPO_NAME}"; then
        log_error "ブランチ保護設定に失敗: $CURRENT_REPO_NAME (学生ID: $CURRENT_STUDENT_ID)"
        return 1
    fi

    # 3. Issue クローズ
    if ! close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ 汎用LaTeXリポジトリ（レビューフロー有効）の登録とブランチ保護設定が完了しました

## 処理内容
- **リポジトリ登録**: [${DEPLOY_ORG}/$CURRENT_REPO_NAME](https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME) ✓
- **ブランチ保護設定**: 完了 ✓
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## ブランチ保護設定
- **main ブランチ**: 1つ以上の承認レビューが必要
- **新しいコミット時**: 古いレビューを無効化
- **フォースプッシュ**: 禁止
- **ブランチ削除**: 禁止

## 確認
リポジトリ設定: https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME/settings/branches

0th-draft ブランチから Pull Request ベースの添削を開始してください。"; then
        log_error "Issue クローズに失敗: #$CURRENT_ISSUE_NUMBER"
        return 1
    fi

    log_success "LaTeXリポジトリ（レビューフロー有効）処理完了: $CURRENT_REPO_NAME"
    return 0
}

# 登録のみリポジトリ処理
#
# latex / other / sotsuron-report を処理する（いずれもブランチ保護なし・
# registry 登録 + Issue クローズのみ。登録タイプは解決済みの
# CURRENT_REPO_TYPE を使用）
process_latex_issue() {
    log_info "LaTeXリポジトリ処理: $CURRENT_REPO_NAME"
    
    # 1. thesis-student-registry への登録のみ（ブランチ保護なし）
    if ! update_thesis_student_registry "$CURRENT_REPO_NAME" "$CURRENT_STUDENT_ID" "$CURRENT_REPO_TYPE"; then
        log_error "thesis-student-registry への登録に失敗: $CURRENT_REPO_NAME"
        return 1
    fi
    
    # 2. Issue クローズ
    if ! close_issue_with_comment "$CURRENT_ISSUE_NUMBER" "✅ リポジトリの登録が完了しました

## 処理内容
- **リポジトリ登録**: [${DEPLOY_ORG}/$CURRENT_REPO_NAME](https://github.com/${DEPLOY_ORG}/$CURRENT_REPO_NAME) ✓
- **設定日時**: $(date '+%Y-%m-%d %H:%M:%S JST')

## このリポジトリについて
- mainブランチで直接作業が可能です
- Pull Requestベースのレビューは任意です
- 自動PDF生成機能が利用可能です

このIssueは自動的にクローズされました。"; then
        log_error "Issue クローズに失敗: #$CURRENT_ISSUE_NUMBER"
        return 1
    fi
    
    log_success "LaTeXリポジトリ処理完了: $CURRENT_REPO_NAME"
    return 0
}

#
# Issueコメント追加
#
# 処理失敗を依頼者にも見えるようにする（issue #473: 無言の滞留防止）
comment_processing_failure() {
    local issue_number="$1"
    local reason="$2"
    local run_url=""

    # 再実行のたびに同文コメントが積もるのを防ぐ（冪等ガード）
    if gh issue view "$issue_number" --repo "$REPO" --json comments \
        --jq '.comments[].body' 2>/dev/null | grep -q "自動処理に失敗しました"; then
        log_debug "Issue #${issue_number}: 失敗コメントは投稿済みのためスキップ"
        return 0
    fi

    if [ -n "${GITHUB_RUN_ID:-}" ]; then
        run_url=" 実行ログ: ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-$REPO}/actions/runs/${GITHUB_RUN_ID}"
    fi

    # リカバリ手順を明記する（issue #530: 復旧前の手動クローズによる取りこぼし防止。
    # 未復旧のままクローズしても verify-protection-on-close.yml が再オープンする）
    add_issue_comment "$issue_number" "⚠️ 自動処理に失敗しました（${reason}）。管理者が対応するまでこの Issue は open のままです。${run_url}

## 管理者向けリカバリ手順

1. 上記の実行ログで失敗原因を確認する
2. ブランチ保護の失敗: \`scripts/setup-branch-protection.sh ${CURRENT_REPO_NAME:-<repo>}\` を再実行する（registry-manager が PATH にあれば registry の protection_status 記録まで自動）
3. レジストリ登録の失敗: \`registry-manager add ${CURRENT_REPO_NAME:-<repo>}\` で再登録する
4. 復旧を確認してからこの Issue をクローズする（未復旧のままクローズすると自動で再オープンされます。リポジトリ作成の取りやめ等は **Close as not planned** でクローズしてください）"
}

add_issue_comment() {
    local issue_number="$1"
    local comment="$2"
    
    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "[DRY-RUN] Issue #${issue_number} にコメント追加: $comment"
        return 0
    fi
    
    if gh issue comment "$issue_number" --repo "$REPO" --body "$comment" >/dev/null 2>&1; then
        log_debug "Issue #${issue_number} にコメントを追加しました"
        return 0
    else
        log_warn "Issue #${issue_number} へのコメント追加に失敗しました"
        return 1
    fi
}

#
# thesis-student-registry 更新（GitHub API経由、github_username付き）
#
update_thesis_student_registry() {
    local repo_name="$1"
    local student_id="$2"
    local repo_type="$3"
    
    log_debug "thesis-student-registry 更新: $repo_name ($repo_type) - $student_id"
    
    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "[DRY-RUN] thesis-student-registry 更新: $repo_name"
        return 0
    fi
    
    # Issue作成者のGitHub usernameを取得
    local github_username="${CURRENT_ISSUE_AUTHOR:-unknown}"

    # review_flow: draft PR サイクルで運用するリポジトリか（registry の必須フィールド）。
    # sotsuron / master / ise / poster は常時 true、latex は作成時オプトイン
    # （CURRENT_REVIEW_FLOW）、wr / other / sotsuron-report は false。
    # ise-report はこの script の判定では生成されないが registry 語彙の別表記
    # （validation が受理する）ため、語彙との整合のため含める。
    # heredoc に JSON boolean として展開するため、リテラルの true 以外はすべて
    # false に正規化する（値の混入で JSON が壊れるのを防ぐ）。
    local review_flow
    case "$repo_type" in
        sotsuron|master|ise|ise-report|poster) review_flow=true ;;
        latex) if [ "$CURRENT_REVIEW_FLOW" = true ]; then review_flow=true; else review_flow=false; fi ;;
        *) review_flow=false ;;
    esac
    
    # GET-mutate-PUT を SHA競合(409)に備えてリトライする（Bug #496: 並行 PUT で
    # 登録が失われる）。競合時は最新の content+sha を取り直し mutation を再適用して再 PUT。
    # content と sha は同一レスポンスから取り出し、取得〜PUT の競合窓を狭める。
    local put_retry_count=0
    # 総試行回数の上限（初回 + (put_max_retries - 1) 回のリトライ = 最大5回 PUT）
    local put_max_retries=5
    while :; do
        # content と sha を1回の取得で得る（別々の GET による窓の拡大を避ける）
        local contents_json
        if ! contents_json=$(gh api "repos/$REGISTRY_REPO/contents/data/registry.json"); then
            log_error "registry.json の取得に失敗: $repo_name"
            return 1
        fi

        local current_json
        if ! current_json=$(echo "$contents_json" | jq -r '.content' | base64 -d 2>/dev/null); then
            log_error "registry.json のデコードに失敗: $repo_name"
            return 1
        fi

        local sha
        sha=$(echo "$contents_json" | jq -r '.sha // empty')
        if [ -z "$sha" ]; then
            log_error "SHA取得に失敗: $repo_name"
            return 1
        fi

        # 新しいエントリを作成（github_usernameを含む）。既存の created_at は取り直した
        # 最新 content から拾い、並行更新による created_at の巻き戻しを防ぐ。
        # 時刻は registry スキーマの ISO8601 UTC（registry-manager
        # docs/data-structure-specification.md）。github_username は配列。
        # コマンド置換を含む local は宣言と代入を分離（set -e で終了コードを握り潰さない）。
        local registry_updated_at
        registry_updated_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
        local created_at
        local existing_created_at
        existing_created_at=$(echo "$current_json" | jq -r --arg repo_name "$repo_name" '.[$repo_name].created_at // empty')
        if [ -n "$existing_created_at" ] && [ "$existing_created_at" != "null" ]; then
            created_at="$existing_created_at"
        else
            created_at="$registry_updated_at"
        fi

        # 既存の github_username 配列に Issue 作成者を追加して重複排除する
        # （複数オーナー登録の保全。レガシーの string 値は配列に正規化してから統合）。
        # 失敗時に空文字列のまま heredoc へ展開すると不正 JSON になるため即失敗させる。
        local github_username_array
        if ! github_username_array=$(echo "$current_json" | jq -c --arg repo_name "$repo_name" --arg u "$github_username" \
            '(.[$repo_name].github_username // []) | if type == "string" then [.] else . end | . + [$u] | unique'); then
            log_error "github_username 配列の生成に失敗: $repo_name"
            return 1
        fi

        local new_entry
        new_entry=$(cat <<EOF
{
  "student_id": "$student_id",
  "repository_type": "$repo_type",
  "created_at": "$created_at",
  "registry_updated_at": "$registry_updated_at",
  "review_flow": $review_flow,
  "github_username": $github_username_array
}
EOF
)

        # JSONを更新
        local updated_json
        if ! updated_json=$(echo "$current_json" | jq --indent 2 --arg repo_name "$repo_name" --argjson new_entry "$new_entry" '.[$repo_name] = $new_entry'); then
            log_error "JSON更新処理に失敗: $repo_name"
            return 1
        fi

        # 個人情報保護のため学生IDをマスク化
        local masked_student_id="${student_id:0:3}***${student_id: -2}"
        local commit_message="Add/update repository: $repo_name

Repository: $repo_name
Student ID: $masked_student_id
Type: $repo_type
GitHub Username: $github_username
Updated: $registry_updated_at

Processed via automated issue processor with GitHub username."

        # base64エンコードしてGitHub APIで更新
        # base64 は環境により76文字ごとに改行を挿入するため tr で除去し1行に揃える
        local encoded_content
        if ! encoded_content=$(echo "$updated_json" | base64 | tr -d '\n'); then
            log_error "base64エンコードに失敗: $repo_name"
            return 1
        fi

        # SHA を指定して PUT（楽観ロック）
        local api_error
        if api_error=$(gh api "repos/$REGISTRY_REPO/contents/data/registry.json" \
            --method PUT \
            --field message="$commit_message" \
            --field content="$encoded_content" \
            --field sha="$sha" 2>&1 >/dev/null); then
            log_debug "thesis-student-registry 更新成功: $repo_name"
            return 0
        fi

        # SHA競合(409)なら最新を取り直して再試行。gh は非2xx 時に末尾へ
        # "(HTTP <code>)" を付けるため、その状態コードで競合を判定する。422 等の
        # 検証エラーはリトライで解消しないため即失敗させ、原因特定を遅らせない。
        put_retry_count=$((put_retry_count + 1))
        if echo "$api_error" | grep -qE 'HTTP 409'; then
            if [ "$put_retry_count" -ge "$put_max_retries" ]; then
                log_error "registry.json 更新が ${put_max_retries} 回の試行すべてSHA競合で失敗: $repo_name"
                log_error "APIエラー詳細: ${api_error}"
                return 1
            fi
            local put_wait_time=$((put_retry_count * 2))
            log_warn "registry.json 更新の競合を検出 (試行 ${put_retry_count}/${put_max_retries}): $repo_name — ${put_wait_time}秒後に再取得して再試行"
            log_debug "APIエラー詳細: ${api_error}"
            sleep "$put_wait_time"
            continue
        fi

        log_error "GitHub API更新に失敗: $repo_name"
        # 権限不足(403)等の切り分けに必須のため API エラーを残す（issue #473）
        log_error "APIエラー詳細: ${api_error}"
        return 1
    done
}

#
# リポジトリ登録（thesis-student-registry統合後）
#


#
# 保護設定完了記録（thesis-student-registry統合後）
#

#
# Issueクローズ
#
close_issue_with_comment() {
    local issue_number="$1"
    local comment="$2"
    
    if [ "$DRY_RUN_MODE" = true ]; then
        log_info "[DRY-RUN] Issue #${issue_number} をクローズ: $comment"
        return 0
    fi
    
    # コメント追加
    if ! add_issue_comment "$issue_number" "$comment"; then
        log_warn "Issue #${issue_number}: コメント追加に失敗しましたが、クローズを続行します"
    fi
    
    # Issue クローズ
    if gh issue close "$issue_number" --repo "$REPO" --reason completed >/dev/null 2>&1; then
        log_debug "Issue #${issue_number} をクローズしました"
        return 0
    else
        log_error "Issue #${issue_number} のクローズに失敗しました"
        return 1
    fi
}

#
# メイン関数
#
main() {
    echo "=== 未処理Issue一括処理スクリプト ==="
    echo "実行時刻: $(date '+%Y-%m-%d %H:%M:%S')"
    echo "ログファイル: $LOG_FILE"

    if [ "$DRY_RUN_MODE" = true ]; then
        echo -e "${YELLOW}[DRY-RUN モード] 実際の変更は行いません${NC}"
    fi

    if [ "$DEBUG_MODE" = true ]; then
        echo -e "${CYAN}[DEBUG モード] 詳細ログを出力します${NC}"
    fi

    echo

    # 前提条件チェック
    if ! check_prerequisites; then
        log_error "前提条件チェックに失敗しました"
        exit 1
    fi

    # バックアップ作成
    if ! create_backup; then
        log_error "バックアップ作成に失敗しました"
        exit 1
    fi

    # thesis-student-registry 準備
    if ! prepare_registry; then
        log_error "thesis-student-registry の準備に失敗しました"
        exit 1
    fi

    # Issue取得・処理
    if ! fetch_and_process_issues; then
        log_error "Issue処理に失敗しました"
        exit 1
    fi

    log_success "スクリプト実行完了"
    echo
    echo "実行結果:"
    echo "  処理済み: ${PROCESSED_COUNT}件"
    echo "  スキップ: ${SKIPPED_COUNT}件"
    echo "  失敗: ${FAILED_COUNT}件"
    echo "  情報抽出エラー: ${EXTRACTION_ERROR_COUNT}件"
    echo "  ログファイル: $LOG_FILE"
    
    if [ ${EXTRACTION_ERROR_COUNT} -gt 0 ]; then
        echo
        echo "情報抽出エラーのIssue（確認推奨）:"
        for error_issue in "${EXTRACTION_ERROR_ISSUES[@]}"; do
            echo "  - Issue #${error_issue}"
        done
    fi

    write_step_summary

    # 1 件でも失敗があれば非 0 で終了し、呼び出し側（Actions）の run を赤にする（issue #473）
    if [ $((FAILED_COUNT + EXTRACTION_ERROR_COUNT)) -gt 0 ]; then
        log_error "失敗 ${FAILED_COUNT} 件 / 情報抽出エラー ${EXTRACTION_ERROR_COUNT} 件のため exit 1"
        exit 1
    fi
}

#
# GitHub Actions の job summary へ集計を出力（ローカル実行では no-op）
#
write_step_summary() {
    [ -z "${GITHUB_STEP_SUMMARY:-}" ] && return 0

    {
        echo "## 登録処理サマリ"
        echo ""
        echo "| 結果 | 件数 |"
        echo "|---|---|"
        echo "| 処理済み | ${PROCESSED_COUNT} |"
        echo "| スキップ | ${SKIPPED_COUNT} |"
        echo "| 失敗 | ${FAILED_COUNT} |"
        echo "| 情報抽出エラー | ${EXTRACTION_ERROR_COUNT} |"

        if [ ${FAILED_COUNT} -gt 0 ]; then
            echo ""
            echo "**失敗した Issue**: $(printf '#%s ' "${FAILED_ISSUES[@]}")"
        fi

        if [ ${EXTRACTION_ERROR_COUNT} -gt 0 ]; then
            echo ""
            echo "**情報抽出エラーの Issue**: $(printf '#%s ' "${EXTRACTION_ERROR_ISSUES[@]}")"
        fi
    } >> "$GITHUB_STEP_SUMMARY"
}

# オプション解析
parse_options "$@"

# デプロイ org とレジストリリポジトリを解決（フラグ/env > 規約）
resolve_deploy_org
resolve_registry_repo

# メイン処理実行
main
