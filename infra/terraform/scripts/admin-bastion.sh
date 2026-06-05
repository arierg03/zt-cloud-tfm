#!/bin/bash
set -euxo pipefail

mkdir -p /usr/local/bin

if command -v curl >/dev/null 2>&1; then
  curl -fsSL -o /usr/local/bin/kubectl https://s3.us-west-2.amazonaws.com/amazon-eks/1.35.3/2026-04-08/bin/linux/amd64/kubectl
else
  python3 -c 'import urllib.request; urllib.request.urlretrieve("https://s3.us-west-2.amazonaws.com/amazon-eks/1.35.3/2026-04-08/bin/linux/amd64/kubectl", "/usr/local/bin/kubectl")'
fi

chmod 0755 /usr/local/bin/kubectl
/usr/local/bin/kubectl version --client

curl -fsSL -o /tmp/helm-linux-amd64.tar.gz https://get.helm.sh/helm-v3.15.4-linux-amd64.tar.gz
tar -xzf /tmp/helm-linux-amd64.tar.gz -C /tmp
install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
/usr/local/bin/helm version --short
