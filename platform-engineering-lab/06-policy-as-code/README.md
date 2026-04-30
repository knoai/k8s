# 06 - 策略即代码（Policy as Code）

策略即代码是平台工程的**安全与合规基线**。它将人工审核转化为自动化规则，确保安全左移（Shift Left）。

---

## 6.1 为什么需要策略即代码？

**传统痛点**：
- 运维人工审核每个 YAML → 瓶颈
- 开发者不知道最佳实践 → 配置错误
- 安全审计时发现问题 → 事后修复成本高
- 不同集群标准不一 → 配置漂移

**策略即代码的价值**：
- ✅ 自动拦截不合规配置
- ✅ 统一多集群安全标准
- ✅ 安全左移：问题在部署前暴露
- ✅ 审计追溯：所有策略变更有 Git 历史

---

## 6.2 技术选型

| 工具 | 语言 | 模式 | 性能 | 学习曲线 | 适用场景 |
|------|------|------|------|---------|---------|
| **Kyverno** | YAML | K8s 原生 Admission | 高 | 低 | K8s 专用，推荐首选 |
| **OPA/Gatekeeper** | Rego | 通用策略引擎 | 高 | 高 | 复杂策略、跨系统 |
| **jsPolicy** | JavaScript | K8s 原生 | 中 | 中 | JS 团队友好 |
| **Kubewarden** | 多语言 | WebAssembly | 高 | 中 | 高性能、多语言 |

**选型建议**：
- **Kyverno**：如果策略主要围绕 K8s 资源（Pod/Service/Ingress），强烈推荐
- **OPA/Gatekeeper**：如果需要跨系统策略（K8s + Terraform + API）

---

## 6.3 Kyverno 深度实践

### 安装

```bash
# Helm 安装
helm repo add kyverno https://kyverno.github.io/kyverno/
helm repo update
helm install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace \
  --set replicaCount=3 \
  --set resources.limits.memory=1Gi
```

### 核心策略类型

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: platform-security-baseline
spec:
  validationFailureAction: Enforce  # Enforce / Audit / Warn
  background: true  # 扫描已有资源
  rules:
  # ─────────────────────────────────────────────
  # 规则 1：禁止特权容器
  # ─────────────────────────────────────────────
  - name: disallow-privileged
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Privileged containers are forbidden"
      pattern:
        spec:
          containers:
          - securityContext:
              allowPrivilegeEscalation: "false"
              privileged: "false"
          =(initContainers):
          - securityContext:
              allowPrivilegeEscalation: "false"
              privileged: "false"

  # ─────────────────────────────────────────────
  # 规则 2：强制只读根文件系统
  # ─────────────────────────────────────────────
  - name: require-ro-rootfs
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Root filesystem must be read-only"
      pattern:
        spec:
          containers:
          - securityContext:
              readOnlyRootFilesystem: true

  # ─────────────────────────────────────────────
  # 规则 3：禁止以 root 运行
  # ─────────────────────────────────────────────
  - name: require-run-as-non-root
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Running as root is not allowed"
      pattern:
        spec:
          securityContext:
            runAsNonRoot: true
          containers:
          - securityContext:
              allowPrivilegeEscalation: false
              =(runAsUser): ">0"

  # ─────────────────────────────────────────────
  # 规则 4：强制资源限制
  # ─────────────────────────────────────────────
  - name: require-resources
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "CPU and memory limits/requests are required"
      pattern:
        spec:
          containers:
          - resources:
              limits:
                memory: "?*"
                cpu: "?*"
              requests:
                memory: "?*"
                cpu: "?*"

  # ─────────────────────────────────────────────
  # 规则 5：禁止 latest 标签
  # ─────────────────────────────────────────────
  - name: disallow-latest-tag
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Using 'latest' tag is not allowed. Use a specific version."
      pattern:
        spec:
          containers:
          - image: "!*:latest"

  # ─────────────────────────────────────────────
  # 规则 6：强制标签
  # ─────────────────────────────────────────────
  - name: require-labels
    match:
      resources:
        kinds:
        - Deployment
        - StatefulSet
        - Service
    validate:
      message: "Required labels are missing"
      pattern:
        metadata:
          labels:
            app.kubernetes.io/name: "?*"
            app.kubernetes.io/component: "?*"
            platform.company.io/team: "?*"
            platform.company.io/cost-center: "?*"

  # ─────────────────────────────────────────────
  # 规则 7：限制镜像仓库
  # ─────────────────────────────────────────────
  - name: restrict-image-registries
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Only approved registries are allowed"
      pattern:
        spec:
          containers:
          - image: "company.registry.io/* | gcr.io/company/* | *.amazonaws.com/*"

  # ─────────────────────────────────────────────
  # 规则 8：禁止 NodePort 服务
  # ─────────────────────────────────────────────
  - name: restrict-nodeport
    match:
      resources:
        kinds:
        - Service
    validate:
      message: "NodePort services are not allowed. Use ClusterIP or LoadBalancer."
      pattern:
        spec:
          type: "!NodePort"

  # ─────────────────────────────────────────────
  # 规则 9：限制 HostPath 使用
  # ─────────────────────────────────────────────
  - name: restrict-hostpath
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "HostPath volumes are restricted"
      pattern:
        spec:
          =(volumes):
          - =(hostPath):
              path: "/tmp/* | /var/log/*"  # 只允许特定路径
```

### 变异规则（Mutate）

自动修改资源，注入最佳实践：

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: add-defaults
spec:
  rules:
  # 自动注入资源请求
  - name: add-default-resources
    match:
      resources:
        kinds:
        - Deployment
    mutate:
      patchStrategicMerge:
        spec:
          template:
            spec:
              containers:
              - (name): "*"
                resources:
                  requests:
                    +(cpu): "100m"
                    +(memory): "256Mi"
                  limits:
                    +(cpu): "2"
                    +(memory): "4Gi"

  # 自动注入网络策略标签
  - name: add-network-policy-label
    match:
      resources:
        kinds:
        - Namespace
    mutate:
      patchStrategicMerge:
        metadata:
          labels:
            +(network-policy): enabled

  # 自动挂载 ServiceAccount Token（禁用自动挂载时）
  - name: disable-automount-sa-token
    match:
      resources:
        kinds:
        - Pod
    mutate:
      patchStrategicMerge:
        spec:
          automountServiceAccountToken: false
```

### 生成规则（Generate）

自动创建关联资源：

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: generate-networkpolicy
spec:
  rules:
  - name: default-deny
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
      name: default-deny
      namespace: "{{request.object.metadata.name}}"
      data:
        spec:
          podSelector: {}
          policyTypes:
          - Ingress
          - Egress
```

---

## 6.4 OPA / Gatekeeper

当需要跨系统策略或复杂逻辑时使用。

### Rego 策略示例

```rego
package k8srequiredlabels

# 拒绝没有必需标签的 Deployment
violation[{"msg": msg}] {
  input.review.object.kind == "Deployment"
  required_labels := {"app.kubernetes.io/name", "app.kubernetes.io/component", "team"}
  missing := required_labels - {key | input.review.object.metadata.labels[key]}
  count(missing) > 0
  msg := sprintf("Deployment must have labels: %v", [missing])
}

# 限制容器只能使用特定镜像仓库
violation[{"msg": msg}] {
  input.review.object.kind == "Pod"
  container := input.review.object.spec.containers[_]
  not startswith(container.image, "company.registry.io/")
  not startswith(container.image, "gcr.io/company/")
  msg := sprintf("Container %v uses unapproved image: %v", [container.name, container.image])
}
```

### 与 Kyverno 对比

| 场景 | Kyverno | OPA/Gatekeeper |
|------|---------|---------------|
| K8s 专用策略 | ✅ 极佳 | ⚠️ 可以但冗余 |
| 跨系统策略（K8s+TF+API） | ❌ 不支持 | ✅ 支持 |
| 学习曲线 | 低（YAML） | 高（Rego） |
| 性能 | 高（原生） | 高（缓存） |
| 社区生态 | 快速增长 | 成熟丰富 |
| 推荐使用 | K8s 平台团队 | 企业安全/合规团队 |

---

## 6.5 策略测试与 CI 集成

### Kyverno CLI 测试

```bash
# 安装 kyverno CLI
brew install kyverno

# 测试策略
kyverno test .

# test.yaml 定义测试用例
tests:
- name: test-disallow-privileged
  policies:
  - disallow-privileged.yaml
  resources:
  - resource-pass.yaml
  - resource-fail.yaml
  results:
  - policy: disallow-privileged
    rule: check-privileged
    resource: good-pod
    kind: Pod
    result: pass
  - policy: disallow-privileged
    rule: check-privileged
    resource: bad-pod
    kind: Pod
    result: fail
```

### CI Pipeline 集成

```yaml
# .github/workflows/policy-check.yaml
name: Policy Check
on: [pull_request]

jobs:
  kyverno:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Install Kyverno CLI
        uses: kyverno/action-install-cli@v0.2.0
        with:
          release: 'v1.11.0'
      
      - name: Test Policies
        run: kyverno test ./policies
      
      - name: Validate Manifests
        run: |
          kyverno apply ./policies/ \
            --resource ./manifests/ \
            --policy-report
```

---

## 6.6 策略报告与合规

```bash
# 查看策略报告
kubectl get policyreports -A
kubectl get clusterpolicyreports

# 查看具体结果
kubectl get policyreport -n team-alpha -o yaml

# 导出合规报告
kubectl get clusterpolicyreports -o json | jq '.items[] | {
  policy: .results[0].policy,
  status: .results[0].status,
  resource: .results[0].resources[0].name
}'
```

---

## 6.7 生产级策略集推荐

### 基础安全（必装）
1. `disallow-privileged` - 禁止特权容器
2. `require-ro-rootfs` - 只读根文件系统
3. `require-run-as-non-root` - 非 root 运行
4. `disallow-latest-tag` - 禁止 latest 镜像标签
5. `restrict-image-registries` - 限制镜像来源

### 资源治理
6. `require-resources` - 强制资源限制
7. `limit-memory` - 内存上限限制（如 max 32Gi）
8. `restrict-nodeport` - 禁止 NodePort

### 合规与审计
9. `require-labels` - 强制标准标签
10. `restrict-hostpath` - 限制 HostPath
11. `block-ingress-nginx-snippets` - 防止 Nginx Ingress 配置注入攻击

### 平台增强
12. `add-default-resources` - 自动注入默认资源
13. `generate-networkpolicy` - 自动创建默认网络策略
14. `add-pod-priority` - 根据命名空间自动设置 PriorityClass

---

## 最佳实践

- [ ] 所有策略变更走 GitOps（ArgoCD/Flux）
- [ ] 新策略先在 Audit 模式运行 1-2 周，观察影响
- [ ] 策略测试覆盖率 > 80%
- [ ] 每月审查策略违反报告，识别培训需求
- [ ] 为开发者提供策略文档和修复指南
- [ ] 策略规则命名清晰，错误消息明确可执行

## 策略生命周期管理

### 策略发布流程

```
阶段 1: 需求收集
├── 安全团队提出合规要求
├── 平台团队评估技术可行性
└── 开发团队反馈影响范围

阶段 2: 策略开发
├── 编写 Kyverno/OPA 策略 YAML
├── 编写测试用例（正向 + 负向）
└── 本地验证（kyverno test / conftest）

阶段 3: 灰度发布
├── 在 Audit 模式运行 1-2 周
├── 收集违反报告，评估影响
└── 修复误报，调整策略

阶段 4: 强制执行
├── 切换到 Enforce 模式
├── 通知所有受影响团队
└── 提供 1 周宽限期

阶段 5: 持续监控
├── 每周审查违反报告
├── 每月评估策略有效性
└── 每季度审查策略集，删除过时策略
```

### 策略测试框架

**Kyverno CLI 测试**:
```yaml
# test/kyverno-test.yaml
name: require-labels-test
policies:
- ../require-labels.yaml
resources:
- ../test-resources.yaml
results:
- policy: require-labels
  rule: check-team-label
  resource: pod-with-label
  kind: Pod
  result: pass
- policy: require-labels
  rule: check-team-label
  resource: pod-without-label
  kind: Pod
  result: fail
```

**OPA Conftest 测试**:
```bash
# 测试策略
conftest test deployment.yaml -p policies/

# 批量测试
conftest test k8s-manifests/ -p policies/ -o table
```

**CI 集成**:
```yaml
# .github/workflows/policy-test.yaml
name: Policy Tests
on: [pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
    - uses: actions/checkout@v4
    - name: Install Kyverno CLI
      uses: kyverno/action-install-cli@v0.2.0
    - name: Run tests
      run: kyverno test ./policies/
    - name: OPA tests
      run: |
        curl -L -o opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64
        chmod +x opa
        ./opa test policies/ -v
```

### 策略治理委员会

**组成**:
- 安全团队代表（1 人）
- 平台团队代表（2 人）
- 产品团队代表（2 人，轮流）
- SRE 代表（1 人）

**职责**:
- 审批新策略（影响评估 + 风险评估）
- 审查现有策略（每季度）
- 处理策略例外申请
- 制定策略优先级

**会议频率**: 每双周一次，30 分钟

**决策规则**:
- 安全关键策略: 安全团队有否决权
- 平台效率策略: 平台团队有决定权
- 影响广泛的策略: 需要多数同意

## 面试常见问题补充

**Q: 策略引擎放在准入控制（Admission Controller）还是 CI/CD 中？**

A: 两者都需要:

| 阶段 | 工具 | 作用 | 时机 |
|------|------|------|------|
| CI/CD | Conftest / Datree | 开发时反馈 | 代码提交前 |
| 准入控制 | Kyverno / OPA Gatekeeper | 最后防线 | 资源创建时 |

理由:
- CI/CD 检查: 给开发者即时反馈，修复成本低
- 准入控制: 防止绕过 CI/CD 的直接 kubectl apply
- 两者互补，不可互相替代

**Q: 如何处理策略的误报（False Positive）？**

A: 处理流程:
1. **收集证据**: 记录误报的资源 YAML 和策略规则
2. **临时豁免**: 为特定资源添加豁免标签
   ```yaml
   metadata:
     annotations:
       kyverno.io/ignore: "true"
   ```
3. **修复策略**: 修改规则使其更精确
4. **回归测试**: 确保修复后不引入新的误报或漏报
5. **更新文档**: 通知所有团队策略变更

预防:
- 新策略必须附带 ≥ 10 个测试用例
- 灰度发布阶段密切关注违反报告
- 建立快速反馈渠道（Slack 频道）

**Q: OPA 和 Kyverno 的性能影响？**

A: 基准数据（1000 RPS 准入请求）:

| 引擎 | P50 延迟 | P99 延迟 | CPU 占用 | 内存占用 |
|------|---------|---------|---------|---------|
| 无策略 | 1ms | 3ms | 0% | 0MB |
| Kyverno（10 策略） | 5ms | 15ms | 50m | 200MB |
| OPA Gatekeeper（10 策略） | 8ms | 25ms | 100m | 500MB |
| OPA（Sidecar） | 3ms | 10ms | 30m | 150MB |

优化建议:
- 策略数量控制在 50 以内
- 避免在策略中调用外部 API
- 使用缓存（如 OPA 的 Bundle 缓存）
- 对大规模集群，考虑分片或专用节点

