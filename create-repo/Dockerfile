FROM alpine:3.24.3@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a

# 必要なツールをインストール
# 注: 旧構成では nodejs/npm も入れていたが、これは #180 当時に aldc を npm 経由で
# インストールしていた名残。現在 aldc は curl+bash 実行に変わり、作成スクリプト群
# (setup.sh / main.sh / common-lib.sh) も aldc 本体も node を一切使わないため削除した（Issue #518）。
RUN apk add --no-cache \
    git \
    curl \
    bash \
    ca-certificates \
    unzip \
    jq

# GitHub CLI をインストール
RUN ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') && \
    LATEST_VERSION=$(curl -s https://api.github.com/repos/cli/cli/releases/latest | jq -r .tag_name | tr -d 'v') && \
    curl -fsSL "https://github.com/cli/cli/releases/latest/download/gh_${LATEST_VERSION}_linux_${ARCH}.tar.gz" \
    | tar -xz -C /tmp && \
    mv "/tmp/gh_${LATEST_VERSION}_linux_${ARCH}/bin/gh" /usr/local/bin/ && \
    rm -rf /tmp/gh_*

# 作業ディレクトリを先に設定
WORKDIR /workspace

# セットアップスクリプトをコピー
# 文書タイプは docker run -e DOC_TYPE=... で選択する（setup.sh が注入）。
# 注: 旧 Dockerfile-thesis/-ise が COPY していた protection-config.json は
# create-repo 内のどのスクリプトからも参照されていないため含めない（Issue #516）
COPY main.sh ./
COPY common-lib.sh ./
COPY templates/ ./templates/
COPY types/ ./types/
RUN chmod +x main.sh common-lib.sh

# Docker環境では手動ブラウザアクセスを前提
ENV DOCKER_ENV=true

# エントリーポイント
ENTRYPOINT ["./main.sh"]
