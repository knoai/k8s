# GitOps 深度实操：从 ArgoCD 安装到生产级发布

> GitOps 是现代平台工程的核心交付模式。本章从原理出发，逐步构建一个完整的 GitOps 流水线，
> 涵盖 ArgoCD 安装配置、多环境管理、金丝雀发布、密钥管理和灾难恢复。
> 每个实验都包含真实报错排查和面试核心考点。

---

## 第一章：ArgoCD 架构理解与安装

### 1.1 为什么需要 GitOps？

在传统运维模式中，工程师通过 kubectl 或控制台直接修改集群状态。这种方式存在三个致命问题：

**配置漂移**：当多个工程师手动修改集群后，实际运行状态与预期状态之间的差异越来越大。
某金融公司曾在审计中发现，生产环境有 37% 的 ConfigMap 与 Git 仓库中的定义不一致。

**操作不可审计**：谁改了什么、什么时候改的、为什么改，这些问题在手工操作中往往无法回答。

**回滚困难**：当发布出现问题时，手工回滚需要记住之前的状态，而人的记忆是不可靠的。

GitOps 通过三个原则解决这些问题：

```
1. 声明式：系统的期望状态以声明式配置存储在 Git 中
2. 版本化：所有变更都有版本历史，可以回滚到任意时间点
3. 自动同步：控制器持续监控 Git 和集群的差异，自动或手动同步
```

### 1.2 ArgoCD 核心架构

```
┌─────────────────────────────────────────────────────────────┐
│                         Git Repository                        │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────┐  │
│  │ 应用配置 YAML │  │ Kustomize    │  │ Helm Charts      │  │
│  │              │  │ Overlays     │  │                  │  │
│  └──────────────┘  └──────────────┘  └──────────────────┘  │
└────────────────────────┬────────────────────────────────────┘
                         │ Webhook / Poll (默认 3 分钟)
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                      ArgoCD Server                            │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ API Server  │  │ Repository  │  │ Application Controller│  │
│  │ (gRPC/REST) │  │ Server      │  │ (状态对比引擎)        │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
└────────────────────────┬────────────────────────────────────┘
                         │
                         ▼
┌─────────────────────────────────────────────────────────────┐
│                      Kubernetes Cluster                       │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐   │
│  │  Dev NS  │  │  Staging │  │   Prod   │  │  ArgoCD  │   │
│  │          │  │   NS     │  │   NS     │  │   NS     │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────┘   │
└─────────────────────────────────────────────────────────────┘
```

ArgoCD 每 3 分钟（可配置）轮询 Git 仓库，比较期望状态（Git 中的配置）和实际状态（集群中的资源）。
当发现差异时，根据同步策略决定是自动修复还是发出告警等待人工确认。

### 1.3 安装与初始化

```bash
# 创建命名空间
kubectl create namespace argocd

# 安装 ArgoCD（稳定版）
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# 等待所有组件就绪
kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-repo-server -n argocd
kubectl wait --for=condition=available --timeout=300s deployment/argocd-application-controller -n argocd

# 验证安装
kubectl get pods -n argocd
# NAME                                      READY   STATUS    RESTARTS   AGE
# argocd-application-controller-0           1/1     Running   0          2m
# argocd-redis-xxx                          1/1     Running   0          2m
# argocd-repo-server-xxx                    1/1     Running   0          2m
# argocd-server-xxx                         1/1     Running   0          2m
# argocd-dex-server-xxx                     1/1     Running   0          2m
```

### 1.4 初始访问配置

```bash
# 方法 1：端口转发（本地测试）
kubectl port-forward svc/argocd-server -n argocd 8080:443
# 访问 https://localhost:8080

# 获取初始密码（admin 用户的初始密码是 argocd-server Pod 名称）
argocd admin initial-password -n argocd
# 输出示例：
# xxxxxxxx-yyyy-zzzz-aaaa-bbbbbbbbbbbb
#
# This password must be only used for first time login.
# We strongly recommend you update the password using `argocd account update-password`.

# 方法 2：修改 Service 为 LoadBalancer（云环境）
kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "LoadBalancer"}}'
# 等待 EXTERNAL-IP 分配
kubectl get svc argocd-server -n argocd
# NAME            TYPE           CLUSTER-IP      EXTERNAL-IP    PORT(S)
# argocd-server   LoadBalancer   10.96.123.456   47.100.x.x     80:30080/TCP,443:30443/TCP

# 登录 CLI
argocd login localhost:8080 --insecure
# Username: admin
# Password: xxxxxxxx-yyyy-zzzz-aaaa-bbbbbbbbbbbb

# 修改密码（必须！）
argocd account update-password
# Enter current password: [初始密码]
# Enter new password: [你的强密码]
# Confirm new password: [再次输入]
```

### 1.5 常见安装错误排查

```bash
# 错误 1：argocd-server Pod 一直 Pending
kubectl describe pod -l app.kubernetes.io/name=argocd-server -n argocd | grep -A 10 Events
# 常见原因：
# - 节点资源不足（CPU/内存）
# - 没有可用的 PersistentVolume（argocd-redis 需要存储）
# 解决：检查节点资源，或安装 local-path-provisioner

# 错误 2：argocd-repo-server CrashLoopBackOff
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd --tail=50
# 常见原因：
# - /tmp 目录无写权限
# - Git 仓库证书问题

# 错误 3：CLI 无法连接
argocd login localhost:8080 --insecure
# FATA[0000] dial tcp [::1]:8080: connect: connection refused
# 原因：端口转发未启动或已断开
# 解决：重新执行 kubectl port-forward
```

---

## 第二章：Git 仓库集成与第一个应用

### 2.1 添加 Git 仓库

ArgoCD 支持多种 Git 提供商：GitHub、GitLab、Bitbucket、私有 Git 仓库等。

```bash
# 方法 1：HTTPS + 用户名密码（个人访问令牌）
argocd repo add https://github.com/your-org/gitops-platform.git \
  --username your-username \
  --password ghp_xxxxxxxxxxxxxxxxxxxx

# 方法 2：SSH + 私钥
argocd repo add git@github.com:your-org/gitops-platform.git \
  --ssh-private-key-path ~/.ssh/id_rsa

# 方法 3：GitHub App（组织级推荐）
# 1. 在 GitHub 创建 App，获取 App ID 和私钥
# 2. 配置 ArgoCD
cat > github-app.yaml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: github-app-repo-creds
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: repo-creds
stringData:
  url: https://github.com/your-org
  githubAppID: "123456"
  githubAppInstallationID: "78901234"
  githubAppPrivateKey: |
    -----BEGIN RSA PRIVATE KEY-----
    ...
    -----END RSA PRIVATE KEY-----
EOF
kubectl apply -f github-app.yaml

# 验证仓库连接
argocd repo list
# TYPE  NAME  REPO                                             INSECURE  OCI    LFS  CREDS  STATUS      MESSAGE
# git         https://github.com/your-org/gitops-platform.git  false     false  false  true   Successful
```

### 2.2 创建第一个 Application

Application 是 ArgoCD 的核心概念，它将 Git 仓库中的配置与 K8s 集群中的目标命名空间关联起来。

```bash
# 使用 CLI 创建
argocd app create guestbook \
  --repo https://github.com/argoproj/argocd-example-apps.git \
  --path guestbook \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace default \
  --sync-policy automated \
  --auto-prune \
  --self-heal

# 参数说明：
# --repo: Git 仓库地址
# --path: 仓库中的应用路径
# --dest-server: 目标 K8s 集群（https://kubernetes.default.svc = 当前集群）
# --dest-namespace: 部署到的命名空间
# --sync-policy automated: 自动同步 Git 变更
# --auto-prune: Git 中删除的资源，集群中也删除
# --self-heal: 集群中手动修改的资源，自动恢复为 Git 状态

# 查看应用状态
argocd app get guestbook
# Name:               guestbook
# Project:            default
# Server:             https://kubernetes.default.svc
# Namespace:          default
# URL:                https://localhost:8080/applications/guestbook
# Repo:               https://github.com/argoproj/argocd-example-apps.git
# Target:             
# Path:               guestbook
# SyncWindow:         Sync Allowed
# Sync Policy:        Automated (Prune)
# Sync Status:        Synced to  (75dba0d)
# Health Status:      Healthy
#
# GROUP  KIND        NAMESPACE  NAME            STATUS   HEALTH   HOOK  MESSAGE
#        Service     default    guestbook-ui    Synced   Healthy        service/guestbook-ui created
# apps   Deployment  default    guestbook-ui    Synced   Healthy        deployment.apps/guestbook-ui created
```

### 2.3 使用声明式方式管理 Application（GitOps 管理 GitOps）

将 Application 本身也存储在 Git 中，实现自举（Bootstrapping）：

```yaml
# gitops-repo/apps/guestbook.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: guestbook
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io  # 删除 App 时级联删除资源
spec:
  project: default
  source:
    repoURL: https://github.com/argoproj/argocd-example-apps.git
    targetRevision: HEAD
    path: guestbook
  destination:
    server: https://kubernetes.default.svc
    namespace: default
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

## 第三章：App of Apps 模式与多环境管理

### 3.1 为什么需要 App of Apps？

当集群中运行数十甚至数百个应用时，逐个管理 Application CRD 是不现实的。
App of Apps 模式通过一个 "根应用" 管理所有其他应用，实现单点控制。

```
gitops-repo/
├── bootstrap/                  # 根应用（只需手动创建一次）
│   └── root-app.yaml           # Application，指向 apps/ 目录
├── apps/
│   ├── payment-service.yaml    # Application
│   ├── order-service.yaml      # Application
│   ├── user-service.yaml       # Application
│   └── monitoring.yaml         # Application
├── payment-service/            # 应用配置
│   ├── base/
│   └── overlays/
├── order-service/
│   ├── base/
│   └── overlays/
└── ...
```

### 3.2 创建 Bootstrap 应用

```bash
# 这个应用只需手动创建一次，后续所有应用由它管理
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: app-of-apps
  namespace: argocd
  finalizers:
  - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://github.com/your-org/gitops-platform.git
    targetRevision: main
    path: apps
    directory:
      recurse: true  # 递归扫描子目录中的 YAML
      jsonnet: {}
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

# 验证：app-of-apps 会自动创建 apps/ 目录下的所有 Application
argocd app get app-of-apps
# GROUP        KIND         NAMESPACE  NAME              STATUS   HEALTH
# argoproj.io  Application  argocd     payment-service   Synced   Healthy
# argoproj.io  Application  argocd     order-service     Synced   Healthy
# argoproj.io  Application  argocd     user-service      Synced   Healthy
```

### 3.3 ApplicationSet 多环境部署

ApplicationSet 是 ArgoCD 2.0+ 引入的强大功能，它通过一个模板和多个生成器，自动生成多个 Application。

```bash
# 场景：同一个微服务需要部署到 dev、staging、prod 三个环境
# 每个环境的差异：副本数、资源配置、域名、配置项

kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: microservices
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - env: dev
        cluster: https://kubernetes.default.svc
        namespace: team-alpha-dev
        replicas: "1"
        cpuRequest: "100m"
        memoryRequest: "128Mi"
        domain: dev-alpha.company.io
        syncAuto: "false"
      - env: staging
        cluster: https://kubernetes.default.svc
        namespace: team-alpha-staging
        replicas: "2"
        cpuRequest: "250m"
        memoryRequest: "512Mi"
        domain: staging-alpha.company.io
        syncAuto: "false"
      - env: prod
        cluster: https://prod-cluster.api
        namespace: team-alpha-prod
        replicas: "3"
        cpuRequest: "500m"
        memoryRequest: "1Gi"
        domain: alpha.company.io
        syncAuto: "true"
  template:
    metadata:
      name: 'payment-service-{{env}}'
      annotations:
        environment: '{{env}}'
        team: team-alpha
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/gitops-platform.git
        targetRevision: main
        path: 'apps/payment-service/overlays/{{env}}'
        kustomize:
          commonAnnotations:
            deployed-by: argocd
            environment: '{{env}}'
      destination:
        server: '{{cluster}}'
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: '{{syncAuto}}'
        syncOptions:
        - CreateNamespace=true
        retry:
          limit: 3
          backoff:
            duration: 10s
            factor: 2
            maxDuration: 3m
EOF

# 验证自动创建的 Application
argocd app list | grep payment-service
# NAME                      CLUSTER                    NAMESPACE            STATUS  HEALTH   SYNCPOLICY  CONDITIONS
# payment-service-dev       https://kubernetes.default.svc  team-alpha-dev       Synced  Healthy  Auto-Prune  <none>
# payment-service-staging   https://kubernetes.default.svc  team-alpha-staging   Synced  Healthy  Auto-Prune  <none>
# payment-service-prod      https://prod-cluster.api        team-alpha-prod      Synced  Healthy  Auto-Prune  <none>
```

### 3.4 Git 生成器：按目录自动发现应用

```yaml
# 更高级的场景：gitops-repo/apps/ 下的每个子目录对应一个应用
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: auto-discover-apps
  namespace: argocd
spec:
  generators:
  - git:
      repoURL: https://github.com/your-org/gitops-platform.git
      revision: main
      directories:
      - path: apps/*
      - path: apps/excluded-app
        exclude: true
  template:
    metadata:
      name: '{{path.basename}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/your-org/gitops-platform.git
        targetRevision: main
        path: '{{path}}'
      destination:
        server: https://kubernetes.default.svc
        namespace: '{{path.basename}}'
      syncPolicy:
        syncOptions:
        - CreateNamespace=true
```

---

## 第四章：Argo Rollouts 金丝雀发布

### 4.1 为什么需要金丝雀发布？

直接全量替换 Pod（RollingUpdate）的问题是：一旦新版本有问题，所有用户都会受影响。
金丝雀发布将流量逐步切换到新版本，同时持续监控关键指标，发现问题立即回滚。

```
流量切换过程：

时间    v1 (旧)      v2 (新)      流量比例
──────────────────────────────────────────
T0      10 pods      0 pods       100% v1
T1      10 pods      2 pods       80% v1, 20% v2
T2      10 pods      4 pods       60% v1, 40% v2
T3      6 pods       6 pods       50% v1, 50% v2
T4      4 pods       8 pods       40% v1, 60% v2
T5      0 pods       10 pods      100% v2（全部通过）
──────────────────────────────────────────
如果在 T2 发现错误率上升 → 立即回滚到 T0 状态
```

### 4.2 安装 Argo Rollouts

```bash
# 安装控制器
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

# 安装 kubectl 插件
# macOS
brew install argoproj/tap/kubectl-argo-rollouts

# Linux
curl -LO https://github.com/argoproj/argo-rollouts/releases/latest/download/kubectl-argo-rollouts-linux-amd64
chmod +x ./kubectl-argo-rollouts-linux-amd64
sudo mv ./kubectl-argo-rollouts-linux-amd64 /usr/local/bin/kubectl-argo-rollouts

# 验证
kubectl argo rollouts version
```

### 4.3 创建金丝雀 Rollout

```bash
kubectl apply -f - <<'EOF'
apiVersion: argoproj.io/v1alpha1
kind: Rollout
metadata:
  name: canary-demo
  namespace: default
spec:
  replicas: 10
  strategy:
    canary:
      maxSurge: "25%"           # 最多额外创建 25% 的 Pod
      maxUnavailable: 0         # 不允许少于 replicas 的可用 Pod
      steps:
      # 步骤 1：发布 20% 流量（2 个 Pod），暂停等待人工确认
      - setWeight: 20
      - pause: {}
      
      # 步骤 2：发布 40% 流量（4 个 Pod），暂停 10 分钟
      - setWeight: 40
      - pause: {duration: 10m}
      
      # 步骤 3：发布 60% 流量（6 个 Pod），暂停 10 分钟
      - setWeight: 60
      - pause: {duration: 10m}
      
      # 步骤 4：发布 80% 流量（8 个 Pod），暂停 10 分钟
      - setWeight: 80
      - pause: {duration: 10m}
      
      # 步骤 5：100% 流量，自动完成
      - setWeight: 100
      
      # 自动回滚条件：错误率 > 5% 持续 5 分钟
      analysis:
        templates:
        - templateName: success-rate
        startingStep: 1  # 从第 1 步开始分析
        args:
        - name: service-name
          value: canary-demo
      
      # 流量管理（需要 Service Mesh 或 Ingress Controller 支持）
      trafficRouting:
        nginx:
          stableIngress: canary-demo-ingress
          annotationPrefix: nginx.ingress.kubernetes.io
  selector:
    matchLabels:
      app: canary-demo
  template:
    metadata:
      labels:
        app: canary-demo
    spec:
      containers:
      - name: canary-demo
        image: argoproj/rollouts-demo:blue
        ports:
        - containerPort: 8080
        resources:
          requests:
            memory: "32Mi"
            cpu: "5m"
---
apiVersion: v1
kind: Service
metadata:
  name: canary-demo
  namespace: default
spec:
  ports:
  - port: 80
    targetPort: 8080
  selector:
    app: canary-demo
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: canary-demo-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
spec:
  ingressClassName: nginx
  rules:
  - host: canary.company.io
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: canary-demo
            port:
              number: 80
EOF
```

### 4.4 执行金丝雀发布

```bash
# 查看初始状态
kubectl argo rollouts get rollout canary-demo
# Name:            canary-demo
# Namespace:       default
# Status:          Healthy
# Strategy:        Canary
#   Step:          5/5
#   SetWeight:     100
#   ActualWeight:  100
# Replicas:
#   Desired:       10
#   Current:       10
#   Updated:       10
#   Ready:         10
#   Available:     10
#
# Images:
#   argoproj/rollouts-demo:blue (stable)
#
# ReplicaSet:
#   Name:   canary-demo-7d4f4db9c6
#   Status: ✔ Healthy
```

```bash
# 触发金丝雀更新
kubectl argo rollouts set image canary-demo canary-demo=argoproj/rollouts-demo:yellow

# 监控推进过程
kubectl argo rollouts get rollout canary-demo --watch
# Name:            canary-demo
# Namespace:       default
# Status:          ॥ Paused
# Message:         CanaryPauseStep
# Strategy:        Canary
#   Step:          1/5
#   SetWeight:     20
#   ActualWeight:  20
# Replicas:
#   Desired:       10
#   Current:       12  <- 2 个额外 Pod（maxSurge 25%）
#   Updated:       2   <- 2 个新版本 Pod
#   Ready:         12
#   Available:     10

# 关键输出解读：
# - Step 1/5: 当前在第 1 步
# - SetWeight 20: 目标流量 20%
# - ActualWeight 20: 实际流量 20%（通过 Ingress/Service Mesh 实现）
# - Current 12: 10 个旧版 + 2 个新版（因为 maxSurge=25%）
```

```bash
# 如果监控指标正常，手动继续推进
kubectl argo rollouts promote canary-demo

# 如果发现问题，立即回滚
kubectl argo rollouts abort canary-demo
# 回滚后：所有流量回到旧版本，新版本 Pod 被缩容到 0

# 查看 Rollout 历史
kubectl argo rollouts history canary-demo
```

---

## 第五章：密钥管理

### 5.1 Sealed Secrets（Bitnami）

GitOps 的核心问题是：Secret 不能提交到 Git，但应用又需要 Secret。
Sealed Secrets 通过非对称加密解决这个问题：只有集群中的 Controller 能解密。

```bash
# 安装 kubeseal CLI
brew install kubeseal

# 安装 Sealed Secrets Controller
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.2/controller.yaml

# 等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=sealed-secrets -n kube-system --timeout=120s

# 获取公钥（用于加密，可以安全地分发给开发者）
kubeseal --fetch-cert > sealed-secrets-cert.pem

# 加密一个 Secret
echo -n 'super-secret-password-12345' | \
  kubectl create secret generic db-password \
    --from-file=password=/dev/stdin \
    --dry-run=client -o yaml | \
  kubeseal --cert sealed-secrets-cert.pem \
           --format yaml > sealed-db-password.yaml

# sealed-db-password.yaml 可以安全提交到 Git
# 内容示例：
# apiVersion: bitnami.com/v1alpha1
# kind: SealedSecret
# metadata:
#   name: db-password
#   namespace: default
# spec:
#   encryptedData:
#     password: AgA123...（很长的加密字符串）

# 提交到 Git
git add sealed-db-password.yaml
git commit -m "Add sealed db password"
git push

# Controller 自动解密为普通 Secret
kubectl get secret db-password -o yaml
# data:
#   password: c3VwZXItc2VjcmV0LXBhc3N3b3JkLTEyMzQ1
# 解密后：super-secret-password-12345
```

### 5.2 External Secrets Operator（推荐用于云环境）

ESO 将云厂商的密钥管理服务（AWS Secrets Manager、Azure Key Vault、阿里云 KMS 等）与 K8s Secret 自动同步。

```bash
# 安装 ESO
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace

# 创建 SecretStore（指向外部密钥管理）
# 以 AWS Secrets Manager 为例
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ClusterSecretStore
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
            namespace: external-secrets
EOF

# 创建 ExternalSecret（定义同步规则）
kubectl apply -f - <<'EOF'
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: payment-db-secret
  namespace: default
spec:
  refreshInterval: 1h  # 每小时同步一次
  secretStoreRef:
    kind: ClusterSecretStore
    name: aws-secrets-manager
  target:
    name: payment-db-connection  # 创建的 K8s Secret 名称
    creationPolicy: Owner
    template:
      type: Opaque
      data:
        # 将外部 Secret 的字段映射到 K8s Secret
        DB_HOST: "{{ .host }}"
        DB_PASSWORD: "{{ .password }}"
  data:
  - secretKey: host
    remoteRef:
      key: prod/payment-db
      property: host
  - secretKey: password
    remoteRef:
      key: prod/payment-db
      property: password
EOF

# 验证 Secret 自动创建
kubectl get secret payment-db-connection -o yaml
# data:
#   DB_HOST: cGF5bWVudC1kYi5jbHVzdGVyLWFid3N0dXMtMS5yd2RzLmFtYXpvbmF3cy5jb20=
#   DB_PASSWORD: c3VwZXJzZWNyZXQxMjM=
```

---

## 第六章：灾难恢复与运维

### 6.1 ArgoCD 自身备份

```bash
# 导出所有 Application 定义
argocd admin export > argocd-backup.yaml

# 导出项目（Projects）配置
argocd proj list
for proj in $(argocd proj list -o name); do
  argocd proj get $proj -o yaml >> argocd-projects-backup.yaml
done

# 导出仓库凭证（注意：Secret 需要单独处理）
kubectl get secret -n argocd -l argocd.argoproj.io/secret-type -o yaml > argocd-secrets-backup.yaml

# 灾难恢复：新集群重建
# 1. 安装 ArgoCD
# 2. 恢复仓库凭证 Secret
kubectl apply -f argocd-secrets-backup.yaml
# 3. 恢复 Application
kubectl apply -f argocd-backup.yaml
# 4. ArgoCD 自动同步所有应用
```

### 6.2 常见运维问题排查

```bash
# 问题 1：应用状态为 Unknown
argocd app get <app-name>
# 原因：目标集群不可达
# 排查：
kubectl get secret -n argocd | grep cluster
argocd cluster list
# 如果集群状态为 Unknown，重新添加：
argocd cluster add <context-name>

# 问题 2：同步失败：resource already exists
# 原因：集群中已有同名资源，但不是由 ArgoCD 管理的
# 解决：将现有资源标记为 ArgoCD 管理
kubectl label deployment <name> app.kubernetes.io/managed-by=argocd
# 或在 Application 中添加：
# syncPolicy:
#   syncOptions:
#   - RespectIgnoreDifferences=true

# 问题 3：大规模应用同步超时
# 原因：默认同步超时 5 分钟，大规模应用可能不够
# 解决：
argocd app sync <app-name> --timeout 600
# 或在 Application 中配置：
# spec:
#   syncPolicy:
#     retry:
#       limit: 10
#       backoff:
#         duration: 10s
#         maxDuration: 5m

# 问题 4：仓库访问 401/403
# 排查：
argocd repo get https://github.com/your-org/repo.git
# 如果状态为 Failed，更新凭证：
argocd repo add https://github.com/your-org/repo.git \
  --username <user> --password <new-token> --upsert
```

---

## 第七章：面试核心考点

```
Q: GitOps 和传统 CI/CD 有什么区别？

A:
   传统 CI/CD：
   - CI 构建镜像 → CD 执行 kubectl apply
   - 部署权限集中在 CI/CD 系统
   - 集群状态 = CI/CD 最后一次执行的结果
   
   GitOps：
   - Git 是唯一的配置来源（Single Source of Truth）
   - 控制器（如 ArgoCD）持续监控 Git → 集群的同步
   - 部署权限分散：任何人都可以提交 PR，ArgoCD 自动同步
   - 集群状态 = Git 当前状态
   
   关键优势：
   1. 配置漂移自动检测和修复
   2. 完整的变更审计历史（Git log）
   3. 灾难恢复：新集群 + Git = 完整恢复

Q: ArgoCD 的 auto-prune 和 self-heal 有什么区别？

A:
   auto-prune：
   - Git 中删除了某个资源定义 → ArgoCD 从集群中删除该资源
   - 解决 "幽灵资源" 问题
   
   self-heal：
   - 有人手动 kubectl edit 修改了集群中的资源
   - ArgoCD 检测到与 Git 不一致 → 自动回滚为 Git 状态
   - 解决配置漂移问题
   
   生产建议：
   - 开发环境：启用两者
   - 生产环境：启用 auto-prune，self-heal 谨慎启用（避免覆盖紧急修复）

Q: ApplicationSet 的 generators 有哪些类型？

A:
   1. List generator：手动定义列表（适合少量固定环境）
   2. Git generator：按 Git 目录/文件自动生成（适合大量应用）
   3. Cluster generator：按注册集群自动生成（适合多集群）
   4. Matrix generator：组合多个 generator（高级场景）
   5. SCM Provider generator：按 SCM 组织/仓库生成
   6. Pull Request generator：为每个 PR 创建预览环境

Q: Argo Rollouts 金丝雀发布 vs K8s 原生 RollingUpdate？

A:
   RollingUpdate：
   - 按 maxUnavailable/maxSurge 逐步替换 Pod
   - 流量切换基于 Pod Ready 状态，不基于实际健康指标
   - 发现问题时已经全量发布
   
   金丝雀发布：
   - 按权重逐步切换流量（10% → 25% → 50% → 100%）
   - 每个阶段可配置自动/手动确认
   - 可集成 Prometheus 指标自动判断回滚
   - 支持 Service Mesh（Istio、Linkerd、SMI）精细流量控制
```
