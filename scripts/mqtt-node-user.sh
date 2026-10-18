#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

node=${1:?usage: scripts/mqtt-node-user.sh <node-id> <ssh-target>}
target=${2:?usage: scripts/mqtt-node-user.sh <node-id> <ssh-target>}
ssh_cmd=${SSH:-ssh}
users_file=apps/emqx/emqx-users.sops.yaml

password=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
csv=$(sops decrypt --extract '["data"]["users.csv"]' "$users_file" | base64 -d | grep -v "^${node}," || true)
csv=$(printf '%s\n%s,%s,false\n' "$csv" "$node" "$password" | sed '/^$/d')
sops set "$users_file" '["data"]["users.csv"]' "\"$(printf '%s\n' "$csv" | base64 -w0)\""
echo "users.csv: ${node} has a new password"

[[ $target == - ]] && exit 0
read -rsp "sudo password on ${target}: " sudo_password
echo
printf '%s\n%s\n%s\n' "$sudo_password" "$password" "$node" | $ssh_cmd "$target" '
  read -r S; read -r P; read -r N
  printf "%s\n" "$S" | sudo -S -p "" -v
  sudo sed -i "/^DRY_RUN=/d;/^MQTT_/d;/^# No broker configured/d;/^# Set MQTT_HOST/d" /etc/edth/node.env
  printf "MQTT_HOST=emqx.rangelov.dev\nMQTT_PORT=8883\nMQTT_TLS=1\nMQTT_USERNAME=%s\nMQTT_PASSWORD=%s\n" "$N" "$P" \
    | sudo tee -a /etc/edth/node.env >/dev/null
  grep -q "^NODE_ID=${N}$" /etc/edth/node.env 2>/dev/null || sudo grep -q "^NODE_ID=${N}$" /etc/edth/node.env \
    || echo "warning: NODE_ID in /etc/edth/node.env is not ${N}"
'
echo "${target}: /etc/edth/node.env now publishes to emqx.rangelov.dev as ${node}"
