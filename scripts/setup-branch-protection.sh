#!/bin/bash
#
# Individual Branch Protection Setup Script
#
# 個別学生のブランチ保護設定
# Usage: ./setup-branch-protection.sh <repository_name>
#   repository_name: リポジトリ名
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# デフォルト設定（環境変数で上書き可能）
#   DEFAULT_OWNER  : 引数に '<owner>/' プレフィックスが無い場合に補完する既定 owner
#   REGISTRY_OWNER : 学生レジストリ（thesis-student-registry）の管理対象 owner。
#                    対象 owner がこの値と一致する場合のみレジストリを更新する。
readonly DEFAULT_OWNER="${REPO_OWNER:-smkwlab}"
readonly REGISTRY_OWNER="${REGISTRY_OWNER:-smkwlab}"

# カラー定義
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() {
    echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}

error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

warn() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# APIレート制限チェック
check_rate_limit() {
    local remaining=$(gh api rate_limit --jq '.resources.core.remaining' 2>/dev/null || echo "0")
    local reset_time=$(gh api rate_limit --jq '.resources.core.reset' 2>/dev/null || echo "0")
    
    if [ "$remaining" -lt 10 ]; then
        warn "GitHub API レート制限に接近しています: 残り${remaining}リクエスト"
        if [ "$reset_time" -gt 0 ]; then
            local reset_date=$(date -r "$reset_time" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "不明")
            warn "リセット時刻: $reset_date"
        fi
        return 1
    fi
    return 0
}

# アカウント権限チェック
# 注: GitHub Actions 環境（GITHUB_ACTIONS が設定済み）では、GITHUB_TOKEN に
#     十分な権限が保証されているため admin 権限チェックを早期 return でスキップする。
#     そのためリポジトリ存在確認はローカル経路でのみ本関数が行い、Actions 経路では
#     setup_protection 側の存在確認が担う（経路によりエラーメッセージが異なりうる）。
# 返り値:
#   0: 管理者権限あり（または Actions 環境でチェックスキップ）
#   1: 権限なしまたはエラー
verify_admin_permissions() {
    local owner="$1"
    local repo_name="$2"

    log "GitHub CLI認証とアカウント権限を確認中..."
    
    # 現在のユーザー名を取得（GitHub Actionsとローカル両対応）
    local current_user
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        # GitHub Actions環境ではgithub-actions[bot]を使用
        current_user="github-actions[bot]"
        log "GitHub Actions環境で実行中"
    else
        # ローカル環境ではgh api userを使用
        current_user=$(gh api user --jq '.login' 2>/dev/null)
        if [ -z "$current_user" ]; then
            error "GitHub CLI認証に失敗しました"
            error "gh auth login を実行してください"
            return 1
        fi
    fi
    
    log "現在のアクティブアカウント: $current_user"
    
    # GitHub Actions環境では権限チェックをスキップ（GITHUB_TOKENで十分な権限が保証されている）
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        success "✅ GitHub Actions環境: GITHUB_TOKENで権限確認済み"
        return 0
    fi
    
    # ローカル環境でのみadmin権限をチェック（対象リポジトリそのものを確認）
    local test_repo="$owner/$repo_name"
    local has_admin

    log "権限確認対象: $test_repo"

    # 単一の API 呼び出しで存在確認と権限取得を兼ねる。
    #   - 呼び出し自体が失敗 → リポジトリ未作成 or 参照権限なし
    #   - 成功して .permissions.admin が true/false → 権限の有無
    #   - 成功したが値が空 → トークンのスコープ不足等で権限情報を取得できず
    if ! has_admin=$(gh api "repos/$test_repo" --jq '.permissions.admin' 2>/dev/null); then
        error "リポジトリが見つからないか、参照権限がありません: $test_repo"
        error "リポジトリ名・owner・アカウントのアクセス権限を確認してください"
        return 1
    fi

    if [ "$has_admin" = "true" ]; then
        success "✅ 管理者権限を確認しました"
        return 0
    elif [ "$has_admin" = "false" ]; then
        error "❌ 現在のアカウント（$current_user）は管理者権限がありません"
        error "   このアカウントではブランチ保護設定に失敗します"
        echo
        error "解決方法："
        error "  管理者アカウントに切り替えてから再実行してください"
        error "  gh auth switch --user <admin-username>"
        echo
        return 1
    else
        error "権限情報の取得に失敗しました（対象リポジトリ: $test_repo）"
        error "トークンのスコープが不足している可能性があります"
        return 1
    fi
}

# 学生リストの更新（pending → completed）
update_student_lists() {
    local repo_name="$1"
    # データは thesis-student-registry で管理されるため、ローカルファイル操作は不要
    # 注: レジストリ対象 owner かどうかの判定は呼び出し元で行う（本関数はレジストリ更新に専念）。

    log "ブランチ保護設定の記録中..."

    # registry-manager で保護状態を更新
    # ツールは smkwlab/registry-manager リポジトリ（sibling checkout）に分離された
    local registry_manager_path=""

    # 1. コマンドとして利用可能かチェック
    if command -v registry-manager >/dev/null 2>&1; then
        registry_manager_path="registry-manager"
    # 2. スクリプト位置基準で探す（リポジトリルートの親にある sibling checkout）
    elif [ -x "$SCRIPT_DIR/../../registry-manager/registry-manager" ]; then
        registry_manager_path="$SCRIPT_DIR/../../registry-manager/registry-manager"
    # 3. カレントディレクトリ基準のフォールバック
    #    （実行時 CWD がリポジトリルートで、その親に checkout がある場合のみ有効。
    #      CWD に依存するため 2. が失敗した場合の補助として残している）
    elif [ -x "$PWD/../registry-manager/registry-manager" ]; then
        registry_manager_path="$PWD/../registry-manager/registry-manager"
    # 4. 旧配置（thesis-student-registry 内、移行期間中のフォールバック）
    elif [ -x "$SCRIPT_DIR/../../thesis-student-registry/registry_manager/registry-manager" ]; then
        registry_manager_path="$SCRIPT_DIR/../../thesis-student-registry/registry_manager/registry-manager"
    elif [ -x "$PWD/../thesis-student-registry/registry_manager/registry-manager" ]; then
        registry_manager_path="$PWD/../thesis-student-registry/registry_manager/registry-manager"
    fi

    if [ -n "$registry_manager_path" ]; then
        log "registry-manager を使用して保護状態を更新: $registry_manager_path"
        # registry-manager はレジストリ owner（smkwlab）配下の owner なしリポジトリ名で
        # 学生リポジトリを引くため、owner は付けず "$repo_name" のみを渡すのが正しい。
        # （owner != registry_owner の場合は上のガードで既に return 済み）
        #
        # set -e 下でも registry 更新失敗でスクリプト全体が終了しないよう、
        # コマンド置換を if 条件で評価して終了コードを安全に判定する
        local output
        if output=$("$registry_manager_path" protect "$repo_name" 2>&1); then
            success "✅ registry-manager で保護状態を更新しました"
            success "✅ ブランチ保護設定の記録が完了しました"
        else
            warn "⚠️  registry-manager での保護状態更新に失敗しました"
            log "リポジトリ: $repo_name"
            log "コマンド出力: $output"
            log "手動実行が必要: registry-manager protect $repo_name"
            warn "⚠️  ブランチ保護設定の記録が完了しましたが、registry更新は失敗しました"
        fi
    else
        warn "⚠️  registry-manager が見つかりません"
        log "リポジトリ情報: $repo_name"
        log "保護状態: protected (未記録)"
        log "手動実行が必要: registry-manager protect $repo_name"
        warn "⚠️  ブランチ保護設定の記録が完了しましたが、registry更新はスキップされました"
    fi
}



# ブランチ保護設定
setup_protection() {
    local owner="$1"
    local repo_name="$2"

    log "Setting up branch protection for: $owner/$repo_name"

    # APIレート制限チェック
    if ! check_rate_limit; then
        error "API レート制限のため処理を中断します"
        return 1
    fi
    
    # リポジトリ存在確認
    # ローカル経路では verify_admin_permissions が gh api で存在＋権限を確認済み
    # のため、ここでの再確認は行わない（同一リポジトリへの二重 API 呼び出しを回避）。
    # 一方 GitHub Actions 経路では verify_admin_permissions が権限チェックを
    # スキップ（早期 return）するため、存在確認はこのパスで実施する。
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        if ! gh repo view "$owner/$repo_name" >/dev/null 2>&1; then
            error "Repository not found or no read access: $owner/$repo_name"
            error "Please ensure the repository exists and is accessible before setting up protection"
            return 1
        fi
    fi

    # ブランチ存在確認
    local branches_to_protect=("main")

    if ! gh api "repos/$owner/$repo_name/branches/main" >/dev/null 2>&1; then
        error "Main branch not found in repository: $owner/$repo_name"
        return 1
    fi

    # 各ブランチへの保護設定
    local protection_config='{
        "required_status_checks": {
            "strict": false,
            "contexts": []
        },
        "required_pull_request_reviews": {
            "required_approving_review_count": 1,
            "dismiss_stale_reviews": true,
            "require_code_owner_reviews": false,
            "dismissal_restrictions": {
                "users": [],
                "teams": []
            }
        },
        "enforce_admins": false,
        "restrictions": null,
        "allow_force_pushes": false,
        "allow_deletions": false
    }'
    
    local success_count=0
    local total_branches=${#branches_to_protect[@]}
    
    for branch in "${branches_to_protect[@]}"; do
        log "ブランチ '$branch' の保護設定を確認中..."
        
        # 既存の保護設定確認（冪等性保証）
        if gh api "repos/$owner/$repo_name/branches/$branch/protection" >/dev/null 2>&1; then
            log "ブランチ '$branch' は既に保護設定済みです"
            success_count=$((success_count + 1))
            continue
        fi
        
        log "ブランチ '$branch' に保護設定を適用中..."
        if [ -n "${GITHUB_ACTIONS:-}" ]; then
            # GitHub Actions環境では詳細なエラー情報を出力
            if echo "$protection_config" | gh api "repos/$owner/$repo_name/branches/$branch/protection" \
                --method PUT \
                --input - 2>&1; then
                success "✅ ブランチ '$branch' の保護設定が完了しました"
                success_count=$((success_count + 1))
            else
                local api_exit_code=$?
                error "❌ ブランチ '$branch' の保護設定に失敗しました (exit code: $api_exit_code)"
                error "GitHub Actions環境でのAPI エラーです。詳細は上記のエラーメッセージを確認してください。"
                error "ヒント: Actions では権限チェックをスキップするため、GITHUB_TOKEN に"
                error "      'administration: write'（ブランチ保護の管理権限）が付与されているか確認してください。"
            fi
        else
            # ローカル環境では従来通り
            if echo "$protection_config" | gh api "repos/$owner/$repo_name/branches/$branch/protection" \
                --method PUT \
                --input - >/dev/null 2>&1; then
                success "✅ ブランチ '$branch' の保護設定が完了しました"
                success_count=$((success_count + 1))
            else
                error "❌ ブランチ '$branch' の保護設定に失敗しました"
            fi
        fi
    done
    
    if [ "$success_count" -eq "$total_branches" ]; then
        success "✅ すべてのブランチ保護設定が完了しました ($success_count/$total_branches)"
        success "   Repository: https://github.com/$owner/$repo_name"
        success "   Protected branches: ${branches_to_protect[*]}"
        success "   Protection rules:"
        success "     - Requires 1 approving review before merge"
        success "     - Dismisses stale reviews when new commits are pushed"
        success "     - Prevents force pushes and branch deletion"
        success "     - Lets administrators bypass protection (enforce_admins: false)"

        # 学生リストの更新（pending → completed）
        # 学生レジストリ（thesis-student-registry）は REGISTRY_OWNER 配下の学生
        # リポジトリのみを管理対象とするため、owner が一致しない場合はスキップする。
        if [ "$owner" = "$REGISTRY_OWNER" ]; then
            update_student_lists "$repo_name"
        else
            log "owner '$owner' は学生レジストリ（$REGISTRY_OWNER）の管理対象外のため、registry 更新をスキップします"
        fi

        return 0
    else
        error "❌ 一部のブランチ保護設定に失敗しました ($success_count/$total_branches)"
        error "   成功: $success_count, 失敗: $((total_branches - success_count))"
        return 1
    fi
}

# ヘルプ表示
show_help() {
    cat <<EOF
Individual Branch Protection Setup Script

Usage: $0 <repository_name>
       $0 <owner>/<repository_name>

Arguments:
  repository_name        Repository name only. The owner defaults to
                         \$REPO_OWNER (default: smkwlab).
  owner/repository_name  Fully-qualified target. Use this form to set up
                         protection for repositories outside the smkwlab
                         organization (e.g. personal accounts).

Environment:
  REPO_OWNER     Default owner used when the argument has no '<owner>/' prefix
                 (default: smkwlab)
  REGISTRY_OWNER Owner whose repositories are tracked in the student registry.
                 The registry (thesis-student-registry) is only updated when the
                 target owner matches this value (default: smkwlab)

Examples:
  $0 k21rs001-sotsuron              # → smkwlab/k21rs001-sotsuron (default owner)
  $0 k21gjk01-thesis                # → smkwlab/k21gjk01-thesis
  $0 k02jk059-ise-report1           # → smkwlab/k02jk059-ise-report1
  $0 myorg/k21rs001-sotsuron        # → myorg/k21rs001-sotsuron (explicit owner)
  REPO_OWNER=myuser $0 my-paper     # → myuser/my-paper (owner via env var)

Protection Rules Applied:
  - Requires 1 approving review before merge
  - Dismisses stale reviews when new commits are pushed
  - Prevents force pushes and branch deletion
  - Does not enforce admin restrictions

Requirements:
  - GitHub CLI (gh) must be authenticated
  - Admin access to target repository
  - Target repository and main branch must exist
EOF
}

# メイン処理
main() {
    local input="$1"

    if [ -z "$input" ]; then
        error "Repository name is required"
        echo
        show_help
        exit 1
    fi

    # owner/repo の解決
    #   - "<owner>/<repo>" 形式が渡された場合は owner を抽出する
    #   - リポジトリ名のみの場合は REPO_OWNER（既定: smkwlab）を owner とする
    # "<owner>/<repo>" を分割する。
    #   - owner     = 最初の '/' より前   : ${input%%/*}
    #   - repo_name = 最初の '/' より後ろ : ${input#*/}
    # 多重スラッシュ（例: a/b/c）の場合は repo_name に '/' が残るため
    # （owner=a, repo_name=b/c）、後続の正規表現バリデーションで弾かれる。
    local owner repo_name
    if [[ "$input" == */* ]]; then
        owner="${input%%/*}"
        repo_name="${input#*/}"
    else
        owner="$DEFAULT_OWNER"
        repo_name="$input"
    fi

    # owner / repo_name の妥当性チェック
    # GitHub の命名規則に合わせて検証する。
    #   - owner（ユーザー/組織名）: 英数字とハイフン。先頭は英数字（先頭ハイフン不可）。
    #   - repo_name（リポジトリ名）: 英数字と '.' '_' '-'
    # これにより空文字・多重スラッシュ（例: owner//repo, a/b/c）・先頭/末尾スラッシュ・
    # 先頭ハイフンの owner（例: -badowner）・空白などの不正文字をまとめて弾く。
    # 注: 1 文字の owner（例: a）は許可する。末尾/連続ハイフンの owner や、
    # '.'/'..' のような病的な repo_name の禁止までは検証せず、それらはここを通過
    # しても最終的に GitHub API 側でエラーとなる。
    if [[ ! "$owner" =~ ^[A-Za-z0-9][A-Za-z0-9-]*$ ]] || [[ ! "$repo_name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        error "Invalid repository specification: $input"
        error "Expected '<repository_name>' or '<owner>/<repository_name>'"
        error "  e.g. 'k21rs001-sotsuron' or 'smkwlab/k21rs001-sotsuron'"
        error "  (multi-slash like 'a/b/c', empty parts, or spaces are not allowed)"
        exit 1
    fi

    # GitHub CLI認証確認（GitHub Actionsとローカル両対応）
    if ! gh auth status >/dev/null 2>&1; then
        error "GitHub CLI is not authenticated or current account is invalid"
        error "Please run 'gh auth login' first"
        exit 1
    fi

    # アカウント権限チェック
    if ! verify_admin_permissions "$owner" "$repo_name"; then
        exit 1
    fi

    setup_protection "$owner" "$repo_name"
}

# コマンドライン処理
case "${1:-}" in
    -h|--help)
        show_help
        exit 0
        ;;
    "")
        error "Repository name is required"
        echo
        show_help
        exit 1
        ;;
    *)
        main "$@"
        ;;
esac
