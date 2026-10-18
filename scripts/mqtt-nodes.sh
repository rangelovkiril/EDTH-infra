#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

rotate=0
[[ ${1:-} == --rotate ]] && { rotate=1; shift; }
[[ $# -ge 1 ]] || { echo "usage: scripts/mqtt-nodes.sh [--rotate] <ssh-target>..." >&2; exit 2; }
ssh_cmd=${SSH:-ssh}
users_file=apps/emqx/emqx-users.sops.yaml

csv=$(sops decrypt --extract '["data"]["users.csv"]' "$users_file" | base64 -d)
password=$(printf '%s\n' "$csv" | awk -F, '$1 == "node" {print $2}')
if [[ -z $password || $rotate == 1 ]]; then
  password=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
  csv=$(printf '%s\n%s,%s,false\n' "$(printf '%s\n' "$csv" | grep -v '^node,')" node "$password" | sed '/^$/d')
  sops set "$users_file" '["data"]["users.csv"]' "\"$(printf '%s\n' "$csv" | base64 -w0)\""
  echo "users.csv: user node has a new password; commit and push, then restart EMQX"
fi

read -rsp "sudo password on the Pis: " sudo_password
echo
for target in "$@"; do
  printf '%s\n%s\n' "$sudo_password" "$password" | $ssh_cmd "$target" '
    read -r S; read -r P
    printf "%s\n" "$S" | sudo -S -p "" -v
    sudo sed -i "/^DRY_RUN=/d;/^MQTT_/d;/^NODE_ID=/d;/^VIDEO_TOKEN=/d;/^# No broker configured/d;/^# Set MQTT_HOST/d" /etc/edth/node.env
    printf "MQTT_HOST=emqx.rangelov.dev\nMQTT_PORT=8883\nMQTT_TLS=1\nMQTT_USERNAME=node\nMQTT_PASSWORD=%s\n" "$P" \
      | sudo tee -a /etc/edth/node.env >/dev/null
    sudo grep -q "^VIDEO_PUSH_URL=" /etc/edth/node.env \
      || echo "VIDEO_PUSH_URL=https://video.rangelov.dev/push" | sudo tee -a /etc/edth/node.env >/dev/null
    sudo systemctl restart edth-node
    if systemctl is-active --quiet edth-fusion; then sudo systemctl restart edth-fusion; fi
  '
  echo "${target}: publishes as user node, named after its board serial"
done
