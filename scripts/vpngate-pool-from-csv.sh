#!/usr/bin/env bash
set -euo pipefail

namespace=egress-system
prefix=jprs-vpngate
country=JP
count=30
authorized_until=
retries=3

usage() {
  cat <<'USAGE'
Usage:
  vpngate-pool-from-csv.sh [--namespace N] [--prefix NAME] [--country CC]
                            [--count N] --authorized-until RFC3339

Create a pool of unique VPNGate OpenVPN Secrets from one API snapshot.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --country) country="$2"; shift 2 ;;
    --count) count="$2"; shift 2 ;;
    --authorized-until) authorized_until="$2"; shift 2 ;;
    --retries) retries="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > 30 )); then
  echo "--count must be between 1 and 30" >&2
  exit 2
fi
[[ -n "$authorized_until" ]] || {
  echo "--authorized-until is required" >&2
  exit 2
}

for command in curl awk base64 date kubectl shuf; do
  command -v "$command" >/dev/null 2>&1 || { echo "$command is required" >&2; exit 1; }
done

if ! [[ "$authorized_until" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] ||
   ! authorized_epoch="$(date -u -d "$authorized_until" +%s 2>/dev/null)"; then
  echo "--authorized-until must be a valid RFC3339 timestamp" >&2
  exit 2
fi
if (( authorized_epoch <= $(date -u +%s) )); then
  echo "--authorized-until must be in the future" >&2
  exit 2
fi

tmp_csv="$(mktemp)"
tmp_selected="$(mktemp)"
tmp_config="$(mktemp)"
trap 'rm -f "$tmp_csv" "$tmp_selected" "$tmp_config"' EXIT

curl -fsSL --retry "$retries" --retry-delay 2 --retry-all-errors \
  "https://www.vpngate.net/api/iphone/" > "$tmp_csv"

awk -F, -v country="$country" '
  /^#/ || NF < 15 { next }
  $7 == country && !seen[$1]++ { print $1 "\t" $15 }
' "$tmp_csv" | shuf -n "$count" > "$tmp_selected"

selected_count="$(wc -l < "$tmp_selected")"
if (( selected_count != count )); then
  echo "Requested $count unique endpoints, but only found $selected_count for $country" >&2
  exit 1
fi

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -

index=0
while IFS=$'\t' read -r host encoded; do
  name="$(printf '%s-%02d' "$prefix" "$index")"
  printf '%s' "$encoded" |
    base64 -d |
    awk '!/^data-ciphers([[:space:]]|$)/ && !/^data-ciphers-fallback([[:space:]]|$)/' > "$tmp_config"
  kubectl -n "$namespace" create secret generic "$name" \
    --from-file=client.ovpn="$tmp_config" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$namespace" annotate secret "$name" --overwrite \
    "vpngate-k8s.local/vpngate-host=$host" \
    "vpngate-k8s.local/pool-index=$index" \
    "vpngate-k8s.local/authorized-until=$authorized_until" >/dev/null
  echo "Prepared $namespace/$name ($host)"
  index=$((index + 1))
done < "$tmp_selected"
