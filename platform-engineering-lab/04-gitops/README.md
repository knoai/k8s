# 04 - GitOps 与持续交付

GitOps 是平台工程的执行引擎，将所有基础设施和应用配置的变更纳入版本控制，实现声明式、可审计、可回滚的交付。

---

## 4.1 GitOps 核心原则

1. **声明式配置**：系统状态由 Git 中的 YAML/JSON 描述
2. **版本控制**：所有变更都有 Git 历史，可审计、可回滚
3. **自动同步**：Git 变更自动应用到集群（Pull 模式）
4. **差异收敛**：实际状态偏离 Git 时，自动纠正（Self-healing）

```
Developer → Git Push → Git Repository → GitOps Agent → K8s Cluster
                                              ↑
                                         自动检测差异并同步
```

---

## 4.2 ArgoCD 深度实践

### 架构组件

```
┌─────────────────────────────────────────┐
│  ArgoCD API Server                      │
│  → Web UI / CLI / API                   │
├─────────────────────────────────────────┤
│  Repository Server                      │
│  → 拉取 Git 仓库，生成 K8s manifest     │
├─────────────────────────────────────────┤
│  Application Controller                 │
│  → 监控 Git 与集群差异，执行同步        │
├─────────────────────────────────────────┤
│  Redis / Dex (SSO) / PostgreSQL         │
└─────────────────────────────────────────┘
```

### 仓库结构设计

#### 方案 A：Mono-repo（推荐用于平台工程）

```
gitops-platform/
├── apps/                          # 业务应用
│   ├── team-alpha/
│   │   ├── payment-service/
│   │   │   ├── base/
│   │   │   │   ├── deployment.yaml
│   │   │   │   ├── service.yaml
│   │   │   │   └── kustomization.yaml
│   │   │   └── overlays/
│   │   │       ├── dev/
│   │   │       │   └── kustomization.yaml
│   │   │       ├── staging/
│   │   │       └── prod/
│   │   │           ├── kustomization.yaml
│   │   │           ├── hpa.yaml
│   │   │           └── pdb.yaml
│   │   └── order-service/
│   └── team-beta/
├── platform/                      # 平台组件
│   ├── ingress-nginx/
│   ├── cert-manager/
│   ├── kyverno/
│   ├── crossplane/
│   └── monitoring/
├── clusters/                      # 集群级配置
│   ├── eks-prod/
│   │   ├── applicationset.yaml
│   │   └── cluster-addons.yaml
│   ├── eks-staging/
│   └── aks-dev/
└── policies/                      # 全局策略
    └── deny-latest-tag.yaml
```

#### 方案 B：App-of-Apps 模式

```yaml
# bootstrap/app-of-apps.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/company/gitops-platform.git
    targetRevision: main
    path: clusters/eks-prod
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
```

### ApplicationSet：多集群/多租户分发

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-components
  namespace: argocd
spec:
  generators:
    # 矩阵生成器：集群 x 组件
    - matrix:
        generators:
          - list:
              elements:
                - cluster: eks-prod
                  url: https://eks-prod.api
                  env: production
                - cluster: eks-staging
                  url: https://eks-staging.api
                  env: staging
                - cluster: aks-dev
                  url: https://aks-dev.api
                  env: development
          - list:
              elements:
                - component: ingress-nginx
                  path: platform/ingress-nginx
                - component: cert-manager
                  path: platform/cert-manager
                - component: kyverno
                  path: platform/kyverno
                - component: monitoring
                  path: platform/monitoring
  template:
    metadata:
      name: '{{cluster}}-{{component}}'
      labels:
        environment: '{{env}}'
        managed-by: platform-team
    spec:
      project: platform
      source:
        repoURL: https://github.com/company/gitops-platform.git
        targetRevision: main
        path: '{{path}}'
        helm:
          valueFiles:
            - values-{{env}}.yaml
      destination:
        server: '{{url}}'
        namespace: '{{component}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - CreateNamespace=true
          - ServerSideApply=true
        retry:
          limit: 5
          backoff:
            duration: 5s
            factor: 2
            maxDuration: 3m
```

### 多源应用（Multiple Sources）

ArgoCD 2.6+ 支持从一个 Application 引用多个 Git 仓库或 Helm Chart：

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: payment-service
spec:
  project: default
  sources:
    # 源 1：基础 Helm Chart（平台团队维护）
    - repoURL: https://charts.company.io
      chart: microservice-base
      targetRevision: 1.2.3
      helm:
        valueFiles:
          - $values/k8s/values-base.yaml
    # 源 2：业务团队的自定义配置
    - repoURL: https://github.com/company/payment-service.git
      targetRevision: HEAD
      ref: values
  destination:
    server: https://kubernetes.default.svc
    namespace: team-alpha
```

### 渐进交付（Argo Rollouts）

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: payment-service
spec:
  replicas: 10
  strategy:
    canary:
      steps:
        - setWeight: 10
        - pause: {duration: 10m}
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 50
        - pause: {duration: 10m}
        - analysis:
            templates:
              - templateName: success-rate
        - setWeight: 100
      analysis:
        startingStep: 2
        args:
          - name: service-name
            value: payment-service
---
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  args:
    - name: service-name
  metrics:
    - name: success-rate
      interval: 1m
      successCondition: result[0] >= 0.99
      provider:
        prometheus:
          address: http://prometheus:9090
          query: |
            sum(rate(http_requests_total{service="{{args.service-name}}",status=~"2.."}[1m]))
            /
            sum(rate(http_requests_total{service="{{args.service-name}}"}[1m]))
```

---

## 4.3 Flux（CNCF 毕业项目）

Flux 是 ArgoCD 的主要替代方案，与 GitHub Actions/Azure DevOps 集成更深。

```yaml
# GitRepository 源
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: platform-repo
  namespace: flux-system
spec:
  interval: 1m
  url: https://github.com/company/gitops-platform
  ref:
    branch: main
  secretRef:
    name: github-token
---
# Kustomization 同步
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: platform-apps
  namespace: flux-system
spec:
  interval: 10m
  path: ./clusters/eks-prod
  prune: true
  sourceRef:
    kind: GitRepository
    name: platform-repo
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: ingress-nginx-controller
      namespace: ingress-nginx
---
# ImagePolicy 自动更新镜像
apiVersion: image.toolkit.fluxcd.io/v1beta2
kind: ImagePolicy
metadata:
  name: payment-service
  namespace: flux-system
spec:
  imageRepositoryRef:
    name: payment-service
  policy:
    semver:
      range: 1.x.x
```

**ArgoCD vs Flux 选型建议**：

| 维度 | ArgoCD | Flux |
|------|--------|------|
| UI | ✅ 强大 Web UI | ❌ 无原生 UI（需 Weave GitOps） |
| 多集群 | ✅ 内置支持 | ✅ 配合 Fleet/Rancher |
| 镜像自动更新 | ❌ 需配合 CI 或 Image Updater | ✅ 原生 ImagePolicy |
| 生态插件 | ✅ 丰富 | ⚠️ 较少但增长快 |
| 企业支持 | Intuit + Akuity | Weaveworks + ControlPlane |
| 适合场景 | 需要 UI、多团队 | GitOps 纯命令行、自动镜像更新 |

---

## 4.4 密钥管理

GitOps 的核心挑战：敏感信息不能存入 Git。

### 方案 A：Sealed Secrets（Bitnami）

```bash
# 1. 安装 kubeseal CLI 和控制器
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.2/controller.yaml

# 2. 加密 Secret
kubectl create secret generic db-password \
  --from-literal=password=my-secret-password \
  --dry-run=client -o yaml | \
  kubeseal --controller-namespace=kube-system \
           --controller-name=sealed-secrets \
           --format yaml > sealed-db-password.yaml

# 3. 提交 sealed-db-password.yaml 到 Git（安全）
# 4. 控制器自动解密为普通 Secret
```

### 方案 B：External Secrets Operator（ESO）

```yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: us-east-1
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets-sa
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-password
  namespace: team-alpha
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: aws-secrets-manager
  target:
    name: db-password
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: production/payment-db
        property: password
```

**方案对比**：

| 方案 | 原理 | 优点 | 缺点 |
|------|------|------|------|
| Sealed Secrets | 非对称加密 | 完全离线，不依赖外部服务 | 密钥轮换复杂 |
| External Secrets | 引用外部 KMS | 集中管理，自动轮换 | 依赖外部服务可用性 |
| SOPS + Age | 对称加密 | 灵活，支持多 KMS | 需要 CI 集成加密步骤 |
| Vault + CSI | 动态凭据 | 最高安全性，自动过期 | 复杂度高 |

---

## 4.5 策略与治理

### ArgoCD 项目隔离

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: team-alpha
  namespace: argocd
spec:
  description: Team Alpha Project
  sourceRepos:
    - https://github.com/company/team-alpha-*
  destinations:
    - namespace: team-alpha-*
      server: https://kubernetes.default.svc
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota
  roles:
    - name: admin
      description: Team Alpha Admins
      policies:
        - p, proj:team-alpha:admin, applications, *, team-alpha/*, allow
      groups:
        - team-alpha@company.io
```

### 禁止直接修改集群

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  annotations:
    # 检测到手动修改时自动同步覆盖
    argocd.argoproj.io/sync-options: PrunePropagationPolicy=foreground
spec:
  syncPolicy:
    automated:
      prune: true
      selfHeal: true  # 关键：自动修复手动修改
      allowEmpty: false
```

---

## 4.6 灾难恢复

```bash
# 导出所有 ArgoCD 应用
argocd app list -o json > argocd-backup.json

# 备份 ArgoCD 本身（包括项目和配置）
kubectl get applications -n argocd -o yaml > apps-backup.yaml
kubectl get appprojects -n argocd -o yaml > projects-backup.yaml

# 在新集群恢复
kubectl apply -f projects-backup.yaml
kubectl apply -f apps-backup.yaml
```

---

## 最佳实践清单

- [ ] 使用 ApplicationSet 管理多集群/多环境
- [ ] 启用自动同步 + 自愈，防止配置漂移
- [ ] 敏感信息使用 Sealed Secrets 或 External Secrets，绝不入 Git
- [ ] 按团队划分 AppProject，实施 RBAC
- [ ] 生产环境使用 Argo Rollouts 实现金丝雀发布
- [ ] 配置同步失败告警（Slack/PagerDuty）
- [ ] 定期备份 ArgoCD 配置
- [ ] 使用 Helm + Kustomize 混合策略（Helm 打包，Kustomize 环境覆盖）

## GitOps 高级模式

### 多集群管理

**ApplicationSet + Cluster Generator**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: global-apps
  namespace: argocd
spec:
  generators:
  - clusters:
      selector:
        matchLabels:
          environment: production
      values:
        replicas: "3"
  - clusters:
      selector:
        matchLabels:
          environment: staging
      values:
        replicas: "1"
  template:
    metadata:
      name: '{{name}}-api'
    spec:
      project: default
      source:
        repoURL: https://github.com/org/gitops.git
        targetRevision: HEAD
        path: apps/api
        helm:
          values: |
            replicaCount: {{values.replicas}}
      destination:
        server: '{{server}}'
        namespace: api
```

**集群注册**:
```bash
# 将新集群注册到 ArgoCD
argocd cluster add <context-name> --name prod-us-west-2

# 为集群打标签
kubectl label secret -n argocd cluster-prod-us-west-2 environment=production region=us-west-2
```

### 渐进式交付（Argo Rollouts）

**金丝雀发布**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: api-rollout
spec:
  replicas: 10
  strategy:
    canary:
      steps:
      - setWeight: 10      # 10% 流量到新版本
      - pause: {duration: 10m}  # 观察 10 分钟
      - setWeight: 50      # 50% 流量
      - pause: {duration: 10m}
      - setWeight: 100     # 100% 流量
      analysis:
        templates:
        - templateName: success-rate
        args:
        - name: service-name
          value: api
```

**自动回滚条件**:
```yaml
apiVersion: argoproj.io/v1alpha1
kind: AnalysisTemplate
metadata:
  name: success-rate
spec:
  metrics:
  - name: success-rate
    interval: 5m
    successCondition: result[0] >= 0.95
    failureLimit: 3
    provider:
      prometheus:
        address: http://prometheus:9090
        query: |
          sum(rate(http_requests_total{service="api",status=~"2.."}[5m]))
          /
          sum(rate(http_requests_total{service="api"}[5m]))
```

### GitOps 与 CI/CD 的分工

**清晰边界**:

| 阶段 | CI (Build) | CD (GitOps) |
|------|-----------|-------------|
| 代码编译 | ✅ | ❌ |
| 单元测试 | ✅ | ❌ |
| 镜像构建 | ✅ | ❌ |
| 镜像推送 | ✅ | ❌ |
| 镜像签名 | ✅ | ❌ |
| 更新 Git 仓库 | ✅ (Bot Commit) | ❌ |
| 同步到集群 | ❌ | ✅ |
| 健康检查 | ❌ | ✅ |
| 回滚 | ❌ | ✅ |
| 配置漂移检测 | ❌ | ✅ |

**CI 更新 Git 仓库的模式**:
```bash
# CI 构建完成后，自动更新 GitOps 仓库中的镜像标签
# 使用 GitHub Actions + kustomize

# .github/workflows/deploy.yml
- name: Update image tag
  run: |
    cd gitops-repo/overlays/staging
    kustomize edit set image api=myregistry/api:${{ github.sha }}
    git add .
    git commit -m "deploy: update api to ${{ github.sha }}"
    git push
```

## 面试常见问题补充

**Q: ArgoCD 和 Flux 怎么选？**

A: 对比:

| 特性 | ArgoCD | Flux |
|------|--------|------|
| UI | ✅ 功能丰富 | ❌ 无原生 UI |
| 多集群 | ✅ 原生支持 | ✅ 通过 Flux CLI |
| 渐进式交付 | ✅ Argo Rollouts | ❌ 需配合 Flagger |
| 镜像自动更新 | ❌ 需配合 CI | ✅ Flux Image Automation |
| 成熟度 | 极高（CNCF 毕业） | 高（CNCF 毕业） |
| 社区 | 极大 | 大 |

选择建议:
- 需要 UI 和渐进式交付 → ArgoCD
- 偏好纯 GitOps、无 UI、镜像自动更新 → Flux
- 两者都很优秀，选择团队更熟悉的一个

**Q: 如何处理 GitOps 中的 secrets？**

A: 三种主流方案:

1. **Sealed Secrets** (Bitnami):
   ```bash
   # 加密 secrets
   kubeseal --format yaml < secret.yaml > sealedsecret.yaml
   # sealedsecret.yaml 可以安全存入 Git
   # 只有集群中的 Sealed Secrets Controller 能解密
   ```
   优点: 完全 GitOps，无需外部依赖
   缺点: 密钥轮换复杂，需要管理公钥

2. **External Secrets Operator**:
   ```yaml
   apiVersion: external-secrets.io/v1beta1
   kind: ExternalSecret
   metadata:
     name: db-credentials
   spec:
     secretStoreRef:
       name: vault-backend
       kind: SecretStore
     target:
       name: db-credentials
     data:
     - secretKey: password
       remoteRef:
         key: secret/data/db
         property: password
   ```
   优点: 集中管理、自动轮换、多云支持
   缺点: 依赖 Vault/AWS Secrets Manager 等外部系统

3. **SOPS + Age/Mozilla SOPS**:
   ```bash
   # 加密
   sops --encrypt --in-place secret.yaml
   # 提交到 Git
   # 解密（CI/CD 或本地）
   sops --decrypt secret.yaml
   ```
   优点: 简单、开源、支持 YAML/JSON/ENV
   缺点: 密钥管理需要额外流程

推荐:
- 中小团队: Sealed Secrets
- 大型企业: External Secrets Operator + HashiCorp Vault
- 开源社区项目: SOPS + Age

