# 策略即代码 - Kyverno 深度实操指南

> 策略即代码（Policy as Code）是平台工程治理的核心能力。本章从安全基线出发，
> 逐步构建一个覆盖资源校验、自动修正、环境生成和合规审计的完整策略体系。

---

## 第一章：为什么需要策略即代码？

### 1.1 生产环境的安全噩梦

在没有策略治理的集群中，以下场景每天都在发生：

```
场景 1：某开发者为了方便调试，创建了特权容器
  kubectl run debug --image=nicolaka/netshoot --privileged
  → 容器可以访问宿主机的所有设备，包括磁盘
  → 如果容器被攻破，攻击者可以直接读取宿主机上的所有 Secret

场景 2：某团队忘记设置资源限制
  resources: {}  # 空对象
  → Pod 可以消耗节点上所有 CPU 和内存
  → 节点资源耗尽，其他 Pod 被驱逐

场景 3：某服务使用了 latest 镜像标签
  image: myapp:latest
  → 每次拉取可能得到不同版本的镜像
  → 生产环境出现不可复现的 bug

场景 4：Pod 以 root 用户运行
  runAsUser: 0
  → 容器内进程拥有 root 权限
  → 容器逃逸风险大幅增加
```

传统的人工审查方式（PR Review 时检查 YAML）有两个根本问题：
1. **不可扩展**：100 个服务 × 每周 10 次变更 = 1000 次审查，人工无法保证质量
2. **不可审计**：审查通过后的资源是否被手动修改过？无法确认

策略即代码的解决方案：将安全规则编写为代码，由控制器自动执行。

### 1.2 Kyverno vs OPA Gatekeeper 选型对比

```
维度              Kyverno                  OPA Gatekeeper
─────────────────────────────────────────────────────────────────
配置语言          YAML（类 K8s 语法）       Rego（专用 DSL）
学习曲线          低（K8s 用户 1 天上手）    高（需学习 Rego）
验证性能          中等（Webhook 模式）       高（ Compiled）
社区活跃度        快速增长                  成熟稳定
与 K8s 集成       原生（理解 K8s 语义）      通用（需自定义）
适用场景          标准策略快速落地          复杂自定义逻辑
─────────────────────────────────────────────────────────────────

选型建议：
  - 80% 的标准策略（禁止特权容器、强制标签等）→ Kyverno
  - 20% 的复杂策略（自定义成本计算、跨资源关联验证）→ OPA Gatekeeper
  - 许多企业两者并用：Kyverno 覆盖基础安全，OPA 覆盖业务逻辑
```

---

## 第二章：Kyverno 安装与架构理解

### 2.1 Kyverno 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Kubernetes API Server                      │
│                          │                                    │
│              ┌───────────▼───────────┐                        │
│              │  Dynamic Admission     │                        │
│              │  Webhook               │                        │
│              │                        │                        │
│              │  MutatingWebhook       │                        │
│              │  ValidatingWebhook     │                        │
│              └───────────┬───────────┘                        │
│                          │                                    │
└──────────────────────────┼────────────────────────────────────┘
                           │ HTTPS (mTLS)
                           ▼
┌─────────────────────────────────────────────────────────────┐
│                    Kyverno Admission Controller                 │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │ Webhook     │  │ Policy      │  │ Rule Engine         │  │
│  │ Server      │  │ Cache       │  │ (Validate/Mutate/   │  │
│  │ (HTTPS)     │  │ (Informer)  │  │  Generate/Verify)   │  │
│  └─────────────┘  └─────────────┘  └─────────────────────┘  │
│                          │                                    │
│              ┌───────────▼───────────┐                        │
│              │  Policy Reporter        │                        │
│              │  (审计与合规报告)        │                        │
│              └─────────────────────────┘                        │
└─────────────────────────────────────────────────────────────┘

工作流程：
  1. 用户执行 kubectl apply
  2. API Server 将请求发送给 Kyverno Webhook
  3. Kyverno 匹配 Policy 中的规则
  4. 根据规则类型执行：
     - Validate：检查是否符合策略，不符合则拒绝（HTTP 403）
     - Mutate：自动修改资源（如注入 sidecar、添加标签）
     - Generate：自动生成关联资源（如创建 NetworkPolicy）
     - VerifyImages：验证镜像签名
  5. 如果通过所有检查，API Server 继续处理请求
```

### 2.2 安装 Kyverno

```bash
# 添加 Helm 仓库
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update

# 安装（生产环境推荐 3 副本）
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set replicaCount=3 \
  --set resources.limits.cpu=1000m \
  --set resources.limits.memory=1Gi \
  --set resources.requests.cpu=100m \
  --set resources.requests.memory=128Mi

# 等待就绪
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=kyverno -n kyverno --timeout=120s

# 验证安装
kubectl get pods -n kyverno
# NAME                       READY   STATUS    RESTARTS   AGE
# kyverno-admission-controller-xxx   1/1     Running   0          2m
# kyverno-admission-controller-yyy   1/1     Running   0          2m
# kyverno-admission-controller-zzz   1/1     Running   0          2m
# kyverno-background-controller-aaa  1/1     Running   0          2m
# kyverno-reports-controller-bbb     1/1     Running   0          2m

# 验证 Webhook 注册
kubectl get validatingwebhookconfigurations | grep kyverno
# kyverno-resource-validating-webhook-cfg
# kyverno-policy-validating-webhook-cfg

kubectl get mutatingwebhookconfigurations | grep kyverno
# kyverno-resource-mutating-webhook-cfg
# kyverno-policy-mutating-webhook-cfg
```

---

## 第三章：验证规则（Validation）

### 3.1 强制标签策略

```bash
# 场景：所有资源必须有 team 和 environment 标签，用于成本分摊和故障定位

cat > require-labels.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
  annotations:
    policies.kyverno.io/title: Require Labels
    policies.kyverno.io/category: Best Practices
    policies.kyverno.io/severity: medium
    policies.kyverno.io/subject: Label
    policies.kyverno.io/description: >-
      所有命名空间和工作负载必须包含 team、environment、cost-center 标签
spec:
  validationFailureAction: Enforce  # Enforce = 拒绝，Audit = 只记录不拒绝
  background: true                  # 后台扫描现有资源
  rules:
  - name: check-namespace-labels
    match:
      resources:
        kinds:
        - Namespace
    validate:
      message: "Namespace 必须包含 team、environment、cost-center 标签"
      pattern:
        metadata:
          labels:
            team: "?*"
            environment: "?*"
            cost-center: "?*"

  - name: check-deployment-labels
    match:
      resources:
        kinds:
        - Deployment
        - StatefulSet
        - DaemonSet
        - Job
    validate:
      message: "工作负载必须包含 team、app、version 标签"
      pattern:
        metadata:
          labels:
            team: "?*"
            app: "?*"
            version: "?*"
EOF

kubectl apply -f require-labels.yaml

# 验证策略生效
kubectl get clusterpolicy require-labels
# NAME             ADMISSION   BACKGROUND   VALIDATE   MUTATE   GENERATE   VERIFYIMAGE
# require-labels   true        true         2          0        0          0
```

### 3.2 测试验证策略

```bash
# 测试 1：合规资源（应通过）
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha-prod
  labels:
    team: team-alpha
    environment: production
    cost-center: CC-1234
EOF
# namespace/team-alpha-prod created

# 测试 2：不合规资源（应被拒绝）
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: bad-namespace
EOF
# Error from server: admission webhook "validate.kyverno.svc-fail" denied the request:
# resource Namespace//bad-namespace was blocked due to the following policies:
# require-labels:
#   check-namespace-labels: 'validation error: Namespace 必须包含 team、environment、cost-center 标签'

# 测试 3：不合规 Deployment（应被拒绝）
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bad-deployment
  namespace: default
  labels:
    app: myapp
    # 缺少 team 和 version
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myapp
  template:
    metadata:
      labels:
        app: myapp
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
EOF
# Error from server: ... 工作负载必须包含 team、app、version 标签
```

### 3.3 禁止特权容器（安全基线）

```bash
cat > disallow-privileged.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow Privileged Containers
    policies.kyverno.io/category: Pod Security Standards (Restricted)
    policies.kyverno.io/severity: high
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: privileged-containers
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "特权容器被禁止（securityContext.privileged = true）"
      pattern:
        spec:
          containers:
          - securityContext:
              =(privileged): "false"
          =(initContainers):
          - securityContext:
              =(privileged): "false"

  - name: host-path-volumes
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "hostPath 卷被禁止（安全风险）"
      pattern:
        spec:
          =(volumes):
          - =(hostPath):
              X(hostPath): "null"

  - name: host-namespace
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "共享宿主机命名空间被禁止"
      pattern:
        spec:
          =(hostPID): "false"
          =(hostIPC): "false"
          =(hostNetwork): "false"
EOF

kubectl apply -f disallow-privileged.yaml

# 验证：尝试创建特权 Pod（应被拒绝）
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
  namespace: default
spec:
  containers:
  - name: debug
    image: nicolaka/netshoot
    securityContext:
      privileged: true
EOF
# Error from server: ... 特权容器被禁止
```

### 3.4 限制镜像来源（供应链安全）

```bash
cat > restrict-image-registries.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-registries
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "只允许使用公司批准的镜像仓库"
      pattern:
        spec:
          containers:
          - image: "registry.company.io/* | gcr.io/company/* | *.amazonaws.com/*"
          =(initContainers):
          - image: "registry.company.io/* | gcr.io/company/* | *.amazonaws.com/*"
EOF

kubectl apply -f restrict-image-registries.yaml

# 测试：使用 Docker Hub 镜像（应被拒绝）
kubectl run test --image=nginx:latest
# Error from server: ... 只允许使用公司批准的镜像仓库

# 测试：使用批准的仓库（应通过）
kubectl run test --image=registry.company.io/nginx:v1.25
# pod/test created
```

---

## 第四章：变异规则（Mutation）

### 4.1 自动注入资源限制

```bash
# 场景：开发者经常忘记设置 resources，导致节点资源耗尽
# 策略：如果 Pod 没有设置 resources，自动注入默认值

cat > add-default-resources.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-default-resources
spec:
  rules:
  - name: add-resources
    match:
      resources:
        kinds:
        - Deployment
        - StatefulSet
        - DaemonSet
        - Job
    mutate:
      patchStrategicMerge:
        spec:
          template:
            spec:
              containers:
              - (name): "*"
                resources:
                  requests:
                    +(memory): "128Mi"
                    +(cpu): "100m"
                  limits:
                    +(memory): "512Mi"
                    +(cpu): "500m"
EOF

kubectl apply -f add-default-resources.yaml

# 测试：创建没有 resources 的 Deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: resource-test
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels:
      app: resource-test
  template:
    metadata:
      labels:
        app: resource-test
    spec:
      containers:
      - name: nginx
        image: nginx:alpine
EOF

# 验证：自动注入了 resources
kubectl get deployment resource-test -o jsonpath='{.spec.template.spec.containers[0].resources}' | jq .
# {
#   "limits": {
#     "cpu": "500m",
#     "memory": "512Mi"
#   },
#   "requests": {
#     "cpu": "100m",
#     "memory": "128Mi"
#   }
# }
```

### 4.2 自动注入 Sidecar（监控代理）

```bash
cat > inject-monitoring-sidecar.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-monitoring-sidecar
spec:
  rules:
  - name: add-prometheus-exporter
    match:
      resources:
        kinds:
        - Deployment
        annotations:
          monitoring.company.io/scrape: "true"
    mutate:
      patchStrategicMerge:
        spec:
          template:
            spec:
              containers:
              - name: prometheus-exporter
                image: prometheus/node-exporter:v1.7.0
                ports:
                - containerPort: 9100
                  name: metrics
                resources:
                  requests:
                    cpu: "50m"
                    memory: "64Mi"
                  limits:
                    cpu: "100m"
                    memory: "128Mi"
EOF

kubectl apply -f inject-monitoring-sidecar.yaml

# 测试：创建带注解的 Deployment
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: monitored-app
  namespace: default
  annotations:
    monitoring.company.io/scrape: "true"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: monitored-app
  template:
    metadata:
      labels:
        app: monitored-app
    spec:
      containers:
      - name: app
        image: nginx:alpine
EOF

# 验证：自动注入了 sidecar
kubectl get deployment monitored-app -o jsonpath='{.spec.template.spec.containers[*].name}'
# app prometheus-exporter
```

---

## 第五章：生成规则（Generation）

### 5.1 自动创建 NetworkPolicy

```bash
# 场景：每个新命名空间都需要默认的 deny-all 网络策略
# 策略：当创建带特定标签的命名空间时，自动生成 NetworkPolicy

cat > generate-default-networkpolicy.yaml <<'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-default-networkpolicy
spec:
  rules:
  - name: create-networkpolicy
    match:
      resources:
        kinds:
        - Namespace
        selector:
          matchLabels:
            network-policy: enabled
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny-all
      namespace: "{{request.object.metadata.name}}"
      synchronize: true  # 如果策略被删除，自动重新创建
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress
EOF

kubectl apply -f generate-default-networkpolicy.yaml

# 测试：创建带标签的命名空间
kubectl create namespace auto-policy-ns
kubectl label namespace auto-policy-ns network-policy=enabled

# 验证 NetworkPolicy 被自动生成
kubectl get networkpolicy -n auto-policy-ns
# NAME                POD-SELECTOR   AGE
# default-deny-all    <none>         5s

# 验证：删除后自动重新创建（因为 synchronize: true）
kubectl delete networkpolicy default-deny-all -n auto-policy-ns
sleep 5
kubectl get networkpolicy -n auto-policy-ns
# NAME                POD-SELECTOR   AGE
# default-deny-all    <none>         2s
```

---

## 第六章：策略测试与 CI 集成

### 6.1 Kyverno CLI 本地测试

```bash
# 安装 kyverno CLI
brew install kyverno

# 创建测试目录结构
mkdir -p kyverno-tests/{policies,resources,tests}

# 测试策略
cat > kyverno-tests/policies/require-labels.yaml <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-labels
    match:
      resources:
        kinds:
        - Deployment
    validate:
      message: "Deployment must have app label"
      pattern:
        metadata:
          labels:
            app: "?*"
EOF

# 通过的资源
cat > kyverno-tests/resources/pass-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: pass
  labels:
    app: test
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
EOF

# 失败的资源
cat > kyverno-tests/resources/fail-deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: fail
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test
  template:
    metadata:
      labels:
        app: test
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
EOF

# 测试文件
cat > kyverno-tests/tests/require-labels-test.yaml <<EOF
name: test-require-labels
policies:
- ../policies/require-labels.yaml
resources:
- ../resources/pass-deployment.yaml
- ../resources/fail-deployment.yaml
results:
- policy: require-labels
  rule: check-labels
  resource: pass
  kind: Deployment
  result: pass
- policy: require-labels
  rule: check-labels
  resource: fail
  kind: Deployment
  result: fail
EOF

# 运行测试
cd kyverno-tests && kyverno test tests/

# 预期输出：
# Loading test (tests/require-labels-test.yaml) ...
#   Loading policies ...
#   Loading resources ...
#   Loading exceptions ...
#   Applying 1 policy to 2 resources ...
#   Checking results ...
#
# ╔════════════════════════════════════════════════════════════════╗
# ║                    TEST SUMMARY                                 ║
# ╠════════════════════════════════════════════════════════════════╣
# ║  # of test cases with no errors : 2                             ║
# ║  # of test cases with errors    : 0                             ║
# ║  # of skipped tests             : 0                             ║
# ║  # of results with no errors    : 2                             ║
# ║  # of results with errors       : 0                             ║
# ╚════════════════════════════════════════════════════════════════╝
```

### 6.2 GitHub Actions CI 集成

```yaml
# .github/workflows/kyverno-test.yaml
name: Kyverno Policy Tests

on:
  pull_request:
    paths:
    - 'policies/**'
    - 'kyverno-tests/**'

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4

    - name: Install Kyverno CLI
      uses: kyverno/action-install-cli@v0.2.0
      with:
        release: 'v1.11.0'

    - name: Run Policy Tests
      run: |
        kyverno test kyverno-tests/

    - name: Validate Policies
      run: |
        kyverno validate policies/
```

---

## 第七章：合规审计与报告

### 7.1 查看策略执行报告

```bash
# 集群级报告（所有命名空间）
kubectl get clusterpolicyreports
# NAME                                   KIND   NAME   PASS   FAIL   WARN   ERROR   SKIP   AGE
# cpol-require-labels                    Pod    xxx    10     2      0      0       0      1h

# 详细结果
kubectl get clusterpolicyreports -o yaml | head -100

# 命名空间级报告
kubectl get policyreports -n default

# 查看某个资源的策略执行结果
kubectl get policyreport -n default -o json | jq '.results[] | select(.resources[].name=="my-deployment")'
```

### 7.2 Policy Reporter 可视化

```bash
# 安装 Policy Reporter UI
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install policy-reporter kyverno/policy-reporter \
  --namespace policy-reporter \
  --create-namespace \
  --set ui.enabled=true \
  --set ui.plugins.kyverno=true

# 端口转发访问 UI
kubectl port-forward svc/policy-reporter-ui -n policy-reporter 8082:8080

# 访问 http://localhost:8082
# 可以看到：
# - 策略执行统计
# - 失败的资源列表
# - 按命名空间/策略/规则的过滤
```

---

## 第八章：面试核心考点

```
Q: Kyverno 的 Mutate、Validate、Generate 三种规则有什么区别？

A:
   Validate（验证）：
   - 在资源创建/更新时检查是否符合规则
   - 不符合 → 返回 HTTP 403，拒绝请求
   - 例：禁止特权容器、强制标签、限制镜像来源
   
   Mutate（变异）：
   - 在资源创建/更新时自动修改资源
   - 修改后的资源再进入 API Server
   - 例：自动注入资源限制、添加标签、注入 sidecar
   
   Generate（生成）：
   - 当匹配的资源被创建时，自动生成其他资源
   - 可以设置 synchronize: true 实现级联管理
   - 例：创建命名空间时自动生成 NetworkPolicy、Quota

Q: validationFailureAction: Enforce 和 Audit 有什么区别？

A:
   Enforce：策略违反时拒绝请求（HTTP 403）
   - 用于安全基线策略（禁止特权容器、限制镜像来源）
   - 适用于生产环境
   
   Audit：策略违反时允许请求，但记录到 PolicyReport
   - 用于新策略上线前的观察期
   - 先 Audit 1 周，确认无误判后切换为 Enforce
   - 适用于非安全类策略（建议性标签、资源推荐）

Q: Kyverno 和 OPA Gatekeeper 如何选型？

A:
   选 Kyverno：
   - 团队熟悉 K8s YAML 但不想学习 Rego
   - 需要快速落地标准安全策略（80% 场景）
   - 需要原生理解 K8s 资源语义（auto-gen rules）
   
   选 OPA Gatekeeper：
   - 需要跨平台策略（不只 K8s，还包括 Terraform、CI/CD）
   - 需要复杂的数据聚合和计算逻辑
   - 已有 Rego 开发经验
   
   最佳实践：两者并用
   - Kyverno：Pod 安全、资源治理、标签策略
   - OPA：成本计算、跨资源关联验证、业务逻辑

Q: Kyverno Webhook 的延迟对 API Server 有什么影响？

A:
   影响：
   - 所有资源创建/更新请求都需要经过 Kyverno Webhook
   - 如果 Kyverno Pod 不可用，API Server 会拒绝所有请求
   - 默认 timeout 是 10 秒
   
   优化措施：
   1. Kyverno 运行 3 副本 + PodDisruptionBudget
   2. 设置合理的 Webhook timeout（默认 10s，可调为 5s）
   3. 使用 exclude 规则减少不必要的匹配
   4. 监控 kyverno_admission_review_duration 指标
   5. 大集群考虑 Kyverno 的 Report 模式（异步扫描）
```
