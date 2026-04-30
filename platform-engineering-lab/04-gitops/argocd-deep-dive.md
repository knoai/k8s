# ArgoCD 深度实践：从安装到生产

> ArgoCD 是 K8s 原生声明式持续交付工具，支持 GitOps 工作流。
> 本节涵盖安装配置、应用管理、多集群部署、RBAC、监控告警和故障排查的完整生产实践。

---

## 一、ArgoCD 架构与核心概念

### 1.1 架构组件

```
ArgoCD 架构：

┌─────────────────────────────────────────┐
│  ArgoCD API Server (:8080, :443)        │
│   - REST API / gRPC / CLI               │
│   - Web UI                              │
│   - SSO 集成（OIDC, LDAP, SAML）        │
│   - Webhook 接收（Git 推送触发同步）     │
├─────────────────────────────────────────┤
│  ArgoCD Repository Server               │
│   - Git 仓库克隆和缓存                  │
│   - Helm / Kustomize / Jsonnet 渲染     │
│   - 生成 K8s manifest                   │
│   - 缓存渲染结果（默认 24h）            │
├─────────────────────────────────────────┤
│  ArgoCD Application Controller          │
│   - 监听 Application CR                 │
│   - 对比 Git 期望状态 vs 集群实际状态   │
│   - 自动/手动同步                       │
│   - 健康检查和自愈                      │
├─────────────────────────────────────────┤
│  ArgoCD Dex（可选）                     │
│   - OpenID Connect 代理                 │
│   - 支持多种身份提供商                  │
├─────────────────────────────────────────┤
│  Redis（缓存）                          │
│   - 会话缓存                            │
│   - 渲染结果缓存                        │
└─────────────────────────────────────────┘
              │
              │ Git 拉取
              ▼
        Git Repository
        (GitHub/GitLab/Bitbucket)
              │
              │ kubectl apply
              ▼
        K8s Cluster(s)
        (单集群或多集群)

核心概念：
  Application：ArgoCD 管理的应用单元，对应 Git 仓库中的一个路径
  Project：应用分组，用于权限隔离和资源限制
  Repository：Git 仓库配置，支持 HTTPS/SSH
  Cluster：目标 K8s 集群，ArgoCD 可管理多集群
  App of Apps：用一个 Application 管理多个 Application
  ApplicationSet：基于模板生成多个 Application（K8s 1.16+）
```

### 1.2 安装与基础配置

```bash
# === 安装 ArgoCD ===

# 方法 1：官方 YAML（推荐用于学习）
kubectl create namespace argocd
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 方法 2：Helm（推荐用于生产）
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd -n argocd --create-namespace \
  --set server.service.type=LoadBalancer \
  --set configs.secret.argocdServerAdminPassword='$2a$10$...'  # bcrypt hash

# 验证安装
kubectl get pods -n argocd
# NAME                                  READY   STATUS    RESTARTS   AGE
# argocd-application-controller-0       1/1     Running   0          2m
# argocd-dex-server-xxx                 1/1     Running   0          2m
# argocd-redis-xxx                      1/1     Running   0          2m
# argocd-repo-server-xxx                1/1     Running   0          2m
# argocd-server-xxx                     1/1     Running   0          2m

# 获取初始密码
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo

# 端口转发访问 UI
kubectl port-forward svc/argocd-server -n argocd 8080:443
# 访问 https://localhost:8080
# 用户名：admin
# 密码：上面获取的初始密码

# 安装 CLI
brew install argocd  # macOS
curl -sSL -o argocd https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
chmod +x argocd
sudo mv argocd /usr/local/bin/

# 登录
argocd login localhost:8080 --insecure
```

### 1.3 生产环境配置

```yaml
# argocd-cm.yaml - ArgoCD ConfigMap 生产配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  # 禁用匿名访问
  users.anonymous.enabled: "false"
  
  # URL 配置
  url: https://argocd.mycompany.com
  
  # 超时配置
  timeout.reconciliation: 180s        # 自动同步间隔
  timeout.hard.reconciliation: 0s     # 硬超时（0=禁用）
  
  # 资源定制（允许自定义 K8s 资源）
  resource.customizations: |
    argoproj.io/Application:
      health.lua: |
        hs = {}
        hs.status = "Progressing"
        hs.message = ""
        if obj.status ~= nil then
          if obj.status.health ~= nil then
            hs.status = obj.status.health.status
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            end
          end
        end
        return hs
  
  # 资源排除（不管理的资源）
  resource.exclusions: |
    - apiGroups:
      - cilium.io
      kinds:
      - CiliumIdentity
      clusters:
      - "*"
  
  # Kustomize 构建选项
  kustomize.buildOptions: "--enable-helm"
  
  # Helm 配置
  helm.repositories: |
    - url: https://charts.bitnami.com/bitnami
      name: bitnami
    - url: https://argoproj.github.io/argo-helm
      name: argo

---
# argocd-rbac-cm.yaml - RBAC 配置
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-rbac-cm
  namespace: argocd
data:
  policy.default: role:readonly
  policy.csv: |
    p, role:org-admin, applications, *, */*, allow
    p, role:org-admin, clusters, *, *, allow
    p, role:org-admin, repositories, *, *, allow
    p, role:org-admin, projects, *, *, allow
    
    p, role:team-alpha, applications, get, team-alpha/*, allow
    p, role:team-alpha, applications, sync, team-alpha/*, allow
    p, role:team-alpha, applications, override, team-alpha/*, deny
    p, role:team-alpha, applications, action/*, team-alpha/*, deny
    
    p, role:team-beta, applications, get, team-beta/*, allow
    p, role:team-beta, applications, sync, team-beta/*, allow
    
    g, team-alpha@mycompany.com, role:team-alpha
    g, team-beta@mycompany.com, role:team-beta
    g, platform-admin@mycompany.com, role:org-admin

---
# argocd-secret.yaml - 密码和密钥
apiVersion: v1
kind: Secret
metadata:
  name: argocd-secret
  namespace: argocd
type: Opaque
stringData:
  # 管理员密码（bcrypt hash）
  admin.password: '$2a$10$xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
  admin.passwordMtime: "2024-01-15T00:00:00Z"
  
  # Git 仓库凭证（SSH 私钥）
  repositories.mycompany-ssh: |
    url: git@github.com:mycompany/k8s-manifests.git
    sshPrivateKey: |
      -----BEGIN OPENSSH PRIVATE KEY-----
      xxxxxx
      -----END OPENSSH PRIVATE KEY-----
  
  # OAuth 配置
  oidc.authentik.clientSecret: xxxxxx
```

---

## 二、Application 管理

### 2.1 基础 Application

```yaml
# 基础 Application 示例
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
  # 最终化策略：防止资源被删除
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
    # Helm 特定配置
    helm:
      valueFiles:
        - values-production.yaml
      parameters:
        - name: replicaCount
          value: "3"
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated:
      prune: true              # 删除 Git 中不存在的资源
      selfHeal: true           # 自动修复漂移
      allowEmpty: false
    syncOptions:
      - CreateNamespace=true   # 自动创建命名空间
      - PrunePropagationPolicy=foreground
      - PruneLast=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
  # 忽略差异（某些字段由控制器管理）
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas
    - group: ""
      kind: Service
      jsonPointers:
        - /spec/clusterIP
```

### 2.2 App of Apps 模式

```yaml
# root-app.yaml - 根应用，管理所有其他应用
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: apps-root
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/mycompany/gitops.git
    targetRevision: main
    path: apps
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

# apps/guestbook.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mycompany/gitops.git
    targetRevision: main
    path: applications/guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: guestbook
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

# apps/nginx.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: nginx
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://github.com/mycompany/gitops.git
    targetRevision: main
    path: applications/nginx
  destination:
    server: https://kubernetes.default.svc
    namespace: nginx
  syncPolicy:
    automated:
      prune: true
      selfHeal: true

# 目录结构：
# gitops/
# ├── apps/
# │   ├── root-app.yaml
# │   ├── guestbook.yaml
# │   └── nginx.yaml
# ├── applications/
# │   ├── guestbook/
# │   │   └── kustomization.yaml
# │   └── nginx/
# │       └── deployment.yaml
# └── projects/
#     └── teams.yaml
```

### 2.3 ApplicationSet（多环境/多集群）

```yaml
# applicationset.yaml - 基于模板生成多个 Application
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd
spec:
  generators:
  # 生成器 1：列表生成器（多环境）
  - list:
      elements:
      - env: dev
        cluster: https://kubernetes.default.svc
        namespace: dev
        autoSync: false
      - env: staging
        cluster: https://kubernetes.default.svc
        namespace: staging
        autoSync: true
      - env: production
        cluster: https://prod-cluster.mycompany.com
        namespace: production
        autoSync: true
  
  # 生成器 2：Git 生成器（多目录）
  - git:
      repoURL: https://github.com/mycompany/microservices.git
      revision: HEAD
      directories:
      - path: services/*
      - path: services/service-a
        exclude: true  # 排除特定服务
  
  # 生成器 3：集群生成器（多集群）
  - clusters:
      selector:
        matchLabels:
          env: production
      values:
        revision: HEAD
  
  template:
    metadata:
      name: '{{env}}-{{path.basename}}'
      labels:
        env: '{{env}}'
        app: '{{path.basename}}'
    spec:
      project: '{{env}}'
      source:
        repoURL: https://github.com/mycompany/microservices.git
        targetRevision: '{{revision}}'
        path: '{{path}}'
      destination:
        server: '{{cluster}}'
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: '{{autoSync}}'
        syncOptions:
        - CreateNamespace=true
```

---

## 三、多集群管理

### 3.1 添加集群

```bash
# 方法 1：使用 argocd CLI
argocd cluster add <context-name> \
  --name production-beijing \
  --labels env=production,region=beijing

# 方法 2：手动添加（使用 ServiceAccount）
# 在目标集群上创建 ServiceAccount
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: argocd
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: argocd-manager
  namespace: argocd
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: argocd-manager-role-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: argocd-manager
  namespace: argocd
---
apiVersion: v1
kind: Secret
metadata:
  name: argocd-manager-token
  namespace: argocd
  annotations:
    kubernetes.io/service-account.name: argocd-manager
type: kubernetes.io/service-account-token
EOF

# 获取 token
TOKEN=$(kubectl get secret argocd-manager-token -n argocd -o jsonpath='{.data.token}' | base64 -d)

# 获取 CA
CA=$(kubectl get secret argocd-manager-token -n argocd -o jsonpath='{.data.ca\.crt}')

# 在 ArgoCD 集群上创建 Secret
kubectl apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-production-beijing
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: production-beijing
  server: https://<prod-api-server>:6443
  config: |
    {
      "bearerToken": "$TOKEN",
      "tlsClientConfig": {
        "insecure": false,
        "caData": "$CA"
      }
    }
EOF

# 验证
argocd cluster list
# SERVER                          NAME                VERSION  STATUS      MESSAGE
# https://kubernetes.default.svc  in-cluster          1.28     Successful
# https://<prod-api-server>:6443  production-beijing  1.28     Successful
```

### 3.2 多集群部署策略

```yaml
# 多集群 ApplicationSet（推模式）
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: multi-cluster-app
  namespace: argocd
spec:
  generators:
  - matrix:
      generators:
      - list:
          elements:
          - app: frontend
            path: frontend
          - app: backend
            path: backend
      - clusters:
          selector:
            matchExpressions:
            - key: env
              operator: In
              values: [dev, staging, production]
  template:
    metadata:
      name: '{{name}}-{{app}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/mycompany/gitops.git
        targetRevision: HEAD
        path: '{{path}}'
        helm:
          valueFiles:
          - 'values-{{name}}.yaml'
      destination:
        server: '{{server}}'
        namespace: '{{app}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true

# 拉模式（Pull-based）- 使用 ArgoCD Application Controller 分片
# 适用于 100+ 集群场景
# 每个 Controller 管理一部分集群
```

---

## 四、生产级监控与告警

### 4.1 Prometheus 监控

```yaml
# ArgoCD ServiceMonitor
groups:
- name: argocd
  rules:
  # 应用同步失败
  - alert: ArgoCDApplicationSyncFailed
    expr: |
      argocd_app_info{sync_status="Unknown"} == 1
      or
      argocd_app_sync_total{phase="Error"} > 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "ArgoCD application {{ $labels.name }} sync failed"
      description: "Application {{ $labels.name }} in namespace {{ $labels.namespace }} has sync errors"

  # 应用不健康
  - alert: ArgoCDApplicationNotHealthy
    expr: argocd_app_info{health_status!="Healthy"} == 1
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "ArgoCD application {{ $labels.name }} is not healthy"
      description: "Application health status: {{ $labels.health_status }}"

  # 同步延迟过高
  - alert: ArgoCDHighSyncLatency
    expr: histogram_quantile(0.99, rate(argocd_app_sync_duration_seconds_bucket[5m])) > 60
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "ArgoCD sync latency is high"
      description: "P99 sync latency is {{ $value }}s"

  # 仓库连接失败
  - alert: ArgoCDRepositoryConnectionFailed
    expr: argocd_repo_connection_status == 0
    for: 5m
    labels:
      severity: critical
    annotations:
      summary: "ArgoCD repository connection failed"
      description: "Repository {{ $labels.repo }} connection failed"

  # 控制器队列积压
  - alert: ArgoCDControllerQueueBacklog
    expr: workqueue_depth{name="application-controller"} > 100
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "ArgoCD controller queue backlog"
      description: "Controller queue depth: {{ $value }}"
```

### 4.2 Grafana Dashboard

```json
// 关键监控面板指标
{
  "dashboard": {
    "title": "ArgoCD Production",
    "panels": [
      {
        "title": "Application Health",
        "targets": [
          {
            "expr": "count(argocd_app_info{health_status=\"Healthy\"})"
          },
          {
            "expr": "count(argocd_app_info{health_status=\"Degraded\"})"
          },
          {
            "expr": "count(argocd_app_info{health_status=\"Progressing\"})"
          }
        ]
      },
      {
        "title": "Sync Status",
        "targets": [
          {
            "expr": "count(argocd_app_info{sync_status=\"Synced\"})"
          },
          {
            "expr": "count(argocd_app_info{sync_status=\"OutOfSync\"})"
          }
        ]
      },
      {
        "title": "Sync Duration P99",
        "targets": [
          {
            "expr": "histogram_quantile(0.99, rate(argocd_app_sync_duration_seconds_bucket[5m]))"
          }
        ]
      },
      {
        "title": "Controller Queue Depth",
        "targets": [
          {
            "expr": "workqueue_depth{name=\"application-controller\"}"
          }
        ]
      }
    ]
  }
}
```

---

## 五、故障排查

### 5.1 应用同步失败

```bash
# 查看应用状态
argocd app get guestbook -o yaml

# 关键字段：
# status:
#   sync:
#     status: OutOfSync          # 不同步
#     comparedTo:
#       source:
#         repoURL: ...
#         targetRevision: HEAD
#   conditions:
#   - type: ComparisonError
#     message: "rpc error: code = Unknown desc = authentication required"
#     lastTransitionTime: "2024-01-15T08:30:00Z"
#     status: "True"

# 查看详细同步状态
argocd app sync guestbook --dry-run

# 查看资源差异
argocd app diff guestbook

# 强制同步（忽略警告）
argocd app sync guestbook --force

# 查看控制器日志
kubectl logs -n argocd deployment/argocd-application-controller | grep guestbook

# 常见错误及修复：
# 1. "authentication required" → 检查仓库凭证
argocd repo add https://github.com/mycompany/repo.git \
  --username <user> --password <token>

# 2. "unable to resolve revision" → 检查分支/标签是否存在
git ls-remote https://github.com/mycompany/repo.git HEAD

# 3. "CustomResourceDefinition is deprecated" → 升级 CRD
kubectl apply -f https://github.com/.../crd.yaml

# 4. "resource already exists" → 添加 ignoreDifferences
# 或者手动删除冲突资源
```

### 5.2 性能问题

```bash
# 检查控制器资源使用
kubectl top pod -n argocd -l app.kubernetes.io/name=argocd-application-controller

# 检查 Redis 缓存
kubectl exec -it -n argocd deployment/argocd-redis -- redis-cli INFO memory

# 检查仓库服务器渲染性能
kubectl logs -n argocd deployment/argocd-repo-server | grep "took"

# 调优建议：
# 1. 增大控制器资源
kubectl patch statefulset argocd-application-controller -n argocd --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/cpu", "value": "2000m"},
  {"op": "replace", "path": "/spec/template/spec/containers/0/resources/limits/memory", "value": "4Gi"}
]'

# 2. 增加并发 workers
kubectl patch cm argocd-cm -n argocd --type='merge' -p '
{
  "data": {
    "controller.status.processors": "20",
    "controller.operation.processors": "10"
  }
}'

# 3. 调整仓库缓存
kubectl patch cm argocd-cm -n argocd --type='merge' -p '
{
  "data": {
    "reposerver.parallelism.limit": "50"
  }
}'
```

---

## 六、面试要点

```
Q: ArgoCD 的 Sync Wave 是什么？如何使用？

A: Sync Wave 控制同步顺序：
   - 默认所有资源 wave = 0，并行同步
   - 可以设置 wave = -5 到 5
   - 先同步低 wave，再同步高 wave
   - 同 wave 内并行
   
   使用场景：
   - wave -1: Namespace, ConfigMap, Secret
   - wave 0: Deployment, StatefulSet
   - wave 1: Service, Ingress
   - wave 2: Job（数据迁移）
   
   配置：
   metadata:
     annotations:
       argocd.argoproj.io/sync-wave: "1"

Q: ArgoCD 如何处理 K8s Secret？

A: 多种方案：
   1. Sealed Secrets: 加密存储在 Git，只有集群能解密
   2. External Secrets Operator: 从 Vault/AWS SM 读取
   3. SOPS: Mozilla 的加密工具，支持 AWS/GCP/Azure KMS
   4. ArgoCD Vault Plugin: 渲染时从 Vault 注入
   
   推荐：External Secrets Operator
   - Secret 不存储在 Git
   - 支持多种后端（Vault、AWS SM、Azure KV）
   - 自动同步和轮换

Q: ArgoCD ApplicationSet 和 App of Apps 的区别？

A: 
   App of Apps:
   - 用一个 Application 管理多个 Application
   - 手动定义每个子应用
   - 适合：少量应用（< 50），固定结构
   
   ApplicationSet:
   - 基于模板和生成器自动生成 Application
   - 支持：列表、Git、集群、矩阵生成器
   - 适合：大量应用（100+），动态结构
   - 功能更强：自动添加/删除应用
   
   建议：新用 ApplicationSet，旧用 App of Apps 可迁移

Q: ArgoCD 与 Flux CD 的区别？

A:
   ArgoCD:
   - 图形化 UI
   - 多集群管理
   - RBAC 更细粒度
   - 社区更大，生态更丰富
   - 资源消耗相对较高
   
   Flux CD:
   - GitOps 原生（无 UI，可用 Weave GitOps）
   - 更轻量
   - 与 Helm 集成更深
   - 渐进式交付（Flagger）
   - 适合：纯 CLI 团队、资源受限环境
```
