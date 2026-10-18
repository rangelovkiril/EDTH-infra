#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

node=${1:?usage: scripts/video-token.sh <node-id> <ssh-target>}
target=${2:?usage: scripts/video-token.sh <node-id> <ssh-target>}
ssh_cmd=${SSH:-ssh}
manifest=apps/miget/relay-deployment.yaml

[[ $node =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { echo "bad node id: $node" >&2; exit 1; }
token=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
hash=$(printf %s "$token" | sha256sum | cut -d' ' -f1)

read -rsp "sudo password on ${target}: " sudo_password
echo
printf '%s\n%s\n' "$sudo_password" "$token" | $ssh_cmd "$target" '
  read -r S; read -r T
  printf "%s\n" "$S" | sudo -S -p "" -v
  sudo sed -i "/^VIDEO_TOKEN=/d" /etc/edth/node.env
  printf "VIDEO_TOKEN=%s\n" "$T" | sudo tee -a /etc/edth/node.env >/dev/null
  grep -q "^VIDEO_PUSH_URL=" /etc/edth/node.env 2>/dev/null || sudo grep -q "^VIDEO_PUSH_URL=" /etc/edth/node.env \
    || echo "VIDEO_PUSH_URL=https://video.rangelov.dev/push" | sudo tee -a /etc/edth/node.env >/dev/null
  sudo systemctl restart edth-node
'

python3 - "$manifest" "$node" "$hash" <<'PY'
import re, sys
path, node, digest = sys.argv[1:]
text = open(path).read()
match = re.search(r"(- name: PUSH_TOKENS\n\s+value: )(\S*)", text)
pairs = dict(p.split(":", 1) for p in match.group(2).strip('"').split(",") if ":" in p)
pairs[node] = digest
value = ",".join(f"{k}:{v}" for k, v in sorted(pairs.items()))
open(path, "w").write(text[: match.start(2)] + value + text[match.end(2):])
PY
echo "${target}: VIDEO_TOKEN set, node restarted; ${manifest} has the hash for ${node}: commit and push it"
