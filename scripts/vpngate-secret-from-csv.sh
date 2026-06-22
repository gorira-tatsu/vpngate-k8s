#!/usr/bin/env bash
set -euo pipefail

namespace=egress-system
name=vpngate-openvpn
country=
host=
random=false
retries=3

usage() {
  cat <<'USAGE'
Usage:
  vpngate-secret-from-csv.sh [--namespace NAMESPACE] [--name SECRET] [--country CC] [--host HOSTNAME] [--random] [--retries N]

Create a Kubernetes Secret containing a VPNGate OpenVPN config.

Filters:
  --country CC   Match VPNGate country short code, for example JP or US.
  --host HOST    Match VPNGate DDNS hostname.

Options:
  --random      Randomly select from matching VPNGate entries.
  --retries N   Retry VPNGate API download. Default: 3.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace)
      namespace="$2"
      shift 2
      ;;
    --name)
      name="$2"
      shift 2
      ;;
    --country)
      country="$2"
      shift 2
      ;;
    --host)
      host="$2"
      shift 2
      ;;
    --random)
      random=true
      shift
      ;;
    --retries)
      retries="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "awk is required" >&2; exit 1; }
command -v base64 >/dev/null 2>&1 || { echo "base64 is required" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "kubectl is required" >&2; exit 1; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

curl -fsSL --retry "$retries" --retry-delay 2 --retry-all-errors "https://www.vpngate.net/api/iphone/" > "$tmp"

encoded="$(
  awk -F, -v country="$country" -v host="$host" -v random="$random" '
    BEGIN { srand() }
    /^#/ { next }
    NF < 15 { next }
    country != "" && $7 != country { next }
    host != "" && $1 != host { next }
    random != "true" { print $15; exit }
    {
      count++
      configs[count] = $15
    }
    END {
      if (random == "true" && count > 0) {
        selected_index = int(rand() * count) + 1
        print configs[selected_index]
      }
    }
  ' "$tmp"
)"

if [[ -z "$encoded" ]]; then
  echo "No VPNGate entry matched the requested filters." >&2
  exit 1
fi

decoded="$(
  printf '%s' "$encoded" |
    base64 -d |
    awk '!/^data-ciphers([[:space:]]|$)/ && !/^data-ciphers-fallback([[:space:]]|$)/'
)"

kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "$namespace" create secret generic "$name" \
  --from-literal=client.ovpn="$decoded" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created/updated secret $namespace/$name"
