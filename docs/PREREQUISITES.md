# リポジトリ作成の前提条件

リポジトリ作成スクリプト (`setup.sh`) を実行する前に用意しておくものをまとめています。
文書の種類（卒業論文・修士論文、情報科学演習レポート、学会ポスター、週報、卒業論文調査報告、
汎用 LaTeX）によらず共通です。

## 必要なもの

1. **GitHub アカウント** — 所属研究室の organization への招待が届いていれば受諾しておく
2. **Docker Desktop** — LaTeX 環境の実行に必要
3. **GitHub Desktop** — リポジトリの管理・同期に必要（リポジトリを作成した後に使う）
4. **GitHub CLI (gh)** — リポジトリ作成スクリプトの実行に必要

gh のインストールは OS によって異なります。Windows では WSL の準備も必要なので、
以下の該当する節を参照してください。

## macOS での準備

Homebrew を使用して gh をインストールします。

```bash
brew install gh
```

## Windows での準備

Windows では、以下の操作をすべて WSL (Ubuntu) の中で実行してください。

### 1. WSL を用意する

WSL が入っていなければ、PowerShell で次を実行します。

```powershell
wsl --install
```

**バージョンは指定しないでください**（`-d Ubuntu-24.04` のような書き方をしない）。
指定しなければ、その時点で最新の Ubuntu LTS が入ります。

すでに WSL を使っている場合はそのままで構いません。ただしサポートが終了した古い Ubuntu
では証明書の更新が止まっているため、リポジトリ作成スクリプトの取得そのものが次のような
エラーで失敗します。

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

この場合は Ubuntu を新しく入れ直すことになりますが、入れ直すと中に入れたものは消えるので、
自分で進めずに担当教員に相談してください。

### 2. Docker Desktop の WSL 統合を有効にする

Docker Desktop をインストールしただけでは、WSL の中から `docker` を使えません。
Docker Desktop の Settings → Resources → WSL Integration で、使っている Ubuntu を
有効にしてください。

有効になっていないと、リポジトリ作成スクリプトが次のメッセージで止まります。

```
❌ Dockerがインストールされていません
```

Docker Desktop は入っているので、このメッセージが案内するインストール手順に従っても
解決しません。確認するのは WSL 統合の設定です。

### 3. gh をインストールする

WSL (Ubuntu/Debian) 内で[公式リポジトリからインストール](https://github.com/cli/cli/blob/trunk/docs/install_linux.md#installing-gh-on-linux-and-bsd)します。

```bash
(type -p wget >/dev/null || (sudo apt update && sudo apt install wget -y)) \
	&& sudo mkdir -p -m 755 /etc/apt/keyrings \
	&& out=$(mktemp) && wget -nv -O$out https://cli.github.com/packages/githubcli-archive-keyring.gpg \
	&& cat $out | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
	&& sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
	&& sudo mkdir -p -m 755 /etc/apt/sources.list.d \
	&& echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null \
	&& sudo apt update \
	&& sudo apt install gh -y
```

## gh の認証

OS を問わず、インストール後に認証を済ませておきます。

```bash
gh auth login
```

1. `GitHub.com` を選択
2. `HTTPS` を選択
3. `Login with a web browser` を選択
4. 表示されたワンタイムコードをコピー
5. ブラウザが自動で開くので、コードを入力して認証完了

## 動作確認

```bash
gh --version
gh auth status
```

バージョン情報と `Logged in to github.com` が表示されれば、準備は完了です。

## 参考

- [GitHub CLI 公式サイト](https://cli.github.com/)
- [GitHub CLI ドキュメント](https://cli.github.com/manual/)
