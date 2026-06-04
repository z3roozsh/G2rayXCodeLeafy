FROM debian:bookworm-slim

ARG XRAY_VERSION=v26.5.9

LABEL maintainer="G2rayXCodeLeafy" \
      description="Educational G2rayXCodeLeafy Codespaces environment"

RUN apt-get update && apt-get install -y --no-install-recommends \
        bash curl wget unzip ca-certificates sudo openssl uuid-runtime tmux tzdata \
        qrencode jq bc net-tools libcap2-bin iproute2 dnsutils \
        python3 python-is-python3 nodejs npm \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN wget -qO xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip" \
    && wget -qO xray.zip.dgst "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip.dgst" \
    && awk -F'= ' '/^SHA2-256=/{print $2 "  xray.zip"}' xray.zip.dgst | sha256sum -c - \
    && unzip -q xray.zip -d /tmp/xray-dir \
    && mv /tmp/xray-dir/xray /usr/local/bin/xray \
    && mv /tmp/xray-dir/*.dat /usr/local/bin/ \
    && chmod +x /usr/local/bin/xray \
    && rm -rf xray.zip xray.zip.dgst /tmp/xray-dir

EXPOSE 443
