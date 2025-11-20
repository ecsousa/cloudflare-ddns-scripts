#!/usr/bin/env bash

# Update a Cloudflare A record with the machine's current local IP (default route).
# Requirements:
#   - CLOUDFLARE_API_TOKEN environment variable must be set with a token that can read/write DNS.
#   - Optional: CLOUDFLARE_ZONE_ID or CLOUDFLARE_ZONE_NAME to avoid guessing the zone.
# Usage:
#   ./update_cloudflare_dns.sh <hostname>

set -euo pipefail

abort() {
  echo "error: $*" >&2
  exit 1
}

command -v jq >/dev/null 2>&1 || abort "jq is required but not found in PATH"

if [[ $# -ne 1 ]]; then
  abort "usage: $0 <hostname>"
fi

hostname=$1
token=${CLOUDFLARE_API_TOKEN:-}

[[ -n $token ]] || abort "CLOUDFLARE_API_TOKEN is not set"

default_interface() {
  if command -v ip >/dev/null 2>&1; then
    ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1
  elif [[ $(uname -s) == "Darwin" ]]; then
    route -n get default 2>/dev/null | awk '/interface:/{print $2}' | head -n1
  else
    return 1
  fi
}

local_ipv4() {
  local iface
  iface=$(default_interface) || true

  [[ -n $iface ]] || abort "could not determine default network interface"

  if command -v ip >/dev/null 2>&1; then
    ip -4 addr show dev "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1
  else
    ifconfig "$iface" 2>/dev/null | awk '/inet / {print $2}' | head -n1
  fi
}

guess_zone_name() {
  local host=$1
  local parts i len

  if [[ -n ${CLOUDFLARE_ZONE_NAME:-} ]]; then
    echo "$CLOUDFLARE_ZONE_NAME"
    return
  fi

  IFS='.' read -r -a parts <<<"$host"
  len=${#parts[@]}
  if (( len < 2 )); then
    return 1
  fi

  echo "${parts[len-2]}.${parts[len-1]}"
}

fetch_zone_id() {
  local zone_name=$1
  local zone_id
  zone_id=$(curl -sS -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    "https://api.cloudflare.com/client/v4/zones?name=${zone_name}&status=active" |
    jq -r 'if .success and (.result | length > 0) then .result[0].id else empty end')

  [[ -n $zone_id ]] || return 1
  echo "$zone_id"
}

parse_record() {
  jq -r '
    if .success and (.result | length > 0) then
      "\(.result[0].id) \(.result[0].content) \(.result[0].proxied // false)"
    else
      empty
    end
  '
}

local_ip=$(local_ipv4)
[[ -n $local_ip ]] || abort "could not determine local IPv4 address"

zone_id=${CLOUDFLARE_ZONE_ID:-}
if [[ -z $zone_id ]]; then
  zone_name=$(guess_zone_name "$hostname") || abort "could not derive zone from hostname; set CLOUDFLARE_ZONE_NAME or CLOUDFLARE_ZONE_ID"
  zone_id=$(fetch_zone_id "$zone_name") || abort "could not fetch zone id for $zone_name"
fi

record_lookup=$(curl -sS -H "Authorization: Bearer $token" \
  -H "Content-Type: application/json" \
  "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=A&name=${hostname}")

read -r record_id current_cloudflare_ip record_proxied <<<"$(echo "$record_lookup" | parse_record || true)"
record_proxied=${record_proxied:-false}

if [[ -n ${current_cloudflare_ip:-} && $current_cloudflare_ip == "$local_ip" ]]; then
  echo "Cloudflare DNS for ${hostname} already set to ${local_ip}; no update needed."
  exit 0
fi

payload=$(cat <<EOF
{
  "type": "A",
  "name": "${hostname}",
  "content": "${local_ip}",
  "ttl": 60,
  "proxied": ${record_proxied}
}
EOF
)

if [[ -n ${record_id:-} ]]; then
  echo "Updating ${hostname}: ${current_cloudflare_ip:-<none>} -> ${local_ip}"
  update_response=$(curl -sS -X PUT \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}")
else
  echo "Creating A record for ${hostname} -> ${local_ip}"
  update_response=$(curl -sS -X POST \
    -H "Authorization: Bearer $token" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records")
fi

update_result=$(echo "$update_response" | jq -r '
  if .success then
    "ok Cloudflare record updated successfully."
  else
    "err " + (([.errors[]?.message] | join("; ") | select(length > 0)) // "unknown error")
  end
' 2>/dev/null || echo "err could not parse Cloudflare response")

if [[ $update_result == ok* ]]; then
  echo "${update_result#ok }"
else
  echo "Cloudflare API call failed: ${update_result#err }" >&2
  exit 1
fi
