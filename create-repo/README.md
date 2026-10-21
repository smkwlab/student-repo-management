# 学生リポジトリ セットアップ

学生が自分の論文・レポートリポジトリを作成するためのDockerベースのツールです。

## 🎓 学生のみなさんへ

### 論文リポジトリ（卒業研究・修士論文）

**WSL上の bash または mac のターミナル上で以下の行を実行し、リポジトリを作成してください：**

```bash
bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

### 情報科学演習レポートリポジトリ

**情報科学演習I・II用のレポートリポジトリを作成する場合：**

```bash
STUDENT_ID=k21rs001 bash <(curl -fsSL https://repo-setup.smkwlab.net) ise
```

※ `k21rs001` の部分を自分の学籍番号に変更してください。

### 週報リポジトリ

**研究週報用のリポジトリを作成する場合：**

```bash
STUDENT_ID=k21rs001 bash <(curl -fsSL https://repo-setup.smkwlab.net) wr
```

**前提条件:** [docs/PREREQUISITES.md](../docs/PREREQUISITES.md)
（Windows は WSL の用意と Docker Desktop の WSL 統合が必要）

## 再現性・安全性（固定版の利用）

上記の `setup.sh` 実行コマンドは、短縮 URL から**最新の安定版**を取得します。
公開済みのリリースだけが配信されるため、未検証の変更がそのまま実行されることはありません。

ある時点の手順を厳密に再現したい場合は、**特定のバージョンに固定した版**を利用できます。
その場合だけ、短縮 URL の代わりにタグ付きの URL を指定してください（文書タイプ引数の
指定方法は同じで、以下は論文 `thesis` の例です）。

```bash
# 特定パッチに完全固定（厳密な再現が必要な場合）
bash <(curl -fsSL https://raw.githubusercontent.com/smkwlab/student-repo-management/v1.3.0/create-repo/setup.sh) thesis
```

> 短縮 URL は「最新の `v1` 系リリース」を配信します（`v1` は GitHub Actions の `@v4` と
> 同様の移動タグです）。完全に同一の内容を再現したい場合のみ、`v1.3.0` のように具体的な
> バージョンを指定してください。

> 変更するのは **URL の部分だけ**です。コマンド末尾の文書タイプ（上の例では `thesis`）や、
> 各コマンド先頭の環境変数（`STUDENT_ID=...` など）はそのまま残してください。

- スクリプトの内容は公開リポジトリでいつでも確認できます。実行前に内容を確認したい場合は、
  [v1 の setup.sh](https://github.com/smkwlab/student-repo-management/blob/v1/create-repo/setup.sh)
  を開いてください（短縮 URL が配信しているものと同じ内容です）。
- 利用可能なバージョン（`v1.3.0` などの具体的なリリース）は [Releases](https://github.com/smkwlab/student-repo-management/releases) を参照してください。なお `v1` はそれらの最新を指す移動タグ（ポインタ）であり、Releases 一覧には個別の項目としては現れません。
- リリース運用の詳細は [docs/RELEASE.md](../docs/RELEASE.md) を参照してください。

## よくある質問

### Q: Docker Desktop が起動していないエラー
A: タスクバー/メニューバーの Docker アイコンを確認し、起動してください。

### Q: ブラウザが開かない
A: 手動で https://github.com/login/device を開いて、表示されたワンタイムコードを入力してください。

### Q: リポジトリはどこに作成される？
A: デフォルトでは `smkwlab` 組織に作成されます。環境変数 `TARGET_ORG` で変更可能です。

### Q: 組織への権限がないエラー
A: 組織の管理者に招待を依頼するか、個人アカウントに作成してください：
```bash
TARGET_ORG=あなたのユーザー名 bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

### Q: エラーの詳細を確認したい
A: デバッグモードで実行すると詳細な情報が表示されます：

```bash
DEBUG=1 bash <(curl -fsSL https://repo-setup.smkwlab.net) thesis
```

## セットアップ後の作業

リポジトリ作成後の詳しい手順は、作成されたリポジトリ内の README を参照してください。

### 論文執筆の流れ
1. GitHub Desktop でリポジトリをクローン
2. VS Code で開く
3. DevContainer で LaTeX 環境を起動
4. 論文執筆開始！

詳細な手順: 作成されたリポジトリの README または [sotsuron-template の執筆ガイド](https://github.com/smkwlab/sotsuron-template/blob/main/WRITING-GUIDE.md) を参照

### ISEレポート作成の流れ
1. GitHub Desktop でリポジトリをクローン
2. VS Code で開く（DevContainer環境が自動起動）
3. `1st-draft` ブランチを作成
4. `index.html` を編集してレポート作成
5. Pull Request を作成・提出
6. レビューフィードバックを確認・対応

詳細な手順: [ise-report-template のREADME](https://github.com/smkwlab/ise-report-template/blob/main/.github/README.md) を参照

## 各リポジトリの特徴

| 種類 | 用途 | 期間 | 技術 | 学習目標 |
|------|------|------|------|----------|
| **論文** | 卒業研究・修士論文 | 1年 | LaTeX + textlint | 学術論文執筆 |
| **ISEレポート** | 情報科学演習I・II | 前期・後期 | HTML + textlint | Pull Request学習 |
| **週報** | 研究進捗報告 | 通年 | LaTeX + textlint | 継続的な報告 |
