# Kyverno 策略即代码深度实践

> Kyverno 是 K8s 原生策略引擎，使用 YAML 而非 Rego 编写策略。
> 本节从基础策略到高级模式，提供完整的生产实践指南。

---

## 一、Kyverno 核心概念

### 1.1 策略类型

```
Kyverno 策略类型：

┌─────────────────────────────────────────┐
│  Validate（验证）                        │
│   - 阻止不符合策略的资源创建/更新        │
│   - 例如：禁止 privileged 容器           │
│   - failurePolicy: Enforce / Audit      │
├─────────────────────────────────────────┤
│  Mutate（变异）                          │
│   - 自动修改资源（添加标签、注入 Sidecar）│
│   - 例如：自动添加资源标签               │
│   - 在资源创建时执行                     │
├─────────────────────────────────────────┤
│  Generate（生成）                        │
│   - 创建相关资源                         │
│   - 例如：创建 Namespace 时自动创建     │
│     NetworkPolicy、ResourceQuota        │
│   - 支持同步更新和清理                   │
├─────────────────────────────────────────┤
│  VerifyImages（镜像验证）                │
│   - 验证镜像签名（cosign/Notary）        │
│   - 确保镜像未被篡改                     │
│   - 支持密钥管理和轮换                   │
└─────────────────────────────────────────┘

策略范围：
  ClusterPolicy：集群范围，影响所有命名空间
  Policy：命名空间范围，只影响特定命名空间
```

### 1.2 安装与配置

```bash
# 安装 Kyverno
kubectl create namespace kyverno
helm repo add kyverno https://kyverno.github.io/kyverno/
helm install kyverno kyverno/kyverno -n kyverno \
  --set replicaCount=3 \
  --set resources.limits.cpu=1000m \
  --set resources.limits.memory=1Gi

# 验证
kubectl get pods -n kyverno
# NAME                            READY   STATUS    RESTARTS   AGE
# kyverno-admission-controller-0  1/1     Running   0          1m
# kyverno-admission-controller-1  1/1     Running   0          1m
# kyverno-admission-controller-2  1/1     Running   0          1m
# kyverno-background-controller-xxx 1/1   Running   0          1m
# kyverno-cleanup-controller-xxx    1/1   Running   0          1m
# kyverno-reports-controller-xxx    1/1   Running   0          1m

# 安装 Kyverno CLI（本地测试）
brew install kyverno  # macOS
# 或下载二进制
curl -L https://github.com/kyverno/kyverno/releases/download/v1.11.0/kyverno-cli_v1.11.0_linux_x86_64.tar.gz | tar xz
sudo mv kyverno /usr/local/bin/

# 本地测试策略
kyverno test .  # 运行 test 目录下的所有测试
```

---

## 二、Validate 策略（生产级）

### 2.1 Pod 安全策略

```yaml
# 策略 1：禁止特权容器
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-privileged
  annotations:
    policies.kyverno.io/title: Disallow Privileged Containers
    policies.kyverno.io/category: Pod Security Standards
    policies.kyverno.io/severity: medium
spec:
  validationFailureAction: Enforce    # Enforce=阻止, Audit=只记录
  background: true                     # 后台扫描现有资源
  rules:
  - name: privileged-containers
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Privileged containers are not allowed"
      pattern:
        spec:
          containers:
          - securityContext:
              =(privileged): "false"    # =() 表示如果存在则必须为 false

---
# 策略 2：禁止 root 用户
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-run-as-non-root
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: check-run-as-non-root
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Running as root is not allowed. Set runAsNonRoot: true"
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
          containers:
          - securityContext:
              allowPrivilegeEscalation: false

---
# 策略 3：要求资源限制
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-resources
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: check-resources
    match:
      resources:
        kinds:
        - Deployment
        - StatefulSet
        - DaemonSet
        - Job
    validate:
      message: "CPU and memory limits and requests are required"
      pattern:
        spec:
          template:
            spec:
              containers:
              - resources:
                  limits:
                    memory: "?*"        # ?* 表示必须存在且非空
                    cpu: "?*"
                  requests:
                    memory: "?*"
                    cpu: "?*"

---
# 策略 4：禁止 latest 标签
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-latest-tag
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: validate-image-tag
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Using 'latest' tag is not allowed"
      pattern:
        spec:
          containers:
          - image: "!*:latest"           # ! 表示不匹配

---
# 策略 5：禁止 hostPath
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: disallow-host-path
spec:
  validationFailureAction: Enforce
  background: true
  rules:
  - name: check-host-path
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "HostPath volumes are not allowed"
      pattern:
        spec:
          =(volumes):                     # =() 表示如果存在 volumes
          - X(hostPath): "null"           # X() 表示该字段不能存在
```

### 2.2 高级验证策略

```yaml
# 策略 6：条件验证（any/all）
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-service-external-ips
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-external-ips
    match:
      resources:
        kinds:
        - Service
    validate:
      message: "Service externalIPs are restricted"
      deny:
        conditions:
          any:
          - key: "{{ request.object.spec.externalIPs[] }}"
            operator: AnyNotIn
            value: ["10.0.0.0/8", "172.16.0.0/12"]  # 只允许内网 IP

---
# 策略 7：变量替换和上下文
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-ingress-host
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-host
    match:
      resources:
        kinds:
        - Ingress
    context:
    - name: hosts
      apiCall:
        urlPath: "/apis/networking.k8s.io/v1/namespaces/{{request.namespace}}/ingresses"
        jmesPath: "items[].spec.rules[].host"
    validate:
      message: "Ingress host already exists"
      deny:
        conditions:
        - key: "{{ request.object.spec.rules[].host }}"
          operator: AnyIn
          value: "{{ hosts }}"

---
# 策略 8：正则表达式验证
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: validate-labels
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-team-label
    match:
      resources:
        kinds:
        - Pod
        - Deployment
        - Service
    validate:
      message: "Resource must have team label matching pattern"
      pattern:
        metadata:
          labels:
            team: "?*"
      # 使用预定义条件
      deny:
        conditions:
        - key: "{{ request.object.metadata.labels.team }}"
          operator: NotEquals
          value: "?*"

---
# 策略 9：验证 Pod 与 Service 的端口一致性
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: validate-service-port
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-service-port
    match:
      resources:
        kinds:
        - Service
    context:
    - name: podPorts
      apiCall:
        urlPath: "/api/v1/namespaces/{{request.namespace}}/pods"
        jmesPath: "items[].spec.containers[].ports[].containerPort"
    validate:
      message: "Service targetPort must match a Pod containerPort"
      deny:
        conditions:
        - key: "{{ request.object.spec.ports[].targetPort }}"
          operator: AnyNotIn
          value: "{{ podPorts }}"
```

---

## 三、Mutate 策略

### 3.1 自动标签和注解

```yaml
# 策略 1：自动添加资源标签
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
  - name: add-labels
    match:
      resources:
        kinds:
        - Pod
        - Deployment
        - Service
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            team: "{{request.userInfo.extra.teams[0]}}"    # 从用户信息获取
            managed-by: kyverno
            created-at: "{{request.operation}}"

---
# 策略 2：自动注入 Sidecar
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: inject-istio-sidecar
spec:
  rules:
  - name: inject-sidecar
    match:
      resources:
        kinds:
        - Deployment
        namespaces:
        - "*"
    preconditions:
    - key: "{{ request.object.metadata.labels.istio-injection }}"
      operator: Equals
      value: enabled
    mutate:
      patchStrategicMerge:
        spec:
          template:
            spec:
              containers:
              - name: istio-proxy
                image: istio/proxyv2:1.19.0
                args:
                - proxy
                - sidecar
                env:
                - name: ISTIO_META_MESH_ID
                  value: cluster.local
                volumeMounts:
                - name: istio-envoy
                  mountPath: /etc/istio/proxy
              volumes:
              - name: istio-envoy
                emptyDir:
                  medium: Memory

---
# 策略 3：自动添加资源配额
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
        - Pod
    mutate:
      patchStrategicMerge:
        spec:
          containers:
          - (name): "*"              # () 表示对所有容器
            resources:
              requests:
                +(cpu): "100m"       # +() 表示如果不存在则添加
                +(memory): "128Mi"
              limits:
                +(cpu): "500m"
                +(memory): "512Mi"
```

---

## 四、Generate 策略

### 4.1 自动资源生成

```yaml
# 策略 1：创建 Namespace 时自动创建 ResourceQuota
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-resourcequota
spec:
  rules:
  - name: generate-quota
    match:
      resources:
        kinds:
        - Namespace
    generate:
      apiVersion: v1
      kind: ResourceQuota
      name: default-quota
      namespace: "{{request.object.metadata.name}}"
      synchronize: true              # 同步更新
      data:
        spec:
          hard:
            requests.cpu: "20"
            requests.memory: 100Gi
            pods: "50"
            services: "20"

---
# 策略 2：创建 Namespace 时自动创建 NetworkPolicy
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-networkpolicy
spec:
  rules:
  - name: generate-default-deny
    match:
      resources:
        kinds:
        - Namespace
    exclude:
      resources:
        namespaces:
        - kube-system
        - kyverno
        - monitoring
    generate:
      apiVersion: networking.k8s.io/v1
      kind: NetworkPolicy
      name: default-deny-all
      namespace: "{{request.object.metadata.name}}"
      synchronize: true
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress

---
# 策略 3：创建 Service 时自动生成监控配置
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-servicemonitor
spec:
  rules:
  - name: generate-monitor
    match:
      resources:
        kinds:
        - Service
        namespaces:
        - production
    preconditions:
    - key: "{{ request.object.metadata.labels.monitoring }}"
      operator: Equals
      value: enabled
    generate:
      apiVersion: monitoring.coreos.com/v1
      kind: ServiceMonitor
      name: "{{request.object.metadata.name}}"
      namespace: monitoring
      synchronize: true
      data:
        spec:
          selector:
            matchLabels: "{{request.object.metadata.labels}}"
          endpoints:
          - port: metrics
            interval: 30s
```

---

## 五、VerifyImages 策略

```yaml
# 镜像签名验证
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
  - name: verify-cosign-signature
    match:
      resources:
        kinds:
        - Pod
    verifyImages:
    - imageReferences:
      - "mycompany/*"
      - "ghcr.io/mycompany/*"
      attestors:
      - entries:
        - keys:
            publicKeys: |
              -----BEGIN PUBLIC KEY-----
              MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXAMPLE...
              -----END PUBLIC KEY-----
      required: true
      mutateDigest: true              # 自动替换为 digest
      verifyDigest: true              # 验证 digest

---
# 镜像来源限制
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  rules:
  - name: validate-registries
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Only approved registries are allowed"
      pattern:
        spec:
          containers:
          - image: "my-registry.io/* | ghcr.io/mycompany/* | registry.cn-hangzhou.aliyuncs.com/*"
```

---

## 六、策略测试

```yaml
# test/kyverno-test.yaml
apiVersion: cli.kyverno.io/v1alpha1
kind: Test
metadata:
  name: pod-security-tests
policies:
- ../policies/disallow-privileged.yaml
resources:
- ../resources/test-pods.yaml
results:
# 测试 1：特权容器应该被拒绝
- policy: disallow-privileged
  rule: privileged-containers
  resource: privileged-pod
  kind: Pod
  result: fail

# 测试 2：非特权容器应该通过
- policy: disallow-privileged
  rule: privileged-containers
  resource: normal-pod
  kind: Pod
  result: pass

# 测试 3：缺少资源限制应该被拒绝
- policy: require-resources
  rule: check-resources
  resource: no-resources-pod
  kind: Pod
  result: fail

# test-pods.yaml
apiVersion: v1
kind: Pod
metadata:
  name: privileged-pod
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      privileged: true          # 应该被拒绝
---
apiVersion: v1
kind: Pod
metadata:
  name: normal-pod
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      privileged: false         # 应该通过
    resources:
      limits:
        cpu: "100m"
        memory: "128Mi"
      requests:
        cpu: "100m"
        memory: "128Mi"
```

---

## 七、监控与报告

```yaml
# PolicyReport（自动生成的合规报告）
apiVersion: wgpolicyk8s.io/v1alpha2
kind: ClusterPolicyReport
metadata:
  name: cluster-policy-report
results:
- policy: disallow-privileged
  rule: privileged-containers
  category: Pod Security
  severity: medium
  result: fail
  resources:
  - apiVersion: v1
    kind: Pod
    name: bad-pod
    namespace: default
  message: "Privileged containers are not allowed"

# 查看报告
kubectl get policyreport -A
kubectl get clusterpolicyreport

# 使用 Grafana 可视化合规状态
```

---

## 八、面试要点

```
Q: Kyverno 与 OPA/Gatekeeper 的区别？

A: 核心差异在语言和集成：

   Kyverno：
   - 使用 YAML（K8s 原生语法）
   - 与 K8s API 深度集成
   - 支持 generate/mutate/validate/verifyImages
   - 学习曲线低（会用 K8s 就会用 Kyverno）
   - 性能更好（无 Rego 编译开销）
   - 社区相对较小
   
   OPA/Gatekeeper：
   - 使用 Rego 语言（专用 DSL）
   - 通用策略引擎（不限于 K8s）
   - 更灵活、表达能力更强
   - 学习曲线高（需要学 Rego）
   - 社区更大、生态更丰富
   
   选择建议：
   - 纯 K8s 环境：Kyverno（简单高效）
   - 多平台策略：OPA（统一策略语言）
   - 复杂逻辑：OPA（Rego 表达能力更强）

Q: Kyverno 的 failurePolicy 怎么选？

A: 
   Enforce：
   - 策略验证失败时，阻止请求
   - 适用于：安全策略、合规要求
   - 风险：Kyverno 故障时可能阻止所有请求
   
   Audit：
   - 策略验证失败时，允许请求但记录违规
   - 适用于：新策略上线初期、非关键策略
   - 安全：不影响业务连续性
   
   建议：
   - 关键安全策略：Enforce
   - 新策略上线：先 Audit 观察，再切换到 Enforce
   - 监控 Audit 结果，及时调整策略

Q: 如何处理 Kyverno 策略冲突？

A: 策略冲突场景：
   1. 多个 Mutate 策略修改同一字段：
      - Kyverno 按策略名称字母顺序执行
      - 后执行的会覆盖先执行的
      - 建议：使用唯一的字段路径，或明确执行顺序
   
   2. Validate 和 Mutate 冲突：
      - Mutate 先执行，Validate 后执行
      - 如果 Mutate 后的结果不满足 Validate，请求被拒绝
      - 建议：确保 Mutate 的结果满足所有 Validate
   
   3. 策略与 Admission Webhook 冲突：
      - Kyverno 是 MutatingAdmissionWebhook（order: 10）
      - 其他 webhook 可能在之前或之后执行
      - 建议：reinvocationPolicy: IfNeeded
```
