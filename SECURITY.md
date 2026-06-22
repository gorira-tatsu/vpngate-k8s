# Security

## Sensitive data

Do not commit kubeconfigs, `.ovpn` files, Kubernetes Secret manifests, certificates, private keys, or rendered Helm output that contains Secret data.

VPNGate OpenVPN configs should be generated into a Kubernetes Secret at deploy time:

```bash
scripts/vpngate-secret-from-csv.sh --namespace egress-system --country JP --name vpngate-openvpn --random
```

When checking rotation status, read only the annotations rather than dumping the whole Secret:

```bash
kubectl -n egress-system get secret vpngate-openvpn \
  -o jsonpath='{.metadata.annotations.vpngate-k8s\.local/vpngate-host}{"\n"}{.metadata.annotations.vpngate-k8s\.local/rotated-at}{"\n"}'
```

## Reporting

For security issues, open a private report with the repository owner. Do not include live credentials, private keys, or full VPN profiles in public issues.
