#!/usr/bin/env bash
set -euo pipefail

namespace=egress-system
prefix=egress-jprs
secret_prefix=jprs-vpngate
count=30
chart="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/charts/egress-plugin"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) namespace="$2"; shift 2 ;;
    --prefix) prefix="$2"; shift 2 ;;
    --secret-prefix) secret_prefix="$2"; shift 2 ;;
    --count) count="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: deploy-jprs-relay-pool.sh [--namespace N] [--prefix NAME] [--secret-prefix NAME] [--count N]"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if ! [[ "$count" =~ ^[0-9]+$ ]] || (( count < 1 || count > 30 )); then
  echo "--count must be between 1 and 30" >&2
  exit 2
fi

command -v date >/dev/null 2>&1 || { echo "date is required" >&2; exit 1; }

for ((index = 0; index < count; index++)); do
  suffix="$(printf '%02d' "$index")"
  release="$prefix-$suffix"
  secret="$secret_prefix-$suffix"
  kubectl -n "$namespace" get secret "$secret" >/dev/null
  authorized_until="$(kubectl -n "$namespace" get secret "$secret" -o jsonpath='{.metadata.annotations.vpngate-k8s\.local/authorized-until}')"
  if [[ -z "$authorized_until" ]] ||
     ! authorized_epoch="$(date -u -d "$authorized_until" +%s 2>/dev/null)" ||
     (( authorized_epoch <= $(date -u +%s) )); then
    echo "$namespace/$secret has no valid future authorization deadline" >&2
    exit 1
  fi
  helm upgrade --install "$release" "$chart" \
    --namespace "$namespace" \
    --set-string "fullnameOverride=$release" \
    --set mode=vpngate \
    --set-string "vpngate.existingSecret=$secret" \
    --set vpngate.tcpRelay.enabled=true \
    --set-string vpngate.tcpRelay.upstreamHost=whois.jprs.jp \
    --set vpngate.tcpRelay.upstreamPort=43 \
    --set service.tcpRelayPort=9043 \
    --set rotation.enabled=false \
    --set healthcheck.enabled=false >/dev/null
  kubectl -n "$namespace" rollout status "deployment/$release" --timeout=5m >/dev/null
  echo "Deployed $namespace/$release"
done

kubectl -n "$namespace" wait --for=condition=available deployment \
  -l app.kubernetes.io/name=egress-plugin --timeout=10m
