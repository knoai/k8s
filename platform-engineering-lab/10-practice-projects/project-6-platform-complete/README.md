# 项目 6: 平台工程综合实战（Platform Complete）

## 项目概述

本项目是整个平台工程实验室的**毕业实战项目**，目标是将前 5 个项目和 13 个模块的知识整合为一个**生产级的内部开发者平台**。你将从零开始设计、构建和运营一个面向多团队的企业级平台。

**项目定位**: 高级综合实战 → 适合已完成前 5 个项目或具备 K8s/云原生经验的工程师

**预计耗时**: 完整搭建 4-8 小时 + 持续运营优化

**前置条件**: 完成 [项目 1: IDP 原型](../project-1-idp-prototype/) 或具备同等经验

---

## 目标平台能力矩阵

本项目要求构建的平台必须具备以下能力：

| 能力域 | 必备组件 | 验收标准 |
|--------|---------|---------|
| **开发者门户** | Backstage | 服务目录、软件模板、K8s 插件、TechDocs |
| **GitOps 交付** | ArgoCD + ApplicationSet | 多环境（dev/staging/prod）自动同步 |
| **多租户隔离** | vCluster + HNC | 团队级虚拟集群 + 资源配额 + 网络策略 |
| **可观测性** | Prometheus + Grafana + Loki + Jaeger | 四金信号监控、日志聚合、分布式追踪 |
| **成本管理** | OpenCost + 配额策略 | 按团队成本分摊、超预算告警 |
| **安全合规** | Kyverno + Falco | 策略即代码、运行时安全检测 |
| **自动扩缩容** | Karpenter + HPA + VPA | 节点级 + Pod 级弹性、成本优化 |
| **服务网格** | Istio | mTLS、流量管理、可观测性 |
| **混沌工程** | Chaos Mesh | 定期故障注入、韧性验证 |
| **性能基准** | kube-burner + Vegeta | 集群压力测试、回归检测 |

---

## 架构设计

### 整体架构

```
┌─────────────────────────────────────────────────────────────────────┐
│                         开发者体验层                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐              │
│  │   Backstage  │  │   Backstage  │  │   Backstage  │              │
│  │   Portal     │  │   Scaffolder │  │   K8s Plugin │              │
│  │  (服务目录)   │  │  (软件模板)   │  │  (Pod 监控)  │              │
│  └──────┬───────┘  └──────┬───────┘  └──────┬───────┘              │
│         │                 │                 │                       │
│         └─────────────────┼─────────────────┘                       │
│                           │                                         │
│  ┌────────────────────────┴────────────────────────┐                │
│  │              GitOps / CI-CD 层                   │                │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐      │                │
│  │  │  ArgoCD  │  │Argo Rollouts│ │  Tekton  │      │                │
│  │  │ (同步)   │  │(金丝雀)   │  │ (CI)     │      │                │
│  │  └────┬─────┘  └────┬─────┘  └────┬─────┘      │                │
│  │       └─────────────┼─────────────┘             │                │
│  └─────────────────────┼───────────────────────────┘                │
│                        │                                            │
│  ┌─────────────────────┴───────────────────────────────┐            │
│  │              平台服务层 (Platform Services)            │            │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐       │            │
│  │  │vCluster│ │Kyverno │ │Karpenter│ │ OpenCost│       │            │
│  │  │(多租户)│ │(策略)  │ │(弹性)  │ │(成本)  │       │            │
│  │  └────────┘ └────────┘ └────────┘ └────────┘       │            │
│  │  ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐       │            │
│  │  │Istio   │ │Falco   │ │Chaos   │ │Cert    │       │            │
│  │  │(网格)  │ │(安全)  │ │Mesh    │ │Manager │       │            │
│  │  └────────┘ └────────┘ └────────┘ └────────┘       │            │
│  └─────────────────────────────────────────────────────┘            │
│                        │                                            │
│  ┌─────────────────────┴───────────────────────────────┐            │
│  │              可观测性层 (Observability)               │            │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐           │            │
│  │  │Prometheus│ │  Loki    │ │ Jaeger   │           │            │
│  │  │ (指标)   │ │ (日志)   │ │ (追踪)   │           │            │
│  │  └────┬─────┘ └────┬─────┘ └────┬─────┘           │            │
│  │       └─────────────┼─────────────┘                │            │
│  │                ┌────┴────┐                        │            │
│  │                │ Grafana │                        │            │
│  │                │(统一视图)│                        │            │
│  │                └─────────┘                        │            │
│  └─────────────────────────────────────────────────────┘            │
│                        │                                            │
│  ┌─────────────────────┴───────────────────────────────┐            │
│  │              基础设施层 (Infrastructure)              │            │
│  │  ┌──────────┐ ┌──────────┐ ┌──────────┐           │            │
│  │  │ EKS/GKE  │ │  VPC-CNI │ │  EBS/EFS │           │            │
│  │  │ (K8s)    │ │ (网络)   │ │ (存储)   │           │            │
│  │  └──────────┘ └──────────┘ └──────────┘           │            │
│  └─────────────────────────────────────────────────────┘            │
└─────────────────────────────────────────────────────────────────────┘
```

### 多租户架构

```
┌──────────────────────────────────────────────┐
│              宿主集群 (Host Cluster)            │
│  ┌────────────────────────────────────────┐  │
│  │  vCluster-Team-A (虚拟控制面)          │  │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐  │  │
│  │  │ API Svr │ │ Syncer  │ │  etcd   │  │  │
│  │  │(虚拟)   │ │(同步)   │ │(SQLite) │  │  │
│  │  └────┬────┘ └────┬────┘ └─────────┘  │  │
│  │       └───────────┘                    │  │
│  └────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────┐  │
│  │  vCluster-Team-B (虚拟控制面)          │  │
│  │  ┌─────────┐ ┌─────────┐              │  │
│  │  │ API Svr │ │ Syncer  │              │  │
│  │  └────┬────┘ └────┬────┘              │  │
│  │       └───────────┘                    │  │
│  └────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────┐  │
│  │  共享服务 (Shared Services)            │  │
│  │  ┌────────┐ ┌────────┐ ┌────────┐     │  │
│  │  │Prometheus│ │ ArgoCD │ │Backstage│    │  │
│  │  └────────┘ └────────┘ └────────┘     │  │
│  └────────────────────────────────────────┘  │
└──────────────────────────────────────────────┘
```

---

## 实施路线图

### 阶段 1: 基础设施搭建（2 小时）

**目标**: 创建生产级 K8s 集群和核心平台组件

```bash
# 1. 创建 EKS 集群（使用 Terraform）
cd infra/terraform
terraform init
terraform apply -var="cluster_name=platform-prod"

# 2. 安装核心平台组件
kubectl apply -k platform/base/

# 预期状态:
# - EKS 集群: 3 节点（t3.medium）
# - Ingress Nginx: 运行中
# - Cert Manager: 运行中
# - External DNS: 运行中
```

**验收标准**:
- `kubectl get nodes` 显示 3 个 Ready 节点
- `kubectl get pods -A` 无 CrashLoopBackOff
- Ingress 域名可访问

### 阶段 2: GitOps 和多环境（1 小时）

**目标**: 建立 dev/staging/prod 多环境 GitOps 工作流

```bash
# 1. 安装 ArgoCD（HA 模式）
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set controller.replicas=2 \
  --set server.replicas=2 \
  --set repoServer.replicas=2 \
  --create-namespace

# 2. 创建 ApplicationSet（一个 Git 仓库管理多环境）
cat > /tmp/appset.yaml << 'EOF'
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: platform-services
  namespace: argocd
spec:
  generators:
  - list:
      elements:
      - env: dev
        cluster: in-cluster
        namespace: platform-dev
      - env: staging
        cluster: in-cluster
        namespace: platform-staging
      - env: prod
        cluster: in-cluster
        namespace: platform-prod
  template:
    metadata:
      name: 'platform-{{env}}'
    spec:
      project: default
      source:
        repoURL: https://github.com/my-org/platform-gitops.git
        targetRevision: HEAD
        path: 'overlays/{{env}}'
      destination:
        server: '{{cluster}}'
        namespace: '{{namespace}}'
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
        - CreateNamespace=true
EOF
kubectl apply -f /tmp/appset.yaml
```

**验收标准**:
- ArgoCD UI 显示 3 个 Application（dev/staging/prod）
- Git 变更自动同步到对应环境
- 回滚可用: `argocd app rollback platform-prod 0`

### 阶段 3: 多租户和隔离（1 小时）

**目标**: 为每个团队创建独立的虚拟集群

```bash
# 1. 安装 vCluster CLI
curl -L -o vcluster "https://github.com/loft-sh/vcluster/releases/latest/download/vcluster-linux-amd64" && chmod +x vcluster

# 2. 为每个团队创建 vCluster
for team in team-alpha team-beta team-gamma; do
  vcluster create $team \
    --namespace vcluster-$team \
    --connect=false \
    --expose
    
  # 创建 ResourceQuota
  cat > /tmp/rq-$team.yaml << RQEOF
apiVersion: v1
kind: ResourceQuota
metadata:
  name: $team-quota
  namespace: vcluster-$team
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    pods: "100"
    services: "20"
    persistentvolumeclaims: "10"
RQEOF
  kubectl apply -f /tmp/rq-$team.yaml
done

# 3. 验证隔离
vcluster connect team-alpha -- kubectl get ns
# 只能看到 team-alpha 的命名空间
```

**验收标准**:
- 每个团队有独立的 kubeconfig
- 团队 A 无法访问团队 B 的资源
- 资源配额生效（超出配额时 Pod 无法创建）

### 阶段 4: 可观测性体系（1.5 小时）

**目标**: 建立 Metrics + Logs + Traces 的统一可观测性平台

```bash
# 1. 安装 kube-prometheus-stack
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=admin \
  --set prometheus.prometheusSpec.retention=30d \
  --create-namespace

# 2. 安装 Loki（日志聚合）
helm upgrade --install loki grafana/loki-stack \
  --namespace monitoring \
  --set promtail.enabled=true

# 3. 安装 Jaeger（分布式追踪）
helm upgrade --install jaeger jaegertracing/jaeger \
  --namespace monitoring \
  --set provisionDataStore.cassandra=false \
  --set storage.type=memory

# 4. 配置应用接入 OpenTelemetry
# 在每个服务的 Deployment 中添加:
env:
- name: OTEL_EXPORTER_OTLP_ENDPOINT
  value: "http://jaeger-collector.monitoring:4317"
- name: OTEL_SERVICE_NAME
  value: "my-service"
```

**验收标准**:
- Grafana 可查看集群级指标（CPU、内存、网络）
- Loki 可搜索所有 Pod 日志
- Jaeger 可追踪跨服务请求链路
- 告警规则生效（CPU > 80% 触发告警）

### 阶段 5: FinOps 和成本优化（1 小时）

**目标**: 实现成本可见性和自动优化

```bash
# 1. 安装 OpenCost
kubectl apply -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/opencost.yaml

# 2. 配置 Karpenter（自动节点扩缩容）
helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
  --namespace karpenter \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"=$KARPENTER_ROLE \
  --create-namespace

# 3. 创建 Provisioner
kubectl apply -f - << 'EOF'
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
  - key: karpenter.k8s.aws/instance-category
    operator: In
    values: ["m", "c", "r"]
  ttlSecondsAfterEmpty: 60
  ttlSecondsUntilExpired: 86400
  limits:
    resources:
      cpu: 1000
      memory: 2000Gi
EOF

# 4. 配置成本告警
kubectl apply -f - << 'EOF'
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: cost-alerts
  namespace: monitoring
spec:
  groups:
  - name: cost
    rules:
    - alert: NamespaceCostOverBudget
      expr: |
        sum(opencost_allocation_cpu_cost + opencost_allocation_memory_cost) by (namespace)
        > 500
      for: 1d
      labels:
        severity: warning
      annotations:
        summary: "命名空间 {{ $labels.namespace }} 日成本超过 $500"
EOF
```

**验收标准**:
- OpenCost Dashboard 显示按命名空间的成本拆分
- Karpenter 自动创建/删除节点（空闲 60 秒后回收）
- 超预算时收到 Slack/邮件告警

### 阶段 6: 安全合规和混沌工程（1 小时）

**目标**: 建立安全基线和韧性验证

```bash
# 1. 安装 Kyverno（策略引擎）
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno \
  --create-namespace

# 2. 部署基础策略
kubectl apply -f - << 'EOF'
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-labels
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-team-label
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "Pod 必须包含 team 标签"
      pattern:
        metadata:
          labels:
            team: "?*"
---
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
      message: "只允许使用内部镜像仓库"
      pattern:
        spec:
          containers:
          - image: "registry.internal/* | registry.company/*"
EOF

# 3. 安装 Chaos Mesh
helm upgrade --install chaos-mesh chaos-mesh/chaos-mesh \
  --namespace chaos-mesh \
  --set chaosDaemon.runtime=containerd \
  --create-namespace

# 4. 创建混沌实验（Pod 故障注入）
kubectl apply -f - << 'EOF'
apiVersion: chaos-mesh.org/v1alpha1
kind: PodChaos
metadata:
  name: pod-kill-experiment
  namespace: chaos-mesh
spec:
  action: pod-kill
  mode: one
  duration: "10s"
  selector:
    namespaces:
    - staging
    labelSelectors:
      "app": "api"
  scheduler:
    cron: "@every 30m"
EOF
```

**验收标准**:
- 不合规的 Pod 无法创建（Kyverno 拦截）
- 镜像扫描漏洞自动修复
- 混沌实验每 30 分钟自动运行
- 服务在 Pod 被删除后 60 秒内自动恢复

---

## 运营检查清单

### 每日检查（5 分钟）

```bash
#!/bin/bash
# daily-check.sh - 平台每日健康检查

echo "=== 平台每日健康检查 $(date) ==="

# 1. 节点状态
echo "[1/5] 节点状态"
kubectl get nodes -o wide | awk 'NR==1 || $2 != "Ready" {print}'

# 2. Pod 状态
echo "[2/5] Pod 状态（排除 Running/Completed）"
kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded 2>/dev/null | grep -v "No resources"

# 3. 告警状态
echo "[3/5] 当前告警"
curl -s "http://alertmanager:9093/api/v2/alerts?active=true" | jq '. | length' 2>/dev/null | xargs -I {} echo "  活跃告警数: {}"

# 4. 成本快照
echo "[4/5] 今日成本 TOP 3"
curl -s "http://opencost:9003/allocation/compute?window=today&aggregate=namespace" 2>/dev/null | jq -r '.data[] | "\(.name): $\(.totalCost)"' | sort -k2 -nr | head -3

# 5. 证书过期检查
echo "[5/5] 证书过期检查"
kubectl get certificates -A -o json 2>/dev/null | jq -r '.items[] | select(.status.conditions[]?.status != "True") | "  ⚠ \(.metadata.namespace)/\(.metadata.name)"'

echo "=== 检查完成 ==="
```

### 每周审查（30 分钟）

1. **性能回顾**: 查看 Grafana 中本周 P99 延迟趋势
2. **成本分析**: 生成 OpenCost 周报，识别异常增长
3. **安全扫描**: 运行 Trivy 扫描，查看新发现的漏洞
4. **容量规划**: 检查节点利用率，规划下月扩容
5. **混沌实验结果**: 回顾本周故障注入结果，更新韧性指标

### 每月优化（2 小时）

1. **Right-sizing**: 使用 Goldilocks/VPA 推荐调整 Request/Limit
2. **闲置资源清理**: 删除未使用的 PVC、ConfigMap、Secret
3. **策略更新**: 根据新合规要求更新 Kyverno 策略
4. **模板迭代**: 根据团队反馈更新 Backstage 软件模板
5. **文档更新**: 更新运维 Runbook 和平台使用指南

---

## 面试知识点

**Q: 设计一个企业级 IDP，你会如何划分团队边界？**

A: 推荐按"能力域"划分:
- **平台体验团队**: Backstage 门户、CLI 工具、文档
- **基础设施团队**: K8s 集群、网络、存储、节点管理
- **可观测性团队**: 监控、日志、追踪、告警
- **安全合规团队**: 策略、审计、镜像扫描、证书管理
- **FinOps 团队**: 成本优化、资源配额、预算管理

每个团队对外提供 SLA:
- 平台体验: 门户可用性 99.9%
- 基础设施: 集群可用性 99.95%
- 可观测性: 数据保留 30 天，告警延迟 < 1 分钟

**Q: 如何确保多租户环境中的资源公平性？**

A: 三层保障:
1. **ResourceQuota**: 硬性限制（CPU、内存、Pod 数）
2. **LimitRange**: 默认值和范围限制（防止个别 Pod 占用过多资源）
3. **Karpenter**: 公平调度（大团队也需要等待节点创建）

监控:
- 每日查看各团队的资源使用率 vs 配额
- 使用率低的团队通知缩容，使用率高的团队评估是否需要扩容
- 每月审查配额分配，根据实际需求调整

**Q: GitOps 多环境管理中，如何处理 secrets？**

A: 三种方案:
1. **Sealed Secrets**: 将 secrets 加密存储在 Git 中，只有集群能解密
   - 优点: 完全 GitOps
   - 缺点: 密钥轮换复杂

2. **External Secrets Operator**: 从 Vault/AWS Secrets Manager 同步 secrets
   - 优点: 集中管理、自动轮换
   - 缺点: 依赖外部系统

3. **SOPS + Age**: 用 age 密钥加密 secrets YAML
   - 优点: 简单、开源
   - 缺点: 密钥管理需要额外流程

推荐: 生产环境使用 External Secrets Operator + Vault。

**Q: 平台工程项目的 ROI 如何量化？**

A: 直接收益:
- **开发者时间节省**: 50 开发者 × 每天节省 1 小时 × $50/小时 × 250 天 = $625,000/年
- **故障减少**: 减少 10 个 P1 故障/年 × $10,000/故障 = $100,000/年
- **云成本优化**: 资源利用率提升 30% × $500,000/年云成本 = $150,000/年

间接收益:
- 开发者满意度提升 → 留存率提升 10% → 节省招聘成本 $200,000/年
- 交付速度提升 2 倍 → 业务机会成本减少

总收益: ~$1,075,000/年
平台团队成本: ~$800,000/年（8 人团队）
ROI: 34%（第一年即可为正）

**Q: 如何设计平台的灾难恢复方案？**

A: RPO/RTO 目标:
- RPO（数据丢失容忍）: 5 分钟（持续备份）
- RTO（恢复时间）: 1 小时（自动恢复 + 人工确认）

方案:
1. **etcd 备份**: 每 5 分钟自动 snapshot，存储到 S3
2. **Git 仓库**: GitOps 配置即备份，新集群 + `kubectl apply` = 恢复
3. **Persistent Volume**: 使用 EBS snapshot，跨 AZ 复制
4. **多区域**: 关键服务双活部署（主区域 + 备区域）
5. **演练**: 每季度进行一次灾难恢复演练

恢复流程:
```
1. 创建新集群（Terraform，30 分钟）
2. 恢复 etcd snapshot（5 分钟）
3. ArgoCD 自动同步所有应用（10 分钟）
4. 验证关键业务功能（15 分钟）
```

---

## 故障排查

**问题 1: vCluster 中的 Pod 无法访问宿主集群的服务**

```bash
# 检查 vCluster 的网络模式
vcluster connect team-alpha -- kubectl get pods -n kube-system

# 确认 Syncer 配置
kubectl get configmap -n vcluster-team-alpha vcluster-team-alpha -o yaml | grep -A 10 "mapSync"

# 常见原因:
# 1. Syncer 未同步 Service（检查 --map-services）
# 2. 网络策略阻止了跨命名空间通信
# 3. DNS 解析问题（vCluster 使用自己的 CoreDNS）
```

**问题 2: ArgoCD ApplicationSet 未生成 Application**

```bash
# 检查 ApplicationSet 状态
kubectl get applicationset -n argocd

# 查看控制器日志
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-applicationset-controller

# 常见原因:
# 1. Git 仓库 URL 错误或无法访问
# 2. Path 不存在
# 3. 生成器配置错误（list/matrix/git）
```

**问题 3: Karpenter 不创建新节点**

```bash
# 检查 Karpenter 日志
kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter

# 检查未调度的 Pod
kubectl get pods -A | grep Pending

# 常见原因:
# 1. Provisioner 的 requirements 太严格（没有匹配的实例类型）
# 2. AWS IAM 权限不足
# 3. subnet/security group 配置错误
# 4. 达到 limits 上限
```

**问题 4: 可观测性数据丢失**

```bash
# 检查 Prometheus 存储
kubectl exec -n monitoring prometheus-prometheus-0 -- df -h /prometheus

# 检查 Loki 存储
kubectl exec -n monitoring loki-0 -- df -h /data

# 常见原因:
# 1. PVC 满了（需要扩容或降低保留期）
# 2. Promtail 未运行（日志不采集）
# 3. OTel Collector 配置错误（追踪不发送）
```

---

## 扩展挑战

1. **多集群管理**: 在 ArgoCD 中管理多个 EKS 集群（prod-us、prod-eu、prod-ap）
2. **渐进式交付**: 使用 Argo Rollouts 实现金丝雀发布（自动流量切换）
3. **AIOps 集成**: 集成 Prometheus Alertmanager + PagerDuty + Slack 自动排障
4. **自定义 Backstage 插件**: 开发内部工具插件（成本仪表盘、资源申请）
5. **GitOps 漂移检测**: 每周扫描集群中未在 Git 中定义的资源（防止配置漂移）
6. **多云管理**: 将平台扩展到 GCP/Azure，统一管理异构基础设施
7. **平台即产品**: 建立平台 NPS 调查机制，持续收集用户反馈

---

## 参考资源

- [Backstage 官方文档](https://backstage.io/docs/)
- [ArgoCD 官方文档](https://argo-cd.readthedocs.io/)
- [vCluster 文档](https://www.vcluster.com/docs/)
- [Karpenter 文档](https://karpenter.sh/docs/)
- [OpenCost 文档](https://www.opencost.io/docs/)
- [Kyverno 文档](https://kyverno.io/docs/)
- [Istio 文档](https://istio.io/latest/docs/)
- [FinOps Foundation](https://www.finops.org/)
- [Team Topologies](https://teamtopologies.com/)

---

*本项目是平台工程实验室系列的终极挑战。完成本项目后，你已经具备了设计、构建和运营企业级内部开发者平台的完整能力。祝你在平台工程的职业道路上更进一步！*
