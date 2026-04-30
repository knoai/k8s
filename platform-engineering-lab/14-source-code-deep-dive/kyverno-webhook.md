# 源码分析：Kyverno Webhook 实现

> Kyverno 是 K8s 原生策略引擎，通过 Dynamic Admission Webhook 实现策略执行。
> 本节深入分析其 webhook 注册、请求处理、变量替换和报告生成的完整链路。

---

## 整体架构

```
K8s API Server
       │
       │ 1. 创建 Pod
       ▼
┌─────────────────────────────┐
│  MutatingAdmissionWebhook   │
│  kyverno-resource-mutating  │
│  (failurePolicy: Fail)      │
└─────────────┬───────────────┘
              │ HTTPS (9443)
              ▼
       Kyverno Admission Controller
              │
              ├─ 2. 反序列化请求 (AdmissionReview)
              ├─ 3. 匹配策略 (Policy Engine)
              ├─ 4. 变量替换 (JMESPath/Variables)
              ├─ 5. 执行规则 (Mutate/Validate/Generate)
              ├─ 6. 构建响应 (JSON Patch / Allowed/Denied)
              │
              ▼
       返回 AdmissionResponse
              │
              ▼
       API Server 执行（或拒绝）请求
              │
              ├─ 7. 背景扫描 (Background Scan)
              │   Kyverno Reports Controller
              │   定期检查现有资源合规性
              │
              └─ 8. 事件/报告生成
                  PolicyReport CR
```

---

## Webhook 注册机制

### 1.1 自动注册流程

```go
// pkg/controllers/webhook/controller.go
// Kyverno 启动时自动创建 ValidatingWebhookConfiguration 和 MutatingWebhookConfiguration

func (c *controller) reconcile(ctx context.Context, logger logr.Logger, key string, namespace string, name string) error {
    // 1. 获取所有 Policy/ClusterPolicy
    policies, err := c.policyLister.List(labels.Everything())
    
    // 2. 根据策略计算需要的 webhook 配置
    webhookCfgs := c.buildWebhookConfigs(policies)
    
    // 3. 创建/更新 ValidatingWebhookConfiguration
    if err := c.reconcileValidatingWebhookConfiguration(ctx, webhookCfgs.validating); err != nil {
        return err
    }
    
    // 4. 创建/更新 MutatingWebhookConfiguration
    if err := c.reconcileMutatingWebhookConfiguration(ctx, webhookCfgs.mutating); err != nil {
        return err
    }
    
    // 5. 更新 CA Bundle（自签名证书）
    if err := c.updateCABundle(ctx); err != nil {
        return err
    }
}
```

### 1.2 Webhook 配置生成

```yaml
# Kyverno 自动生成的 ValidatingWebhookConfiguration
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: kyverno-resource-validating-webhook-cfg
webhooks:
- name: validate.kyverno.svc
  clientConfig:
    service:
      namespace: kyverno
      name: kyverno-svc
      path: /validate
      port: 443
    caBundle: <base64-encoded-ca>  # Kyverno 自签名证书
  rules:
  - apiGroups: ["*"]
    apiVersions: ["*"]
    operations: ["CREATE", "UPDATE", "DELETE"]
    resources: ["*/*"]             # 监控所有资源
  failurePolicy: Fail              # 失败时拒绝请求
  sideEffects: None
  admissionReviewVersions: ["v1"]
  # 关键：namespaceSelector 排除 kyverno 自身命名空间
  namespaceSelector:
    matchExpressions:
    - key: kubernetes.io/metadata.name
      operator: NotIn
      values: [kyverno]
  # 关键：objectSelector 排除 kyverno 自身的 Pod
  objectSelector:
    matchExpressions:
    - key: app.kubernetes.io/part-of
      operator: NotIn
      values: [kyverno]
  timeoutSeconds: 10
```

```yaml
# Kyverno 自动生成的 MutatingWebhookConfiguration
apiVersion: admissionregistration.k8s.io/v1
kind: MutatingWebhookConfiguration
metadata:
  name: kyverno-resource-mutating-webhook-cfg
webhooks:
- name: mutate.kyverno.svc
  clientConfig:
    service:
      namespace: kyverno
      name: kyverno-svc
      path: /mutate
  rules:
  - apiGroups: ["*"]
    apiVersions: ["*"]
    operations: ["CREATE", "UPDATE"]
    resources: ["*/*"]
  failurePolicy: Fail
  reinvocationPolicy: IfNeeded   # 允许被其他 webhook 再次调用
  sideEffects: None
  timeoutSeconds: 10
```

### 1.3 证书管理

```go
// pkg/tls/certmanager.go
// Kyverno 使用自签名证书，通过 Secret 存储

func (c *certManager) Run(ctx context.Context) {
    // 1. 生成 CA 私钥和证书
    caCert, caKey, err := generateCA()
    
    // 2. 生成服务器证书（CN = kyverno-svc.kyverno.svc）
    serverCert, serverKey, err := generateCert(caCert, caKey, 
        "kyverno-svc.kyverno.svc",
        "kyverno-svc.kyverno.svc.cluster.local",
    )
    
    // 3. 存储到 Secret
    secret := &corev1.Secret{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "kyverno-svc.kyverno.svc-tls-pair",
            Namespace: "kyverno",
        },
        Type: corev1.SecretTypeTLS,
        Data: map[string][]byte{
            corev1.TLSCertKey:       serverCert,
            corev1.TLSPrivateKeyKey: serverKey,
            "ca.crt":                caCert,
        },
    }
    c.client.Update(ctx, secret)
    
    // 4. 将 CA Bundle 注入 Webhook 配置
    c.injectCABundle(ctx, caCert)
}

// 证书轮换周期：默认 1 年
// 提前 30 天自动轮换
```

---

## 请求处理流程

### 2.1 HTTP Handler 入口

```go
// pkg/webhooks/server.go

func (s *server) handlerFunc(
    metricsHandler ...http.HandlerFunc,
) http.HandlerFunc {
    return func(writer http.ResponseWriter, request *http.Request) {
        // 1. 记录请求指标
        startTime := time.Now()
        
        // 2. 读取请求体
        body, err := io.ReadAll(request.Body)
        if err != nil {
            http.Error(writer, "can't read body", http.StatusBadRequest)
            return
        }
        
        // 3. 反序列化 AdmissionReview
        admissionReview := &admissionv1.AdmissionReview{}
        if _, _, err := s.codecs.Decode(body, nil, admissionReview); err != nil {
            http.Error(writer, "can't decode body", http.StatusBadRequest)
            return
        }
        
        // 4. 处理请求
        admissionResponse := s.handle(request.Context(), admissionReview.Request)
        
        // 5. 构建响应
        response := &admissionv1.AdmissionReview{
            TypeMeta: admissionReview.TypeMeta,
            Response: admissionResponse,
        }
        response.Response.UID = admissionReview.Request.UID
        
        // 6. 序列化并返回
        responseJSON, err := json.Marshal(response)
        writer.Header().Set("Content-Type", "application/json")
        writer.Write(responseJSON)
        
        // 7. 记录指标
        duration := time.Since(startTime)
        s.metrics.RecordAdmissionDuration(
            admissionReview.Request.Operation,
            admissionReview.Request.Kind,
            duration,
        )
    }
}
```

### 2.2 策略匹配

```go
// pkg/engine/match.go

func doesResourceMatchCondition(
    condition kyvernov1.Condition,
    resource unstructured.Unstructured,
    admissionInfo kyvernov1.RequestInfo,
) (bool, error) {
    // 1. 检查资源类型匹配
    if condition.GetResources() != nil {
        if !matchResources(condition.GetResources(), resource) {
            return false, nil
        }
    }
    
    // 2. 检查 subjects（用户/组/ServiceAccount）
    if condition.GetSubjects() != nil {
        if !matchSubjects(condition.GetSubjects(), admissionInfo) {
            return false, nil
        }
    }
    
    // 3. 检查 roles/clusterRoles
    if condition.GetRoles() != nil || condition.GetClusterRoles() != nil {
        if !matchRoles(condition, admissionInfo) {
            return false, nil
        }
    }
    
    // 4. 检查 namespaceSelector
    if condition.GetNamespaceSelector() != nil {
        if !matchNamespaceSelector(condition.GetNamespaceSelector(), resource.GetNamespace()) {
            return false, nil
        }
    }
    
    // 5. 检查 objectSelector
    if condition.GetObjectSelector() != nil {
        if !matchObjectSelector(condition.GetObjectSelector(), resource) {
            return false, nil
        }
    }
    
    return true, nil
}
```

### 2.3 规则执行引擎

```go
// pkg/engine/engine.go

func (e *engine) invokeRule(
    ctx context.Context,
    logger logr.Logger,
    policyContext *PolicyContext,
    rule *kyvernov1.Rule,
    ruleType RuleType,
) *RuleResponse {
    switch ruleType {
    case Validation:
        // 执行验证规则
        return e.validate(ctx, logger, policyContext, rule)
    case Mutation:
        // 执行变异规则
        return e.mutate(ctx, logger, policyContext, rule)
    case Generation:
        // 执行生成规则
        return e.generate(ctx, logger, policyContext, rule)
    case ImageVerification:
        // 执行镜像验证规则
        return e.verifyImages(ctx, logger, policyContext, rule)
    }
}
```

---

## Mutation 实现

### 3.1 Strategic Merge Patch

```go
// pkg/engine/mutate/patch/strategicMergePatch.go

func applyStrategicMergePatch(
    resource unstructured.Unstructured,
    patch kyvernov1.Any,
) (unstructured.Unstructured, error) {
    // 1. 将 patch 转换为 JSON
    patchBytes, err := patch.ToJson()
    
    // 2. 使用 Strategic Merge Patch 算法
    // 这是 K8s 特有的 patch 方式，理解列表合并语义
    // 例如：对于容器列表， strategic merge patch 会根据 name 字段合并
    patchedBytes, err := strategicpatch.StrategicMergePatch(
        originalBytes,
        patchBytes,
        resource.Object,
    )
    
    // 3. 解析为 unstructured
    var patched unstructured.Unstructured
    json.Unmarshal(patchedBytes, &patched)
    
    return patched, nil
}
```

### 3.2 实际 Mutation 示例

```yaml
# 策略定义：自动添加资源标签
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-team-label
spec:
  rules:
  - name: add-label
    match:
      resources:
        kinds:
        - Deployment
        - StatefulSet
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            team: platform-engineering
            managed-by: kyverno
```

```go
// Kyverno 处理后的 AdmissionResponse
{
  "uid": "abc12345-6789-0123-4567-890abcdef012",
  "allowed": true,
  "patchType": "JSONPatch",
  "patch": "W3sib3AiOiAiYWRkIiwgInBhdGgiOiAiL21ldGFkYXRhL2xhYmVscy90ZWFtIiwgInZhbHVlIjogInBsYXRmb3JtLWVuZ2luZWVyaW5nIn0seyJvcCI6ICJhZGQiLCAicGF0aCI6ICIvbWV0YWRhdGEvbGFiZWxzL21hbmFnZWQtYnkiLCAidmFsdWUiOiAia3l2ZXJubyJ9XQ=="
}

// Base64 解码后的 patch：
[
  {"op": "add", "path": "/metadata/labels/team", "value": "platform-engineering"},
  {"op": "add", "path": "/metadata/labels/managed-by", "value": "kyverno"}
]
```

---

## Validation 实现

### 4.1 模式验证（Pattern Matching）

```go
// pkg/engine/validate/pattern.go

func validateResourceWithPattern(
    resource interface{},
    pattern interface{},
) (bool, string) {
    switch typedPattern := pattern.(type) {
    case map[string]interface{}:
        // 递归验证 map 的每个字段
        return validateMap(resource, typedPattern)
    case []interface{}:
        // 验证列表
        return validateList(resource, typedPattern)
    case string:
        // 特殊操作符：
        // "*" -> 匹配任何值
        // "?(...)") -> 存在性判断
        // "X | Y" -> 或操作
        return validateString(resource, typedPattern)
    default:
        // 精确匹配
        return resource == pattern, ""
    }
}
```

### 4.2 条件验证（Any/All）

```yaml
# 验证规则示例
validate:
  message: "容器必须设置资源限制"
  any:
  - resources:
      kinds:
      - Deployment
  pattern:
    spec:
      template:
        spec:
          containers:
          - resources:
              limits:
                memory: "?*"    # 必须存在且非空
                cpu: "?*"
  deny:
    conditions:
      all:
      - key: "{{ request.object.spec.replicas }}"
        operator: GreaterThan
        value: 10
```

```go
// 变量替换后执行验证
func (v *validator) validate(ctx context.Context) *RuleResponse {
    // 1. 变量替换
    substitutedPattern, err := v.substituteVariables(v.rule.Validation.GetPattern())
    
    // 2. 模式匹配
    if v.rule.Validation.GetPattern() != nil {
        if passed, msg := validateResourceWithPattern(
            v.policyContext.NewResource().Object,
            substitutedPattern,
        ); !passed {
            return ruleError(v.rule, validation, msg, nil)
        }
    }
    
    // 3. 条件判断
    if v.rule.Validation.GetDeny() != nil {
        if denied, msg := v.checkDenyConditions(); denied {
            return ruleError(v.rule, validation, msg, nil)
        }
    }
    
    return ruleSuccess(v.rule, validation)
}
```

---

## 变量替换（JMESPath）

### 5.1 变量上下文

```go
// pkg/engine/variables/vars.go

func (v *variableResolver) resolve(ctx context.Context, variable string) (interface{}, error) {
    // 内置变量：
    // {{request.userInfo}} -> 请求用户信息
    // {{request.operation}} -> CREATE/UPDATE/DELETE
    // {{request.namespace}} -> 目标命名空间
    // {{request.object}} -> 完整请求对象
    // {{request.oldObject}} -> 更新前的对象（UPDATE 操作）
    // {{request.roles}} -> 用户角色列表
    // {{request.clusterRoles}} -> 用户集群角色列表
    
    // 替换逻辑：
    // 1. 去掉 {{ 和 }}
    // 2. 解析 JMESPath 表达式
    // 3. 在上下文中查找值
    
    jmesPath := strings.Trim(variable, "{}")
    result, err := applyJMESPath(jmesPath, v.context)
    return result, err
}
```

### 5.2 JMESPath 示例

```yaml
# 策略中使用变量
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
      message: "只能使用白名单镜像仓库"
      pattern:
        spec:
          containers:
          - image: "my-registry.io/* | ghcr.io/my-org/*"
---
# 更复杂的变量使用
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-network-policy
spec:
  rules:
  - name: default-deny
    match:
      resources:
        kinds:
        - Namespace
    generate:
      kind: NetworkPolicy
      name: default-deny-all
      namespace: "{{request.object.metadata.name}}"  # 使用变量
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress
```

---

## 性能优化

### 6.1 缓存机制

```go
// pkg/utils/admission/cached.go

// Kyverno 缓存已编译的策略和 JMESPath 查询
type cache struct {
    policies      map[string]*kyvernov1.ClusterPolicy
    jmesPathCache map[string]jmespath.JMESPath
    compiledRules map[string]*compiledRule
}

func (c *cache) getCompiledRule(rule *kyvernov1.Rule) *compiledRule {
    key := fmt.Sprintf("%s/%s", rule.Name, rule.GetType())
    
    if compiled, ok := c.compiledRules[key]; ok {
        return compiled
    }
    
    // 编译规则（预解析 JMESPath、正则等）
    compiled := compileRule(rule)
    c.compiledRules[key] = compiled
    return compiled
}
```

### 6.2 并发处理

```go
// pkg/webhooks/resource/handlers.go

func (h *handlers) handleMutation(
    ctx context.Context,
    request *admissionv1.AdmissionRequest,
) *admissionv1.AdmissionResponse {
    // 1. 匹配策略（并行）
    matchedPolicies := h.matchPolicies(ctx, request)
    
    // 2. 执行 mutation（顺序执行，因为 patch 有依赖关系）
    patches := []jsonpatch.JsonPatchOperation{}
    for _, policy := range matchedPolicies {
        result := h.applyMutation(ctx, policy, request)
        patches = append(patches, result.Patches...)
    }
    
    // 3. 合并 patch
    mergedPatch := jsonpatch.MergePatch(patches)
    
    // 4. 返回响应
    patchBytes, _ := mergedPatch.MarshalJSON()
    return &admissionv1.AdmissionResponse{
        Allowed: true,
        Patch:   patchBytes,
        PatchType: func() *admissionv1.PatchType {
            pt := admissionv1.PatchTypeJSONPatch
            return &pt
        }(),
    }
}
```

### 6.3 性能基准

```
Kyverno 性能指标（标准测试环境）：

场景                        P50      P99      说明
─────────────────────────────────────────────────────────
简单 Mutation（添加标签）    5ms      20ms     1 条规则
复杂 Mutation（JSON Patch）  15ms     50ms     5 条规则
简单 Validation              3ms      10ms     模式匹配
复杂 Validation（JMESPath）  20ms     80ms     多变量替换
Image Verification           100ms    500ms    调用 cosign/notary
Generate                     50ms     200ms    创建新资源

大规模集群优化：
- Policy 数量：建议 < 100 条（过多影响启动时间）
- Webhook timeout：建议 10-15 秒（Image Verification 需要更长）
- 并发处理：默认 20 个 worker，可增大到 50
- 缓存策略：启用 rule cache 可减少 50% 处理时间
```

---

## 关键源码文件索引

| 功能 | 文件路径 | 核心函数 |
|------|---------|---------|
| Webhook 注册 | `pkg/controllers/webhook/controller.go` | `reconcile()` |
| 证书管理 | `pkg/tls/certmanager.go` | `Run()` |
| HTTP Server | `pkg/webhooks/server.go` | `handlerFunc()` |
| 策略匹配 | `pkg/engine/match.go` | `doesResourceMatchCondition()` |
| Mutation | `pkg/engine/mutate/` | `applyStrategicMergePatch()` |
| Validation | `pkg/engine/validate/` | `validateResourceWithPattern()` |
| 变量替换 | `pkg/engine/variables/vars.go` | `resolve()` |
| JMESPath | `pkg/engine/jmespath/` | `execute()` |
| 报告生成 | `pkg/controllers/report/` | `reconcile()` |

---

## 面试要点

```
Q: Kyverno 与 OPA/Gatekeeper 的区别？
A: - Kyverno: 使用 YAML 原生语法，无需学习 Rego
   - Kyverno: 直接操作 K8s 资源，支持 generate/mutate
   - OPA: 通用策略引擎，不仅限于 K8s
   - Kyverno: 性能更好（无 Rego 编译开销）
   - OPA: 更灵活，支持复杂逻辑

Q: Kyverno Webhook 的 failurePolicy 怎么选？
A: - Enforce 场景：Fail（策略必须执行）
   - Audit 场景：Ignore（不阻塞请求，但记录违规）
   - 注意：Webhook 服务不可用时，Fail 会导致所有请求被拒绝！
   - 建议：关键策略用 Fail，非关键用 Ignore

Q: Kyverno 的 reinvocationPolicy 作用？
A: - IfNeeded：允许 API Server 在 Kyverno 修改后，
      再次调用其他 mutating webhook
   - Never：只调用一次
   - 用于多个 webhook 协作的场景

Q: 为什么 Kyverno 用 Strategic Merge Patch 而不是 JSON Patch？
A: - Strategic Merge Patch 理解 K8s 资源语义
   - 例如：合并容器列表时根据 name 字段匹配
   - JSON Patch 是盲操作，容易破坏资源结构
```
