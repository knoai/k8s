# 源码深度解析：Kyverno Webhook 生命周期与请求处理

> Kyverno 的核心是一个 Kubernetes Dynamic Admission Webhook。
> 理解它的请求处理流程、缓存机制、性能优化和故障模式，
> 是平台工程师面试和 production troubleshooting 的必备能力。

---

## 第一章：Dynamic Admission Webhook 原理

### 1.1 K8s Admission Control 架构

```
用户请求 → API Server → 以下阶段顺序执行：

  Phase 1: Authentication（认证）
    - 验证用户身份（Token、证书）
    - 不依赖 Webhook
    
  Phase 2: Authorization（授权）
    - RBAC 检查
    - 不依赖 Webhook
    
  Phase 3: Mutating Admission（变异准入）
    - 按注册顺序执行所有 Mutating Webhook
    - Kyverno 的 mutate 规则在此执行
    - 可以修改请求中的资源对象
    
  Phase 4: Object Schema Validation（模式验证）
    - 验证资源是否符合 OpenAPI 模式
    
  Phase 5: Validating Admission（验证准入）
    - 按注册顺序执行所有 Validating Webhook
    - Kyverno 的 validate 规则在此执行
    - 只能拒绝，不能修改
    
  Phase 6: etcd 写入
    - 所有准入通过后，写入 etcd

关键特性：
  - Mutating Webhook 先执行，Validating Webhook 后执行
  - 如果任何 Webhook 返回失败，请求被拒绝
  - Webhook 超时后，请求根据 failurePolicy 决定（Ignore 或 Fail）
```

### 1.2 Kyverno Webhook 注册

```yaml
# Kyverno 安装时自动注册以下 Webhook

# 1. 资源验证 Webhook
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: kyverno-resource-validating-webhook-cfg
webhooks:
- name: validate.kyverno.svc-fail
  failurePolicy: Fail          # 超时或错误时拒绝请求
  sideEffects: NoneOnDryRun
  admissionReviewVersions: ["v1"]
  rules:                       # 匹配所有资源类型
  - apiGroups: ["*"]
    apiVersions: ["*"]
    operations: ["CREATE", "UPDATE", "DELETE", "CONNECT"]
    resources: ["*"]
  clientConfig:
    service:
      namespace: kyverno
      name: kyverno-svc
      path: /validate
      port: 443
  namespaceSelector:           # 可配置排除某些命名空间
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: [kyverno, kube-system]

# 2. 资源变异 Webhook
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kyverno-resource-mutating-webhook-cfg
webhooks:
- name: mutate.kyverno.svc-fail
  failurePolicy: Fail
  sideEffects: NoneOnDryRun
  admissionReviewVersions: ["v1"]
  rules:
  - apiGroups: ["*"]
    apiVersions: ["*"]
    operations: ["CREATE", "UPDATE"]
    resources: ["*"]
  clientConfig:
    service:
      namespace: kyverno
      name: kyverno-svc
      path: /mutate
      port: 443
```

### 1.3 请求处理时序

```
用户: kubectl apply -f deployment.yaml

  │
  ▼
API Server
  │
  ├── POST /apis/apps/v1/namespaces/default/deployments
  │
  ├── Mutating Webhook 调用
  │     │
  │     ├── Kyverno Mutate
  │     │     1. 匹配 Policy（按资源类型、标签、命名空间）
  │     │     2. 执行 mutate 规则（ StrategicMergePatch / JSONPatch ）
  │     │     3. 返回修改后的资源
  │     │
  │     └── 其他 Mutating Webhook
  │
  ├── Schema 验证
  │
  ├── Validating Webhook 调用
  │     │
  │     ├── Kyverno Validate
  │     │     1. 匹配 Policy
  │     │     2. 执行 validate 规则（pattern、deny、anyPattern）
  │     │     3. 如果失败，返回 Allow=false + 错误信息
  │     │
  │     └── 其他 Validating Webhook
  │
  ├── 写入 etcd
  │
  └── 返回响应给用户

时序关键数字：
  - API Server → Webhook 网络延迟：1-5ms（同节点）或 5-20ms（跨节点）
  - Kyverno 策略匹配：1-10ms（取决于 Policy 数量）
  - Kyverno 规则执行：1-50ms（取决于规则复杂度）
  - Webhook 总延迟：5-100ms
  - API Server 默认 Webhook 超时：10s
```

---

## 第二章：Kyverno 内部架构

### 2.1 控制器组件

```
Kyverno 部署包含 3 个核心控制器：

┌─────────────────────────────────────────────────────────────┐
│                    kyverno-admission-controller                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐  │
│  │ Webhook Server  │  │ Policy Engine   │  │ Rule Engine │  │
│  │ (HTTP/gRPC)     │  │ (Policy Cache)  │  │ (JMESPath)  │  │
│  └────────┬────────┘  └─────────────────┘  └─────────────┘  │
│           │                                                   │
│           │  处理 Admission Review 请求                         │
│           │  - /validate                                      │
│           │  - /mutate                                        │
│           │  - /verifyimages                                  │
└───────────┼───────────────────────────────────────────────────┘
            │
┌───────────▼───────────────────────────────────────────────────┐
│                   kyverno-background-controller                │
│  - 后台扫描现有资源（background scans）                         │
│  - 生成 PolicyReport                                         │
│  - 处理 generate 规则的同步                                    │
└───────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                   kyverno-reports-controller                   │
│  - 聚合 PolicyReport 到 ClusterPolicyReport                  │
│  - 生成审计报告                                               │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Policy 缓存机制

```
Kyverno 使用 K8s Informer 缓存所有 Policy：

API Server ←── Watch ──→ Kyverno Policy Cache
                              │
                              ├── ClusterPolicy (集群级)
                              │     ├── require-labels
                              │     ├── disallow-privileged
                              │     └── ...
                              │
                              └── Policy (命名空间级)
                                    └── (较少使用)

缓存优势：
  - Webhook 处理请求时直接从内存读取 Policy
  - 不需要每次查询 API Server
  - 延迟从 50-100ms（API Server 查询）降到 1-10ms（内存访问）

缓存更新：
  - Policy 变更 → Informer 事件 → 更新缓存
  - 延迟：< 1 秒
```

### 2.3 请求处理代码流程

```go
// 简化版请求处理流程

// 1. Webhook Handler 接收请求
func (h *handlers) Mutate(ctx context.Context, request *admissionv1.AdmissionRequest) *admissionv1.AdmissionResponse {
    // request 包含：
    // - UID: 请求唯一标识
    // - Kind: 资源类型（Deployment、Pod 等）
    // - Resource: GVR
    // - Operation: CREATE/UPDATE/DELETE
    // - Object: 请求中的资源对象（已 JSON 解码）
    // - OldObject: 更新前的对象（仅 UPDATE）
    // - DryRun: 是否为试运行
    // - UserInfo: 请求用户信息
    
    // 2. 加载匹配的 Policies
    policies := h.policyCache.GetPolicies(
        engineapi.Kind(request.Kind.Kind),
        engineapi.Namespace(request.Namespace),
    )
    
    // 3. 逐个执行 Policy 中的 rules
    for _, policy := range policies {
        for _, rule := range policy.Spec.Rules {
            // 4. 检查 match 条件
            if !match(request, rule.MatchResources) {
                continue
            }
            
            // 5. 检查 exclude 条件
            if exclude(request, rule.ExcludeResources) {
                continue
            }
            
            // 6. 执行 rule
            if rule.HasMutate() {
                // StrategicMergePatch 或 JSONPatch
                patchedResource := mutate(request.Object, rule.Mutation)
                response.Patch = createPatch(request.Object, patchedResource)
            }
            
            if rule.HasValidate() {
                // pattern、deny、anyPattern 验证
                if !validate(request.Object, rule.Validation) {
                    response.Allowed = false
                    response.Result = &metav1.Status{
                        Message: rule.Validation.Message,
                    }
                    return response
                }
            }
        }
    }
    
    response.Allowed = true
    return response
}
```

---

## 第三章：JMESPath 与变量替换

### 3.1 Kyverno 的变量系统

```
Kyverno 支持在规则中使用变量，这些变量在运行时从请求上下文中提取：

预定义变量：
  {{request.operation}}      -> CREATE, UPDATE, DELETE
  {{request.userInfo.username}} -> admin, system:serviceaccount:default:sa1
  {{request.namespace}}      -> default, kube-system
  {{request.object.metadata.name}} -> pod-name
  {{request.object.spec.containers[0].image}} -> nginx:1.25

JMESPath 表达式：
  {{request.object.spec.containers[*].image}}
    -> ["nginx:1.25", "busybox:latest"]
  
  {{request.object.spec."hostPID"}}
    -> true 或 null

使用场景：
  # 将资源名称注入到标签中
  mutate:
    patchStrategicMerge:
      metadata:
        labels:
          created-by: "{{request.userInfo.username}}"
  
  # 验证镜像标签
  validate:
    pattern:
      spec:
        containers:
        - image: "{{request.namespace}}/*:v*"
```

### 3.2 变量替换的性能影响

```
问题：复杂的 JMESPath 表达式会增加 Webhook 处理延迟

示例对比：
  简单表达式（1-5ms）：
    {{request.object.metadata.name}}
  
  复杂表达式（10-50ms）：
    {{request.object.spec.containers[?securityContext.privileged==`true`].name}}

优化建议：
  1. 避免在 match/exclude 中使用复杂表达式
  2. 预编译 JMESPath 表达式（Kyverno 内部已实现）
  3. 使用 background 模式处理复杂策略（不阻塞 Admission）
```

---

## 第四章：性能优化与监控

### 4.1 Webhook 延迟分析

```bash
# Kyverno 内置 Prometheus 指标

# 1. Admission Review 处理延迟
kyverno_admission_review_duration_seconds_bucket{operation="mutate",resource_kind="Pod"}
# 目标：P99 < 50ms

# 2. 策略执行延迟
kyverno_policy_execution_duration_seconds_bucket{policy="require-labels",rule="check-labels"}
# 目标：P99 < 10ms

# 3. 按资源类型的请求数量
kyverno_admission_requests_total{resource_kind="Deployment",operation="CREATE"}

# 4. PolicyRule 结果统计
kyverno_policy_rule_results_total{policy="require-labels",rule="check-labels",status="pass"}
kyverno_policy_rule_results_total{policy="require-labels",rule="check-labels",status="fail"}
```

### 4.2 生产环境性能调优

```yaml
# Kyverno Helm 安装时的性能优化配置
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --set replicaCount=3 \
  --set resources.limits.cpu=2000m \
  --set resources.limits.memory=2Gi \
  --set admissionController.replicas=3 \
  --set backgroundController.replicas=2 \
  --set features.logging.format=json \
  --set config.webhooks.timeoutSeconds=5  # 默认 10s，调小减少等待

# 策略优化建议：
# 1. 使用 namespaceSelector 排除不需要的命名空间
# 2. 使用 objectSelector 排除系统组件
# 3. 复杂策略使用 background: true（不阻塞 Admission）
# 4. 避免在 mutate 规则中使用复杂 JMESPath
```

---

## 第五章：故障模式与排查

### 5.1 Kyverno Pod 不可用导致全集群拒绝

```
故障现象：
  - 所有 kubectl apply 都失败
  - 错误：Internal error occurred: failed calling webhook ...
  
根因：
  - Kyverno Pod 全部 Crash 或网络不可达
  - API Server 调用 Webhook 超时
  - failurePolicy=Fail → 请求被拒绝

紧急恢复：
  # 方法 1：删除 Webhook 配置（临时）
  kubectl delete validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg
  kubectl delete mutatingwebhookconfiguration kyverno-resource-mutating-webhook-cfg
  
  # 方法 2：修改 failurePolicy 为 Ignore（临时）
  # 但这会导致策略不生效
  
  # 方法 3：修复 Kyverno Pod
  kubectl get pods -n kyverno
  kubectl describe pod -l app.kubernetes.io/name=kyverno -n kyverno
  kubectl logs -l app.kubernetes.io/name=kyverno -n kyverno --tail=100

预防措施：
  1. Kyverno 运行 3 副本 + PodDisruptionBudget
  2. 设置合理的 timeoutSeconds（5-10s）
  3. 监控 Kyverno Pod 健康状态
  4. 使用 namespaceSelector 排除 kyverno 自身命名空间
```

### 5.2 策略匹配性能问题

```
故障现象：
  - kubectl apply 延迟从 100ms 增加到 5s+
  - API Server 日志显示 Webhook 调用超时

排查步骤：
  1. 检查 Kyverno 资源使用
     kubectl top pod -n kyverno
     # CPU 是否满载？内存是否 OOM？
  
  2. 检查 Kyverno 日志
     kubectl logs -l app.kubernetes.io/name=kyverno -n kyverno | grep "slow"
  
  3. 检查 Policy 数量
     kubectl get clusterpolicy | wc -l
     # 如果 > 100 个 Policy，考虑合并或优化
  
  4. 检查是否有复杂 JMESPath
     # 查看 Policy 定义中是否有复杂表达式

优化措施：
  1. 合并相似 Policy（减少匹配次数）
  2. 使用更精确的 match 条件（减少规则执行）
  3. 增加 Kyverno CPU 限制
  4. 将非关键策略改为 background: true
```

---

## 第六章：面试核心考点

```
Q: Kyverno 的 Mutate 和 Validate 分别在 Admission 的哪个阶段执行？

A:
   Mutate 在 Mutating Admission 阶段执行：
   - 在 Schema 验证之前
   - 可以修改请求中的资源对象
   - 多个 Mutating Webhook 按注册顺序执行
   
   Validate 在 Validating Admission 阶段执行：
   - 在 Schema 验证之后
   - 只能拒绝，不能修改
   - 如果任何 Validating Webhook 拒绝，请求失败
   
   为什么分开两个阶段？
   - 先 mutate 后 validate：确保最终对象通过验证
   - 如果 mutate 后发现不符合 validate，直接拒绝

Q: Kyverno Webhook 超时的影响是什么？

A:
   API Server 调用 Webhook 的默认超时是 10 秒。
   如果 Kyverno 在 10 秒内未响应：
   
   failurePolicy=Fail（默认）：
   - 请求被拒绝
   - 返回错误：Internal error occurred: failed calling webhook
   - 影响：全集群无法创建/更新资源
   
   failurePolicy=Ignore：
   - 请求继续处理（不经过 Kyverno）
   - 策略不生效
   - 影响：安全风险
   
   生产建议：
   - 使用 failurePolicy=Fail（安全优先）
   - 保证 Kyverno 高可用（3 副本 + PDB）
   - 设置合理的 timeoutSeconds（5-10s）
   - 监控 kyverno_admission_review_duration_seconds

Q: Kyverno 的 background 模式是什么？什么时候使用？

A:
   background: true：
   - 不阻塞 Admission 请求
   - 由 background-controller 定期扫描现有资源
   -  violations 记录到 PolicyReport
   
   background: false（默认）：
   - 在 Admission 阶段实时验证
   - 阻塞请求
   - 立即返回结果
   
   使用场景：
   - 安全基线策略（禁止特权容器）→ background: false
   - 复杂数据分析策略（如成本标签合规性）→ background: true
   - 新策略上线观察期 → background: true（Audit 模式）
```
