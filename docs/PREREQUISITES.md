# リポジトリ作成の前提条件

リポジトリ作成スクリプト (`setup.sh`) を実行する前に、PC の環境構築を済ませてください。
文書の種類（卒業論文・修士論文、情報科学演習レポート、学会ポスター、週報、卒業論文調査報告、
汎用 LaTeX）によらず共通です。

## 環境構築

[研究室の PC 環境セットアップ](https://www.nw.is.kyusan-u.ac.jp/pcenv/) に従ってください。
必要なもの（パッケージ管理ソフト・WSL と Ubuntu・Git・GitHub アカウント・GitHub Desktop・
Docker Desktop・VS Code・GitHub CLI）がすべて揃います。

まとめて入れるスクリプトも用意されています
（[一括インストール](https://www.nw.is.kyusan-u.ac.jp/pcenv/pcenv-setup-all.html)）。

## 確認

リポジトリを作る前に、以下が通ることを確認してください。
**Windows では WSL (Ubuntu) の中で実行します。**

```bash
gh --version      # GitHub CLI が入っているか
gh auth status    # 認証できているか（Logged in to github.com と出る）
docker info       # Docker が使えるか
```

3 つとも通れば、リポジトリを作成できます。

## うまくいかないとき

### `❌ Dockerがインストールされていません` で止まる（Windows）

Docker Desktop の WSL 統合が有効になっていません。**Docker Desktop は入っているので、
メッセージが案内するインストール手順では解決しません。**

[pcenv 9.4](https://www.nw.is.kyusan-u.ac.jp/pcenv/#94-docker-desktop-の-wsl-統合を確認するwindows-のみ)
のとおり、Settings → Resources → WSL Integration で Ubuntu を有効にしてください。

### `gh: command not found` になる（Windows）

Windows 側に入れた gh は WSL から見えません。
[pcenv 9.5.1](https://www.nw.is.kyusan-u.ac.jp/pcenv/#951-windows-の場合)
のとおり、Ubuntu の中にインストールしてください。

### `SSL certificate problem: unable to get local issuer certificate` で止まる（Windows）

WSL の Ubuntu が古く、サポートが終了している可能性があります。サポートが切れると証明書の
更新が止まるため、`setup.sh` の**取得そのもの**が失敗します。

この場合は新しい Ubuntu に移ることになりますが、手順を誤ると今の環境が失われるので、
自分で進めずに担当教員に相談してください。相談するときは、次の出力を一緒に伝えると話が早く
なります（PowerShell で実行します）。

```powershell
wsl --list --verbose
```
