#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

users_file=apps/emqx/emqx-users.sops.yaml

new_password() {
  head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32
}

add_user() {
  local user=$1 password=$2 csv
  csv=$(sops decrypt --extract '["data"]["users.csv"]' "$users_file" | base64 -d | grep -v "^${user}," || true)
  csv=$(printf '%s\n%s,%s,false\n' "$csv" "$user" "$password" | sed '/^$/d')
  sops set "$users_file" '["data"]["users.csv"]' "\"$(printf '%s\n' "$csv" | base64 -w0)\""
}

write_secret() {
  local path=$1 namespace=$2 name=$3
  shift 3
  kubectl create secret generic "$name" --namespace "$namespace" --dry-run=client -o yaml "$@" \
    | sops encrypt --filename-override "$path" /dev/stdin > "$path"
}

grafana_password=$(new_password)
fusion_password=$(new_password)

add_user grafana "$grafana_password"
add_user fusion "$fusion_password"
write_secret apps/grafana/grafana-mqtt.sops.yaml grafana grafana-mqtt \
  --from-file=password=<(printf %s "$grafana_password")
write_secret apps/miget/fusion-mqtt.sops.yaml miget fusion-mqtt \
  --from-literal=MQTT_USERNAME=fusion \
  --from-file=MQTT_PASSWORD=<(printf %s "$fusion_password")

echo "users.csv now has: $(sops decrypt --extract '["data"]["users.csv"]' "$users_file" | base64 -d | cut -d, -f1 | paste -sd' ')"
echo "wrote apps/grafana/grafana-mqtt.sops.yaml and apps/miget/fusion-mqtt.sops.yaml"
