# リポジトリ作成の前提条件

リポジトリ作成スクリプト (`setup.sh`) を実行する前に用意しておくものをまとめています。
文書の種類（卒業論文・修士論文、情報科学演習レポート、学会ポスター、週報、卒業論文調査報告、
汎用 LaTeX）によらず共通です。

## リポジトリ作成に必要なもの

- **GitHub アカウント** — 持っていなければ [github.com](https://github.com/) で作成する。
  所属研究室の organization への招待が届いていれば受諾しておく
- **Docker Desktop** — LaTeX 環境の実行に必要
- **GitHub CLI (gh)** — リポジトリ作成スクリプトの実行に必要

Docker Desktop と gh の入れ方は OS によって違います。**以下は該当する節だけを読めば足ります。**

## 作成した後に必要なもの

**GitHub Desktop** — リポジトリのクローン・同期に使います。リポジトリ作成の時点では不要なので、
後から入れても構いません。[desktop.github.com](https://desktop.github.com/) から入れ、操作は
[GitHub Desktop 操作ガイド](https://github.com/smkwlab/latex-ecosystem/blob/main/docs/GITHUB-DESKTOP-GUIDE.md)
を参照してください。

## macOS での準備

[Homebrew](https://brew.sh/) で両方入ります。

```bash
brew install --cask docker-desktop
brew install gh
```

Homebrew を使わない場合は、Docker Desktop を
[www.docker.com](https://www.docker.com/products/docker-desktop/) から入れてください。

入れたら **Docker Desktop を起動しておいてください。** 起動していないと、リポジトリ作成
スクリプトが「❌ Dockerデーモンが起動していません」で止まります。

## Windows での準備

Windows では、gh のインストール以降の操作をすべて WSL (Ubuntu) の中で実行してください。

### 1. WSL を用意する

WSL が入っていなければ、PowerShell で次を実行します。

```powershell
wsl --install
```

**バージョンは指定しないでください**（`-d Ubuntu-24.04` のような書き方をしない）。
指定するとその版に固定されます。指定しなければ既定の Ubuntu（最新の LTS）が入ります。
コマンドの詳細は [Microsoft の公式手順](https://learn.microsoft.com/ja-jp/windows/wsl/install)
にあります。

すでに WSL を使っている場合はそのままで構いません。ただしサポートが終了した古い Ubuntu
では証明書の更新が止まっているため、リポジトリ作成スクリプトの取得そのものが次のような
エラーで失敗します。

```
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

この場合は新しい Ubuntu に移ることになりますが、手順を誤ると今の環境が失われるので、
自分で進めずに担当教員に相談してください。相談するときは、次の出力を一緒に伝えると話が早く
なります（PowerShell で実行します）。

```powershell
wsl --list --verbose
```

### 2. Docker Desktop を入れ、WSL 統合を有効にする

Docker Desktop は [www.docker.com](https://www.docker.com/products/docker-desktop/) から
入れてください。インストールしただけでは、WSL の中から `docker` を使えません。
Docker Desktop の Settings → Resources → WSL Integration で、使っている Ubuntu を
有効にして Apply を押してください。同じ手順は[公式ドキュメント](https://docs.docker.com/desktop/features/wsl/)にもあります。
Docker Desktop の更新でメニュー構成が変わることがあるので、見つからない場合はそちらを見てください。

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

ここから先は OS 共通です。上の「macOS での準備」または「Windows での準備」が終わったら、
認証を済ませておきます。

```bash
gh auth login
```

1. `GitHub.com` を選択
2. `HTTPS` を選択
3. `Login with a web browser` を選択
4. 表示されたワンタイムコードをコピー
5. ブラウザが自動で開くので、コードを入力して認証完了

## 動作確認

2 つに分けて確認します。まずインストールできているか。

```bash
gh --version
```

バージョン情報が表示されれば成功です。`command not found` になる場合は OS 別の節に戻って
ください。Windows では、WSL の中で実行しているかも確認してください（Windows 側に入れた gh
は WSL から見えません）。

次に認証できているか。

```bash
gh auth status
```

`Logged in to github.com` と表示されれば、準備は完了です。

## 参考

- [GitHub CLI 公式サイト](https://cli.github.com/)
- [GitHub CLI ドキュメント](https://cli.github.com/manual/)
