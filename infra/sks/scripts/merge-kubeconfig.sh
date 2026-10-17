#!/usr/bin/env bash
set -euo pipefail

NAME=edth-sks
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="${KUBECONFIG:-$HOME/.kube/config}"
TARGET="${TARGET%%:*}"

umask 077
tmp="$(mktemp)"
merged="$(mktemp)"
trap 'rm -f "$tmp" "$merged"' EXIT

tofu -chdir="$TF_DIR" output -raw kubeconfig > "$tmp"

ctx="$(kubectl --kubeconfig "$tmp" config current-context)"
cluster="$(kubectl --kubeconfig "$tmp" config view -o jsonpath="{.contexts[?(@.name=='$ctx')].context.cluster}")"
user="$(kubectl --kubeconfig "$tmp" config view -o jsonpath="{.contexts[?(@.name=='$ctx')].context.user}")"
sed -i \
  -e "s|^\(\s*cluster:\s*\)$cluster\s*\$|\1$NAME|" \
  -e "s|^\(\s*user:\s*\)$user\s*\$|\1$NAME|" \
  -e "s|^\(\s*-\?\s*name:\s*\)$cluster\s*\$|\1$NAME|" \
  -e "s|^\(\s*-\?\s*name:\s*\)$user\s*\$|\1$NAME|" \
  -e "s|^\(\s*-\?\s*name:\s*\)$ctx\s*\$|\1$NAME|" \
  -e "s|^\(current-context:\s*\).*\$|\1$NAME|" \
  "$tmp"

[ -f "$TARGET" ] && cp -p "$TARGET" "$TARGET.bak"
KUBECONFIG="$TARGET:$tmp" kubectl config view --flatten > "$merged"
mv "$merged" "$TARGET"
chmod 600 "$TARGET"

kubectl --kubeconfig "$TARGET" config use-context "$NAME"
