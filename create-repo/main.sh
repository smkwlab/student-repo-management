#!/bin/bash
# 学生リポジトリセットアップスクリプト（統合版）
#
# 6 種類の文書タイプ（thesis / wr / latex / ise / poster / sotsuron-report）の
# リポジトリ作成を
# 1 本で担う。タイプは環境変数 DOC_TYPE で選択する（setup.sh が
# docker run -e DOC_TYPE=... で注入。位置引数 $1 は従来どおり学籍番号）。
#
# 設計基準（Issue #516、#554 で conf 外出しに改訂）:
# - タイプ定義（静的設定と decide_repo_name / build_commit_message /
#   print_next_steps の 3 関数）は types/<type>.conf に置き、下の明示 whitelist
#   case で source する。conf の契約は types/README.md を参照。
# - eval や "func_$DOC_TYPE" 式の動的関数名解決は使わない。conf の選択も
#   タイプ名を列挙した case で行う（whitelist 検証を兼ねる）。
# - タイプ一覧は types/*.conf で列挙できる。main.sh 内の残りのタイプ固有処理
#   （ヘルパー関数・フロー中のガード）は grep -n 'DOC_TYPE' で列挙できる。
# - 対話プロンプト・コミットメッセージ・完了メッセージ・ログ文言は学生
#   リポジトリの履歴・実行ログに残るため逐語保存（詳細は types/README.md）。
# - conf の関数は REPO_NAME / COMMIT_MESSAGE 等の決められた変数の設定のみを
#   行い、共通フローの順序に依存する副作用を持たない。タイプ固有の判定・
#   プロンプトのヘルパーは本ファイルに置き、conf から明示名で呼ぶ。

set -e

# 共通ライブラリの読み込み
source ./common-lib.sh

# ================================
# 文書タイプの検証
# ================================
# setup.sh 側の case でも whitelist 済みだが、コンテナを setup.sh 経由せず
# 直接実行するデバッグ経路でも安全にするため二重に検証する
# （AUTO_ASSIGN_REVIEWER の二重検証と同じ既存流儀）。
DOC_TYPE="${DOC_TYPE:?DOC_TYPE を指定してください (thesis|wr|latex|ise|poster|sotsuron-report)}"

# ================================
# タイプ定義の読み込み
# ================================
# 各タイプの静的設定と 3 関数（decide_repo_name / build_commit_message /
# print_next_steps）は types/<type>.conf が定義する（契約は types/README.md）。
# この case はタイプ名の whitelist 検証を兼ねる（動的なパス組み立てをしない）。
case "$DOC_TYPE" in
    thesis) source ./types/thesis.conf ;;
    wr)     source ./types/wr.conf ;;
    latex)  source ./types/latex.conf ;;
    ise)    source ./types/ise.conf ;;
    poster) source ./types/poster.conf ;;
    sotsuron-report) source ./types/sotsuron-report.conf ;;
    *)
        die "サポートされていない文書タイプ: $DOC_TYPE (thesis|wr|latex|ise|poster|sotsuron-report)"
        ;;
esac

# REVIEW_FLOW: latex 専用のオプトイン。draft PR レビューフロー（main + 0th-draft
# 初期化・auto-assign）を有効化する。setup.sh が truthy を true に正規化して
# 転送するが、コンテナを直接実行する経路にも効かせるため本体側でも truthy 判定する
if [ "$DOC_TYPE" = "latex" ] && [[ "${REVIEW_FLOW:-}" =~ ^(true|TRUE|1|yes|YES)$ ]]; then
    SETUP_AUTO_ASSIGN=true
    USE_DRAFT_FLOW=true
fi

# 共通初期化
init_script_common "$SCRIPT_TITLE" "$SCRIPT_EMOJI"

# ================================
# 設定
# ================================
ORGANIZATION=$(determine_organization)

# テンプレートリポジトリの決定。全タイプで TEMPLATE_REPO による上書きに対応する
# （setup.sh はタイプ非依存で TEMPLATE_REPO をコンテナへ転送する。Issue #517 で
# 全タイプ上書き可に統一）。既定値は conf の TEMPLATE_BASENAME と
# TEMPLATE_ORG_POLICY から組み立てる:
# - follow  … 実行 org に追従（${ORGANIZATION}/<basename>）
# - smkwlab … smkwlab 固定（個人ユーザー = ORGANIZATION が個人アカウントでも
#   利用する共有テンプレのため。他 org で独自テンプレを使う場合は TEMPLATE_REPO
#   で上書きする）
case "$TEMPLATE_ORG_POLICY" in
    follow)  TEMPLATE_REPOSITORY="${TEMPLATE_REPO:-${ORGANIZATION}/${TEMPLATE_BASENAME}}" ;;
    smkwlab) TEMPLATE_REPOSITORY="${TEMPLATE_REPO:-smkwlab/${TEMPLATE_BASENAME}}" ;;
    *) die "内部エラー: 未知の TEMPLATE_ORG_POLICY: ${TEMPLATE_ORG_POLICY:-<unset>} (types/${DOC_TYPE}.conf を確認してください)" ;;
esac
VISIBILITY="private"

log_info "テンプレートリポジトリ: $TEMPLATE_REPOSITORY"

# 学籍番号の取得（INDIVIDUAL_MODE のときはスキップして空文字）
STUDENT_ID=$(read_student_id_if_needed "$1" "$STUDENT_ID_EXAMPLES") || exit 1

# ================================
# タイプ固有関数群（旧 main-<type>.sh から逐語移設）
# ================================

# --- thesis: 論文タイプの判定（旧 main-thesis.sh） ---
determine_thesis_type() {
    local student_id="$1"
    # kxxの次の文字がgの場合は修士論文、それ以外は卒業論文
    if echo "$student_id" | grep -qE '^k[0-9]{2}g'; then
        echo "shuuron"
    else
        echo "sotsuron"
    fi
}

# --- latex: ドキュメント名の入力（旧 main-latex.sh） ---
read_document_name() {
    if [ -n "$DOCUMENT_NAME" ]; then
        log_info "ドキュメント名: $DOCUMENT_NAME（環境変数指定）"
        return 0
    fi

    echo ""
    echo "📝 ドキュメント名を入力してください (デフォルト: latex):"
    echo "   例: research-note, report2024, experiment-log"
    read -r -p "> " DOCUMENT_NAME

    DOCUMENT_NAME="${DOCUMENT_NAME:-latex}"

    if ! [[ "$DOCUMENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "ドキュメント名は英数字、ハイフン、アンダースコアのみ使用可能です"
        DOCUMENT_NAME=""
        read_document_name
    fi
}

# --- poster: ポスター名の入力（旧 main-poster.sh） ---
read_poster_name() {
    if [ -n "$POSTER_NAME" ]; then
        log_info "ポスター名: $POSTER_NAME（環境変数指定）"
        return 0
    fi

    if [ -n "$DOCUMENT_NAME" ]; then
        POSTER_NAME="$DOCUMENT_NAME"
        log_info "ポスター名: $POSTER_NAME（環境変数指定）"
        return 0
    fi

    echo ""
    echo "📊 ポスター名を入力してください (デフォルト: poster):"
    echo "   例: jxiv2025-poster, conference2024, symposium-poster"
    read -r -p "> " POSTER_NAME

    POSTER_NAME="${POSTER_NAME:-poster}"

    if ! [[ "$POSTER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        log_error "ポスター名は英数字、ハイフン、アンダースコアのみ使用可能です"
        POSTER_NAME=""
        read_poster_name
    fi
}

# --- ise: ISE レポート番号の決定とリポジトリ存在チェック（日時ベース） ---
# 実装メモ（Issue #520 で修正）:
# - 学期判定は日本の学期基準のため JST で行う（`TZ='JST-9'`）。Alpine busybox の date は
#   tzdata 無しでも POSIX offset 形式 `JST-9`（UTC+9・DST なし）を解釈できる。
# - `date +%m` はゼロ埋め（08/09）で、算術文脈 `(( ))` では 8 進数と解釈されエラーに
#   なるため、比較は `10#` で 10 進を強制する。
# - `local var=$(cmd)` は local 自体の終了コード（常に 0）で `$?` を潰す（SC2155）。
#   API エラー分岐を機能させるため、宣言と代入を分離して `$?` が gh の終了コードを
#   拾うようにしている。
determine_ise_report_number() {
    local student_id="$1"
    local report_num

    # 環境変数による手動制御をチェック
    if [ -n "$ISE_REPORT_NUM" ] && [ "$ISE_REPORT_NUM" != "auto" ]; then
        if [ "$ISE_REPORT_NUM" = "1" ] || [ "$ISE_REPORT_NUM" = "2" ]; then
            local target_repo="${ORGANIZATION}/${student_id}-ise-report${ISE_REPORT_NUM}"
            local api_result
            api_result=$(gh api "repos/${target_repo}" --jq .name 2>&1)
            local api_status=$?

            if [ $api_status -eq 0 ]; then
                if [ "$api_result" = "${student_id}-ise-report${ISE_REPORT_NUM}" ]; then
                    log_error "リポジトリ ${target_repo} は既に存在します"
                    echo "   https://github.com/${target_repo}" >&2
                    exit 1
                fi
            elif ! echo "$api_result" | grep -q "HTTP 404" 2>/dev/null; then
                log_warn "GitHub APIへのアクセスに問題が発生しました"
                echo "   詳細: $api_result" >&2
                exit 1
            fi
            log_debug "手動指定: ISE_REPORT_NUM=$ISE_REPORT_NUM"
            echo "$ISE_REPORT_NUM"
            return
        else
            die "ISE_REPORT_NUM は 1 または 2 を指定してください (現在: $ISE_REPORT_NUM)"
        fi
    fi

    # 学期判定（日本の学期基準のため JST。busybox は tzdata 無しでも JST-9 を解釈する）
    # SC2155 回避のため宣言と代入を分離する（他の gh api 呼び出しと同じ流儀）
    local current_month
    current_month=$(TZ='JST-9' date +%m)
    # date 失敗で空になると後段の `(( 10#$current_month ... ))` が算術構文エラーになるため、
    # 空でないことを保証する（現実にはまず失敗しないが防御的に）
    [ -n "$current_month" ] || die "学期判定の日付取得に失敗しました"
    local preferred_num fallback_num

    # 10# でゼロ埋め月（08/09）の 8 進誤解釈を防ぐ
    if (( 10#$current_month >= 4 && 10#$current_month <= 9 )); then
        preferred_num=1
        fallback_num=2
        log_debug "前期期間 (${current_month}月): ise-report1 を優先"
    else
        preferred_num=2
        fallback_num=1
        log_debug "後期期間 (${current_month}月): ise-report2 を優先"
    fi

    # 優先リポジトリをチェック
    local preferred_repo="${ORGANIZATION}/${student_id}-ise-report${preferred_num}"
    local api_result
    api_result=$(gh api "repos/${preferred_repo}" --jq .name 2>&1)
    local api_status=$?

    if [ $api_status -ne 0 ]; then
        if echo "$api_result" | grep -q "HTTP 404" 2>/dev/null; then
            report_num=$preferred_num
            log_info "${student_id}-ise-report${preferred_num} は利用可能"
        else
            log_warn "GitHub APIへのアクセスに問題が発生しました"
            echo "   詳細: $api_result" >&2
            exit 1
        fi
    elif [ "$api_result" != "${student_id}-ise-report${preferred_num}" ]; then
        report_num=$preferred_num
        log_info "${student_id}-ise-report${preferred_num} は利用可能"
    else
        # フォールバックをチェック
        local fallback_repo="${ORGANIZATION}/${student_id}-ise-report${fallback_num}"
        local fallback_result
        fallback_result=$(gh api "repos/${fallback_repo}" --jq .name 2>&1)
        local fallback_status=$?

        if [ $fallback_status -ne 0 ]; then
            if echo "$fallback_result" | grep -q "HTTP 404" 2>/dev/null; then
                report_num=$fallback_num
                log_warn "${student_id}-ise-report${preferred_num} は既存、${student_id}-ise-report${fallback_num} を使用"
            else
                log_warn "GitHub APIへのアクセスに問題が発生しました"
                echo "   詳細: $fallback_result" >&2
                exit 1
            fi
        elif [ "$fallback_result" != "${student_id}-ise-report${fallback_num}" ]; then
            report_num=$fallback_num
            log_warn "${student_id}-ise-report${preferred_num} は既存、${student_id}-ise-report${fallback_num} を使用"
        else
            log_error "情報科学演習レポートは最大2つまでです"
            echo "   前期用: https://github.com/${ORGANIZATION}/${student_id}-ise-report1" >&2
            echo "   後期用: https://github.com/${ORGANIZATION}/${student_id}-ise-report2" >&2
            echo "" >&2
            echo "削除が必要な場合は、担当教員にご相談ください。" >&2
            exit 1
        fi
    fi

    echo "$report_num"
}

# --- thesis: 論文タイプに応じて不要なファイルを削除（旧 main-thesis.sh） ---
remove_unused_thesis_files() {
    if [ "$THESIS_TYPE" = "shuuron" ]; then
        rm -f sotsuron.tex gaiyou.tex example.tex example-gaiyou.tex 2>/dev/null || true
        log_debug "修士論文用: sotsuron.tex, gaiyou.tex, example.tex, example-gaiyou.tex を削除しました"
    else
        rm -f thesis.tex abstract.tex 2>/dev/null || true
        log_debug "卒業論文用: thesis.tex, abstract.tex を削除しました"
    fi
}

# ================================
# メインフロー
# ================================
# 5 タイプの処理列はすべて thesis の順序（aldc → タイプ固有削除 → auto-assign →
# 組織外ワークフロー削除 → cleanup → コミット → registry）の部分列であり、
# 順序の入れ替えなしにフラグガード付きの単一線形フローで全タイプを表現できる。

# リポジトリ名の決定
decide_repo_name

# 標準セットアップフロー
run_standard_setup "$DOC_TYPE"

# LaTeX環境のセットアップ（ise は HTML ベースのため実行しない）
# 注意: bare call のまま維持すること。set -e 下で aldc 失敗 = スクリプト終了が
# 現行挙動であり、|| true や条件式への組み込みは挙動を変えるため禁止。
if [ "$RUN_ALDC" = true ]; then
    setup_latex_environment
fi

# 論文タイプに応じて不要なファイルを削除
if [ "$DOC_TYPE" = "thesis" ]; then
    remove_unused_thesis_files
fi

# smkwlab 組織メンバーの場合は auto-assign 設定を追加
if [ "$SETUP_AUTO_ASSIGN" = true ]; then
    setup_auto_assign_for_organization_members
fi

# 組織外ユーザーの場合は組織専用ワークフローを削除
remove_org_specific_workflows

# 教員の添削ルールによる下書きレビュー（ルールを読める org の論文のみ）
setup_rule_review_for_organization || exit 1

# テンプレートファイルの整理（aldc 実行後に行う必要がある: Issue #433）
# ise は aldc 非実行のため *-aldc は無いが、テンプレート由来の CLAUDE.md / docs/
# の削除が必要なのは同じ（Issue #433）
cleanup_template_files

# 変更をコミットしてプッシュ
build_commit_message

if [ "$USE_DRAFT_FLOW" = true ]; then
    # main へのセットアップコミット → 0th-draft 作成 → 初期ドラフト commit/push。
    # 注意: bare call 必須（|| exit 1 を付けると関数内の set -e が無効化される。
    # 詳細は common-lib.sh の finalize_with_draft_flow を参照）
    finalize_with_draft_flow "$COMMIT_MESSAGE"
else
    commit_and_push "$COMMIT_MESSAGE" || exit 1
fi

# Registry Manager連携（INDIVIDUAL_MODEでない場合のみ）
if ! is_individual_mode; then
    if [ "$DOC_TYPE" = "thesis" ]; then
        # registry の正式語彙へ変換（内部値 shuuron はテンプレート整理用、issue #471）
        if [ "$THESIS_TYPE" = "shuuron" ]; then
            run_registry_integration "master"
        else
            run_registry_integration "$THESIS_TYPE"
        fi
    else
        run_registry_integration "$DOC_TYPE"
    fi
fi

# 完了メッセージ
print_next_steps
