# Thesis Management Tools

論文執筆ワークフローの管理ツールとガイドドキュメント集です。
GitHub を使った効率的な論文指導をサポートします。

## 対象ユーザー

### 組織内ユーザー（smkwlab）
- **学生**: 論文執筆・提出（PR添削ワークフロー付き）
- **教員**: 論文添削・指導
- **管理者**: レビューワークフロー管理
- **TA・先輩**: 副指導・レビュー支援

### 個人ユーザー（組織外）
- **個人研究者・学習者**: LaTeX環境での文書作成
- **他大学の学生**: 個人的なLaTeX論文執筆環境

## 🎓 LaTeX環境のセットアップ

### 組織内学生向け（smkwlab所属）

**PR添削ワークフロー付き論文執筆環境の作成**

**前提条件:**
- Windows: WSL + Docker Desktop
- macOS: Docker Desktop
- GitHub CLI（推奨、認証を大幅に簡素化）

#### 卒業論文・修士論文用
```bash
bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

#### 週間報告用
```bash
bash <(curl -fsSL https://repo-setup.smkwlab.net) wr
```

#### 汎用LaTeX文書用（研究ノート、レポート等）
```bash
bash <(curl -fsSL https://repo-setup.smkwlab.net) latex
```

> 末尾の `thesis` / `wr` / `latex` / `ise` / `poster` が文書タイプとして `setup.sh` に渡されます。

**実行手順:**
1. GitHub CLI がある場合：
   - `gh auth login` でGitHubにログイン
   - 上記コマンドを実行（自動認証）
2. GitHub CLI がない場合：
   - 上記コマンドを実行
   - GitHub認証：ワンタイムコードをブラウザで入力
3. 学籍番号を入力
4. 自動でリポジトリ作成・セットアップ完了

**複数GitHubアカウントがある場合:**
```bash
# アカウント切り替え
gh auth switch --user your-username

# または個人アカウントに作成（論文の例。wr / latex / ise / poster も同様）
TARGET_ORG=your-username bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

### 個人ユーザー向け（組織外）

**高品質なLaTeX文書作成環境を個人でも利用可能**

smkwlab組織に所属していない方でも、同じセットアップスクリプトで個人用のLaTeX環境を構築できます。組織外ユーザーは自動的に個人モードで動作します。

**セットアップコマンド:**
```bash
# 個人用 LaTeX 文書（組織外ユーザーは自動的に個人モードになります）
bash <(curl -fsSL https://repo-setup.smkwlab.net) latex

# 明示的に個人モード指定（組織メンバーが個人利用したい場合）
INDIVIDUAL_MODE=true bash <(curl -fsSL https://repo-setup.smkwlab.net) latex
```

**個人モードの特徴:**
| 機能 | 個人モード | 組織モード |
|------|-----------|-----------|
| LaTeX環境 (DevContainer) | ✅ 提供 | ✅ 提供 |
| textlint日本語校正 | ✅ 提供 | ✅ 提供 |
| VS Code統合 | ✅ 提供 | ✅ 提供 |
| リポジトリ作成先 | 個人アカウント | smkwlab組織 |
| ブランチ保護 | ❌ なし | ✅ 自動設定 |
| PR添削ワークフロー | ❌ なし | ✅ 教員レビュー |
| 進捗管理 | ❌ なし | ✅ 組織レベル |

**実行手順:**
1. `gh auth login` でGitHubにログイン
2. 上記コマンドを実行
3. リポジトリ名のベースを入力（例: your-username, my-thesis など）
4. 個人用LaTeX環境が自動設定されます

### 📚 手動テンプレート使用
1. [sotsuron-template](https://github.com/smkwlab/sotsuron-template) にアクセス
2. 「Use this template」をクリック
3. リポジトリ名を `学籍番号-sotsuron` 形式で入力
4. 手動でLaTeX環境をセットアップ

## 📁 構成

### `docs/` - ガイドドキュメント

教員向けガイドは [latex-ecosystem/docs/](https://github.com/smkwlab/latex-ecosystem/tree/main/docs) に集約されています:

- **[TEACHER-ONBOARDING.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/TEACHER-ONBOARDING.md)**: 初めて論文指導を始める教員向けオンボーディング（最初の1時間で読む文書）
- **[PR-REVIEW-GUIDE.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/PR-REVIEW-GUIDE.md)**: GitHub PR 初心者向け添削ガイド（コメント・Suggestion・複数教員での連携）
- **[TEACHER-GUIDE.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/TEACHER-GUIDE.md)**: 教員向け添削・管理ガイド（初期設定・スクリプト・提出プロセス管理）

本リポジトリの docs/ には開発者向け文書（CLAUDE-*.md ほか）が置かれています。

### `scripts/` - 運用ツール

- **[setup-branch-protection.sh](scripts/setup-branch-protection.sh)**: mainブランチ保護設定（教員用）
  - main ブランチの誤操作防止
  - GitHub Actions によるレビュー要件のバイパスを許可

### `create-repo/` - リポジトリ作成ツール

- **[setup.sh](create-repo/setup.sh)**: リポジトリ作成スクリプト
  - Docker-based zero-dependency setup
  - クロスプラットフォーム対応
  - ブラウザ認証統合

- **[main.sh](create-repo/main.sh)**: Docker 内実行の統合メインスクリプト（文書タイプは環境変数 `DOC_TYPE` で選択: thesis / wr / latex / ise / poster）
  - GitHub認証・リポジトリ作成
  - LaTeX環境自動セットアップ
  - ブランチ構造初期化

## 🚀 クイックスタート

### 1. 学生のリポジトリ作成

学生自身がスクリプトを使って論文リポジトリを作成：

```bash
# リポジトリ作成スクリプト実行（論文リポジトリの例）
bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

### 2. 添削ワークフローの開始

1. **学生がPR作成** → 自動的に以下が実行:
   - 次稿ブランチ自動作成
   - レビューブランチ自動更新
   - レビュー用PR自動更新

2. **教員が添削実施**:
   - 個別PR: 差分レビュー
   - レビュー用PR: 全体レビュー

3. **学生がPRをクローズ**:
   - 添削対応完了後、自分でPRをクローズ
   - 並行して次稿執筆継続可能

4. **PRはマージしません**: 添削専用として活用、学生が自分でクローズ

## 📚 対応テンプレート

このツールセットは以下のテンプレートで使用できます:

- **[sotsuron-template](https://github.com/smkwlab/sotsuron-template)**: 卒業論文・修士論文用

## 🔧 主要機能

### 論文リポジトリ作成・管理

- ✅ **自動リポジトリ作成**: Docker経由での依存関係なしセットアップ
- ✅ **ブランチ保護設定**: 教員レビュー必須の安全なワークフロー
- ✅ **Issue自動管理**: ブランチ保護設定依頼の自動化
- ✅ **一括管理機能**: 複数学生のリポジトリを効率的に管理

#### 管理システムアーキテクチャ（2025-06-22統一）
- **データ統一管理**: `data/` ディレクトリで一元管理
- **学生レジストリ**: `data/students/` で年度別・タイプ別管理
- **保護状況追跡**: `data/protection-status/` で設定状況を追跡
- **GitHub Actions連携**: Issue駆動の自動処理

### 完全自動化ワークフロー

- ✅ **次稿ブランチ自動作成**: 1st-draft → 2nd-draft → ... → 20th-draft
- ✅ **概要ブランチ自動作成**: abstract-1st → abstract-2nd → ...
- ✅ **レビューブランチ自動更新**: PR作成時に自動同期
- ✅ **並行執筆サポート**: 添削完了を待たずに次稿執筆開始

### 効率的な添削システム

- ✅ **差分レビュー**: 変更点のみを効率的に確認
- ✅ **全体レビュー**: 論文全体の構成・整合性確認
- ✅ **複数教員対応**: 役割分担・並行レビュー
- ✅ **Suggestion機能**: 具体的な修正提案

### 学生体験の向上

- ✅ **GitHub Desktop**: Git知識不要の簡単操作
- ✅ **自動化**: ブランチ作成・管理の自動化
- ✅ **明確な手順**: ステップバイステップガイド
- ✅ **エラー回避**: 自動化によるヒューマンエラー削減

## 📖 詳細ガイド

### 教員向け

教員向けガイドは [latex-ecosystem/docs/](https://github.com/smkwlab/latex-ecosystem/tree/main/docs) に集約されています。

0. **初めて本エコシステムで論文指導を始める場合**
   → [TEACHER-ONBOARDING.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/TEACHER-ONBOARDING.md)

1. **初めてGitHub PRを使う場合**
   → [PR-REVIEW-GUIDE.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/PR-REVIEW-GUIDE.md)

2. **技術的な詳細・上級操作**
   → [TEACHER-GUIDE.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/TEACHER-GUIDE.md)

3. **リポジトリ管理・一括操作**
   → [管理ツール使用方法](#管理ツール) 参照

### 学生向け

**論文執筆ガイドは各テンプレートリポジトリにあります**:
- [sotsuron-template](https://github.com/smkwlab/sotsuron-template) - 卒業論文・修士論文用

## 📊 管理ツール

学生リポジトリの状況確認・PR/Issue 統計・活動状況・ブランチ保護確認は
**[thesis-monitor](https://github.com/smkwlab/thesis-monitor)**（Elixir escript、
レジストリ `data/registry.json` を GitHub API で参照）で行います。ブランチ保護の
一括設定は、リポジトリ登録の自動化ワークフロー
（`.github/workflows/student-repo-management.yml` + `scripts/setup-branch-protection.sh`）
が担当します。

```bash
# 全学生リポジトリの状況確認 / 統計 / 活動 / 保護状況
thesis-monitor status
thesis-monitor pr-stats
thesis-monitor activity
thesis-monitor check
```

> `thesis-monitor` のインストール・設定手順は
> [thesis-monitor の README](https://github.com/smkwlab/thesis-monitor#readme) を参照してください。

### 設定される保護ルール

自動化ワークフロー（`student-repo-management.yml`）と `scripts/setup-branch-protection.sh` が
論文リポジトリに適用するブランチ保護ルールは以下のとおりです。

- 1つ以上の承認レビューが必要
- 新しいコミット時に古いレビューを無効化
- フォースプッシュとブランチ削除を禁止
- 管理者に対する制限は適用なし

### 個別スクリプト

#### scripts/setup-branch-protection.sh

単一学生のブランチ保護設定用：

```bash
cd scripts
./scripts/setup-branch-protection.sh k21rs001-sotsuron
```

- Issue の自動クローズ機能付き
- エラー時の詳細診断機能

## 🛠️ システム要件

### 教員・管理者

- **GitHub CLI**: リポジトリ作成・管理用
- **Git**: バージョン管理
- **Bash**: スクリプト実行環境

### 学生

- **GitHub Desktop**: ブランチ操作・コミット
- **VS Code + LaTeX Workshop**: 論文執筆環境
- **Docker**: devcontainer環境（自動設定）

## 🔍 トラブルシューティング

### よくある問題

#### GitHub Actions が動作しない
```bash
# ワークフロー実行状況確認
gh run list --repo smkwlab/{student-repo}
```

#### ブランチ作成が失敗する
```bash
# リポジトリ権限確認
gh repo view smkwlab/{student-repo}

# 手動ブランチ作成
git checkout -b {next-branch} {base-branch}
git push -u origin {next-branch}
```

#### 複数教員での競合
- [PR-REVIEW-GUIDE.md](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/PR-REVIEW-GUIDE.md) の「複数教員での添削」を参照

## 🤝 コントリビューション

改善提案・バグ報告は Issues または Pull Request でお知らせください。

### 開発・テスト環境

```bash
# テスト用リポジトリ作成（create-repo/main.sh を直接実行）
cd create-repo && DOC_TYPE=thesis ./main.sh k21rs999

# 動作確認
cd k21rs999-sotsuron
# 通常の学生ワークフローをテスト
```

### YAML ワークフロー検証

GitHub Actions ワークフローの品質を保つため、YAML 検証ツールを導入しています。

```bash
# 必要ツールのインストール
pip install yamllint
brew install actionlint  # macOS
# or: bash <(curl https://raw.githubusercontent.com/rhysd/actionlint/main/scripts/download-actionlint.bash)

# ローカル検証実行
make validate-yaml
# または直接実行
./scripts/validate-yaml.sh

# 個別ツール実行
yamllint -c .yamllint.yml .
actionlint
```

**検証内容:**
- **yamllint**: YAML 構文チェック、フォーマット統一
- **actionlint**: GitHub Actions 専用検証、型チェック、依存関係チェック
- **自動実行**: Push/PR 時に CI で検証

**設定ファイル:**
- `.yamllint.yml`: yamllint 設定（行長120文字、truthy値許可など）
- `.github/workflows/yaml-validation.yml`: CI 検証ワークフロー

## 📊 使用状況・統計

```bash
# 作成済みリポジトリ一覧
gh repo list smkwlab --topic thesis

# アクティブなPR確認
gh search prs --owner smkwlab --state open
```

## 📞 サポート

質問・問題がある場合:

1. **ドキュメント確認**: 該当するガイドを参照
2. **Issues作成**: このリポジトリでIssue作成
3. **ML連絡**: smkwlabML で質問共有

## 📝 更新履歴

- **v2.0.0** (2024/06): GitHub Actions完全自動化
- **v1.5.0** (2024/05): 概要ワークフロー追加
- **v1.0.0** (2024/04): 基本システム完成

## 📄 ライセンス

MIT License - 教育・研究目的での自由な利用を推奨

---

**関連リポジトリ**:
- [sotsuron-template](https://github.com/smkwlab/sotsuron-template) - 論文テンプレート
- [latex-environment](https://github.com/smkwlab/latex-environment) - LaTeX開発環境
