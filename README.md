# vpngate-k8s

Kubernetes 上で、明示的に opt-in した Pod の出口を Tor または VPNGate(OpenVPN) 経由にするための Helm chart です。

この構成は CNI やノード全体のルーティングを書き換えません。対象 workload が `HTTP_PROXY` / `HTTPS_PROXY` / `ALL_PROXY` を `egress-plugin` Service に向けた場合だけ出口が変わります。学術・検証用途で、出口の選択と監査をしやすくするための最小構成です。

## 構成

- `charts/egress-plugin`: Tor / VPNGate 切り替え可能な Helm chart
- `scripts/vpngate-secret-from-csv.sh`: VPNGate CSV から `.ovpn` を取り出して Kubernetes Secret を作る補助スクリプト
- `examples/httpbin-check.yaml`: 出口 IP 確認用の opt-in Pod 例

## Tor で使う

```bash
helm install egress-plugin charts/egress-plugin \
  --namespace egress-system \
  --create-namespace \
  --set mode=tor
```

workload からは次のように参照します。

```yaml
env:
  - name: HTTP_PROXY
    value: http://egress-plugin.egress-system.svc.cluster.local:8118
  - name: HTTPS_PROXY
    value: http://egress-plugin.egress-system.svc.cluster.local:8118
  - name: ALL_PROXY
    value: socks5h://egress-plugin.egress-system.svc.cluster.local:9050
```

## VPNGate で使う

VPNGate は接続先ごとに出口 IP が変わるため、`.ovpn` を Secret 化してから chart に渡します。

```bash
scripts/vpngate-secret-from-csv.sh \
  --namespace egress-system \
  --country JP \
  --name vpngate-openvpn \
  --random
```

このスクリプトは、古い OpenVPN クライアントで起動エラーになる `data-ciphers` / `data-ciphers-fallback` 行を Secret 作成時に除去します。

生成された Secret を使って install します。

```bash
helm install egress-plugin charts/egress-plugin \
  --namespace egress-system \
  --create-namespace \
  --set mode=vpngate \
  --set vpngate.existingSecret=vpngate-openvpn
```

VPNGate モードは Pod のネットワーク namespace 内で OpenVPN を張り、その同じ namespace で HTTP proxy を動かします。そのため `NET_ADMIN` 権限が必要です。

OpenVPN の `redirect-gateway` でクラスタ内通信まで VPN 側に戻らないよう、標準設定では `10.0.0.0/8`、`172.16.0.0/12`、`192.168.0.0/16` を元のクラスタ gateway に固定します。

## IP ローリング

`rotation.enabled=true` を指定すると、CronJob が定期的に出口をローリングします。

Tor モードでは Deployment を restart して Tor proxy の回路を作り直します。

```bash
helm upgrade --install egress-plugin charts/egress-plugin \
  --namespace egress-system \
  --create-namespace \
  --set mode=tor \
  --set rotation.enabled=true \
  --set 'rotation.schedule=0 */6 * * *'
```

VPNGate モードでは CronJob が VPNGate CSV から接続先を選び直し、Secret を更新して Deployment を restart します。

```bash
helm upgrade --install egress-plugin charts/egress-plugin \
  --namespace egress-system \
  --create-namespace \
  --set mode=vpngate \
  --set vpngate.existingSecret=vpngate-openvpn \
  --set rotation.enabled=true \
  --set rotation.vpngate.country=JP \
  --set rotation.vpngate.random=true \
  --set 'rotation.schedule=0 */6 * * *'
```

ローテーション Job は `backoffLimit` と `activeDeadlineSeconds` を持ち、VPNGate API のダウンロードにも retry をかけます。選ばれた VPNGate ホストと更新時刻は Secret annotation に記録されます。

```bash
kubectl -n egress-system get secret vpngate-openvpn \
  -o jsonpath='{.metadata.annotations.vpngate-k8s\.local/vpngate-host}{"\n"}{.metadata.annotations.vpngate-k8s\.local/rotated-at}{"\n"}'
```

手動で即時ローテーションしたい場合は CronJob から Job を作れます。

```bash
kubectl -n egress-system create job --from=cronjob/egress-plugin-rotator egress-plugin-rotate-now
```

## ヘルスチェック（自動ローテーション）

`rotation.schedule` を待たずに、プロキシが壊れた時点でローテーションさせたい場合は `healthcheck.enabled=true` を指定します。CronJob が `healthcheck.validationUrls` を定期的に proxy 経由で取得し、`healthcheck.failuresAllowed` 回以上失敗したら rotator の `rotate.sh` をそのまま exec します。

`validationUrls` は**実際にアプリが叩く URL** にしてください。プロキシが生きていても origin 側でブロックされていれば意味がなく、`example.com` だけでは検知できません。

結果は status ConfigMap に入ります。

```bash
kubectl -n egress-system get cm egress-plugin-status -o jsonpath='{.data.status}{" "}{.data.vpngate_host}{"\n"}'
kubectl -n egress-system get cm egress-plugin-healthcheck-status -o jsonpath='{.data.status}{" "}{.data.message}{"\n"}'
```

## 消費側リポジトリでやること

egress-plugin 一式（Deployment / rotator / healthcheck / status RBAC）はこの chart が所有します。プロキシを使う側のリポジトリに置くのは、**自分の ServiceAccount を束ねる RoleBinding だけ**です。chart は消費側の SA を知らないため、ここは chart 側では作れません。

```yaml
# 例: 消費側リポジトリの manifest
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: myapp-egress-status-reader
  namespace: egress-system
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: egress-plugin-status-reader  # chart が作る
subjects:
  - kind: ServiceAccount
    name: myapp
    namespace: myapp
```

rotate.sh や healthcheck の manifest を消費側リポジトリにコピーして `kubectl apply` しないでください。chart が同じオブジェクトを所有しているため、`helm upgrade` で黙って巻き戻ります（実際に一度そうなりかけました）。挙動を変えたいときは values で調整します。

## 出口確認

```bash
kubectl apply -n default -f examples/httpbin-check.yaml
kubectl logs -n default job/egress-httpbin-check
```

## 注意

- この chart は明示的な proxy opt-in 用です。既存 Pod の全通信を透過的に匿名化する用途ではありません。
- `.ovpn`、kubeconfig、Secret manifest、証明書、秘密鍵はリポジトリに commit しないでください。VPNGate 設定は Kubernetes Secret としてクラスタ内で管理します。
- VPNGate は公開中継サーバーに依存します。安定性、帯域、利用規約、研究倫理の確認は利用側で行ってください。
- Tor / VPN 経由の通信でも、アプリケーション層の識別子や DNS の扱いによって出口制御の意味が変わります。`ALL_PROXY=socks5h://...` のようにリモート DNS を使う設定を優先してください。
- 高頻度なローテーションは公開中継や Tor ネットワークへの負荷になります。研究用途でも、必要最小限の頻度と明示的な監査ログを前提にしてください。

## 今後あるとよい機能

- 出口 IP を定期観測する health Job とメトリクス出力
- 許可された namespace / ServiceAccount だけが proxy を使える NetworkPolicy
- VPNGate 候補の品質スコアリングと失敗ホストの一時除外
- Tor control port を持つ専用イメージへの切り替えによる restart なしの Newnym
- ローテーション履歴の ConfigMap / 外部ログ保存
