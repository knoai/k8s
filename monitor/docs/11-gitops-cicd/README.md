# GitOps 与监控即代码

> 将监控配置纳入 Git 版本控制，通过 ArgoCD/Flux 实现声明式交付，实现环境一致性和快速回滚。

---

## 1. 为什么监控即代码

| 传统方式 | 监控即代码 |
|----------|-----------|
| 手动点击配置 | Git 版本控制 |
| 环境差异大 | 所有环境一致 |
| 回滚困难 | `git revert` 一键回滚 |
| 变更无审计 | PR Review + 变更记录 |
| 难以复用 | 模板化、标准化 |

---

## 2. 目录结构

```
observability-gitops/
├── README.md
├── base/                           # 基础组件
│   ├── prometheus/
│   │   ├── kustomization.yaml
│   │   ├── prometheus.yaml         # Prometheus CRD
│   │   ├── alertmanager.yaml       # Alertmanager CRD
│   │   └── thanos-sidecar.yaml
│   ├── grafana/
│   │   ├── kustomization.yaml
│   │   ├── grafana.yaml            # Grafana CRD
│   │   ├── datasources.yaml        # 数据源 ConfigMap
│   │   └── dashboards/             # Dashboard JSON
│   ├── loki/
│   │   ├── kustomization.yaml
│   │   └── values.yaml             # Helm values
│   └── tempo/
│       ├── kustomization.yaml
│       └── values.yaml
│
├── overlays/                       # 环境覆盖
│   ├── production/
│   │   ├── kustomization.yaml
│   │   ├── prometheus-patch.yaml   # 生产环境特定配置
│   │   ├── grafana-patch.yaml
│   │   └── secrets/              # SealedSecrets
│   └── staging/
│       ├── kustomization.yaml
│       └── prometheus-patch.yaml
│
├── rules/                          # 告警规则
│   ├── kustomization.yaml
│   ├── infrastructure/             # 基础设施告警
│   │   ├── node-alerts.yaml
│   │   ├── pod-alerts.yaml
│   │   └── k8s-control-plane.yaml
│   ├── application/                # 应用告警
│   │   ├── http-alerts.yaml
│   │   ├── database-alerts.yaml
│   │   └── cache-alerts.yaml
│   └── business/                   # 业务告警
│       └── business-kpi.yaml
│
├── dashboards/                     # Dashboard 源码
│   ├── kustomization.yaml
│   ├── infrastructure/
│   │   ├── cluster-overview.json
│   │   └── node-detail.json
│   ├── application/
│   │   ├── service-red.json
│   │   └── jvm-monitoring.json
│   └── business/
│       └── conversion-funnel.json
│
├── recording-rules/                # 记录规则
│   ├── kustomization.yaml
│   ├── node-metrics.yaml
│   └── service-metrics.yaml
│
├── exporters/                      # Exporter 部署
│   ├── redis-exporter.yaml
│   ├── kafka-exporter.yaml
│   └── mysql-exporter.yaml
│
└── policies/                       # 网络策略
    └── network-policies.yaml
```

---

## 3. Kustomize 基础配置

### 3.1 Base 层

```yaml
# base/prometheus/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - prometheus.yaml
  - alertmanager.yaml

namespace: monitoring

commonLabels:
  app.kubernetes.io/part-of: observability
  app.kubernetes.io/managed-by: argocd
```

```yaml
# base/grafana/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - grafana.yaml

configMapGenerator:
  - name: grafana-datasources
    files:
      - datasources.yaml
  - name: grafana-dashboards
    files:
      - dashboards/cluster-overview.json
      - dashboards/node-detail.json
```

### 3.2 Overlay 层

```yaml
# overlays/production/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/prometheus
  - ../../base/grafana
  - ../../rules
  - ../../exporters

namespace: monitoring

namePrefix: prod-

commonLabels:
  environment: production

patches:
  - path: prometheus-patch.yaml
    target:
      kind: Prometheus
      name: prometheus
  - path: grafana-patch.yaml
    target:
      kind: Grafana
      name: grafana

secretGenerator:
  - name: alertmanager-config
    type: Opaque
    literals:
      - slack-webhook=https://hooks.slack.com/services/xxx
```

```yaml
# overlays/production/prometheus-patch.yaml
apiVersion: monitoring.coreos.com/v1
kind: Prometheus
metadata:
  name: prometheus
spec:
  replicas: 3                    # 生产 3 副本
  retention: 30d
  retentionSize: "100GB"
  resources:
    requests:
      memory: 8Gi
      cpu: "2"
    limits:
      memory: 32Gi
      cpu: "8"
  remoteWrite:
    - url: http://thanos-receive:19291/api/v1/receive
  storage:
    volumeClaimTemplate:
      spec:
        storageClassName: fast-ssd
        resources:
          requests:
            storage: 500Gi
```

---

## 4. ArgoCD 应用配置

```yaml
# argocd-applications.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: observability-production
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/your-org/observability-gitops.git
    targetRevision: main
    path: overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: monitoring
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

## 5. CI Pipeline（GitHub Actions）

```yaml
# .github/workflows/observability-ci.yaml
name: Observability CI

on:
  push:
    branches: [main]
    paths:
      - 'rules/**'
      - 'dashboards/**'
      - 'base/**'
      - 'overlays/**'
  pull_request:
    branches: [main]
    paths:
      - 'rules/**'
      - 'dashboards/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      # 1. 验证 YAML 语法
      - name: Validate YAML
        run: |
          pip install yamllint
          yamllint -c .yamllint rules/ base/ overlays/

      # 2. 验证 PrometheusRule
      - name: Validate PrometheusRules
        run: |
          docker run --rm -v "$PWD:/rules" \
            prom/prometheus:latest \
            promtool check rules /rules/rules/**/*.yaml

      # 3. 验证 Dashboard JSON
      - name: Validate Dashboards
        run: |
          for f in dashboards/**/*.json; do
            jq empty "$f" || exit 1
          done

      # 4. 测试 PromQL 查询
      - name: Test PromQL
        run: |
          docker run --rm -v "$PWD:/rules" \
            prom/prometheus:latest \
            promtool test rules /rules/rules/test.yaml

      # 5. Kustomize 构建验证
      - name: Build Kustomize
        run: |
          for overlay in overlays/*/; do
            echo "Building $overlay"
            kustomize build "$overlay" | kubectl apply --dry-run=client -f -
          done

      # 6. 检查高基数标签
      - name: Check High Cardinality
        run: |
          python scripts/check_cardinality.py rules/
```

---

## 6. PR Review Checklist

```markdown
## 监控变更 Review Checklist

### 告警规则
- [ ] 告警名称符合规范 `[<系统>] <症状> [<阈值>]`
- [ ] 有明确的 `for` 持续时间
- [ ] 包含 `summary` 和 `description` 注释
- [ ] 包含 Runbook 链接
- [ ] 已评估是否会引发告警风暴
- [ ] 已使用 Recording Rules 优化复杂查询

### Dashboard
- [ ] 命名符合规范 `[<环境>] <系统> - <用途>`
- [ ] 所有面板有单位和描述
- [ ] 使用了变量实现过滤
- [ ] 已导出 JSON 并格式化

### 指标
- [ ] 指标名符合命名规范
- [ ] 标签无高基数字段
- [ ] 已添加必要的通用标签

### 安全
- [ ] 无敏感信息硬编码
- [ ] Secret 使用 SealedSecret 或 Vault
```

---

## 7. 变更流程

```
开发者在本地修改
    ↓
git checkout -b feature/add-redis-alerts
    ↓
修改 rules/cache/redis-alerts.yaml
    ↓
本地验证: promtool check rules rules/cache/redis-alerts.yaml
    ↓
git commit -m "feat(alert): add redis memory and hit rate alerts"
git push origin feature/add-redis-alerts
    ↓
创建 PR → CI 自动验证
    ↓
Code Review（按 checklist）
    ↓
合并到 main → ArgoCD 自动同步到生产
    ↓
验证告警生效
```

---

## 8. SealedSecret（敏感信息加密）

```bash
# 安装 kubeseal
brew install kubeseal

# 加密 Secret
cat <<EOF | kubeseal --controller-namespace=kube-system --format yaml - > sealed-secret.yaml
apiVersion: v1
kind: Secret
metadata:
  name: alertmanager-config
  namespace: monitoring
type: Opaque
stringData:
  slack-webhook: https://hooks.slack.com/services/xxx
  pagerduty-key: xxx
EOF

# 提交加密后的文件到 Git
git add sealed-secret.yaml
git commit -m "chore(secret): add alertmanager config"
```

---

## 参考

- [Kustomize 文档](https://kubectl.docs.kubernetes.io/guides/introduction/kustomize/)
- [ArgoCD 文档](https://argo-cd.readthedocs.io/)
- [Prometheus promtool](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/)
- [Sealed Secrets](https://github.com/bitnami-labs/sealed-secrets)
