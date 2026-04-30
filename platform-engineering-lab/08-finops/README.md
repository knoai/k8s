# 08 - FinOps 与成本优化

FinOps 是云成本管理的工程化实践，将财务问责制引入云资源使用。
在平台工程中，FinOps 不是单纯省钱，而是在成本、性能、可靠性之间
找到最优平衡点。本章覆盖成本观测、分摊策略、资源优化和预算治理。

## 学习目标

1. 理解 FinOps 的核心原则和文化转变
2. 掌握 Kubernetes 成本分配和分摊方法
3. 学会使用 OpenCost/Kubecost 进行成本观测
4. 建立成本优化闭环（观测 → 分析 → 优化 → 验证）
5. 掌握 Spot 实例、自动伸缩、Right-sizing 等优化手段

## 核心概念

### FinOps 生命周期

```
        告知 (Inform)
             ↑
  优化 (Optimize) ←──→ 运营 (Operate)
```

**告知 (Inform)**: 建立成本可见性，让团队了解自己在花多少钱。
包括成本仪表盘、分摊报告、标签策略。

**优化 (Optimize)**: 识别浪费，实施优化措施。
包括 Right-sizing、Spot 实例、存储优化、网络优化。

**运营 (Operate)**: 将成本管理嵌入日常运营，建立预算和告警机制。
包括预算跟踪、自动告警、成本审查会议。

### Kubernetes 成本分配挑战

K8s 成本分配比 VM 复杂得多，主要挑战:

1. **共享资源分摊**: 节点被多个 Pod 共享，CPU 和内存如何公平分摊？
2. **Request vs 实际**: Request 是预留值，实际使用可能远低于 Request
3. **命名空间边界**: 团队按命名空间组织，但节点是共享的
4. **间接成本**: 存储、网络、负载均衡器的成本归属困难
5. **动态性**: Pod 来去频繁，成本随时间波动

### 分摊策略对比

| 策略 | 描述 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| 按 Request | 按 CPU/Memory Request 比例分摊 | 鼓励合理规划 | 实际使用低时团队吃亏 | 资源规划良好的团队 |
| 按实际使用 | 按实际 CPU/Memory 使用分摊 | 公平反映使用 | 导致团队不敢 Request | 资源波动大的场景 |
| 按 Limit | 按 Limit 比例分摊 | 激励资源约束 | 过度约束影响性能 | 需要严格资源管控 |
| 混合模式 | Request 保底 + 超出按实际 | 兼顾公平和激励 | 计算复杂 | **大多数场景推荐** |

**推荐策略**: 混合模式
- 节点成本的 70% 按 Request 分摊（保障基础资源归属）
- 节点成本的 30% 按实际使用分摊（激励高效利用）
- 未使用部分归平台团队（激励平台优化节点利用率）

## 模块内容

### 成本观测与分摊

文件: `cost-allocation.md`

使用 OpenCost/Kubecost 实现成本观测:

```bash
# 安装 OpenCost
helm install opencost opencost/opencost \
  --namespace opencost \
  --set prometheus.internal.enabled=true \
  --create-namespace

# 查看命名空间成本
kubectl port-forward -n opencost service/opencost 9003:9003
# 访问 http://localhost:9003/allocation.html
# 查看不同维度（namespace/deployment/pod）的成本分配
```

OpenCost 计算模型:
```
Pod 成本 = CPU 成本 + 内存成本 + 存储成本 + GPU 成本
CPU 成本 = Pod CPU Request × CPU 单价 × 运行时间
内存成本 = Pod Memory Request × 内存单价 × 运行时间
```

关键指标:
- **CPU 成本**: $/vCPU/小时（AWS m5.large ≈ $0.043/小时，vCPU 单价 ≈ $0.0215/小时）
- **内存成本**: $/GB/小时（m5.large 4GB ≈ $0.01075/GB/小时）
- **存储成本**: $/GB/月（EBS gp3 ≈ $0.08/GB/月）
- **网络成本**: $/GB 出口流量（AWS ≈ $0.09/GB）

### 资源优化

文件: `resource-optimization.md`

**Right-sizing 方法论**:

```bash
# 步骤 1: 收集历史使用数据（至少 7 天）
kubectl top pods -A --containers | awk '{print $1, $2, $3, $4}'

# 步骤 2: 计算实际使用与 Request 的差异
# 理想: Request ≈ P80 实际使用，Limit ≈ P95 峰值

# 步骤 3: 使用 VPA 获取推荐值
kubectl apply -f - <<EOF
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: my-app-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: my-app
  updatePolicy:
    updateMode: "Off"  # 仅推荐，不自动更新
EOF

# 查看推荐（通常需要 24 小时数据）
kubectl get vpa my-app-vpa -o json | jq '.status.recommendation.containerRecommendations'
```

**Right-sizing 决策矩阵**:

| 场景 | CPU Request | CPU Limit | 内存 Request | 内存 Limit |
|------|------------|-----------|-------------|-----------|
| Web 服务（稳定负载） | P80 | P95 | P80 | P95 |
| 批处理（突发） | P50 | P99 | P80 | P95 |
| 大数据（内存密集） | P50 | P90 | P90 | P100 |
| 微服务（不可预测） | P60 | P95 | P70 | P90 |

**Spot/Preemptible 实例**:
- 成本节省: 60-90%（AWS Spot 平均节省 70%）
- 中断率: 通常 <5%，但某些实例类型可达 20%
- 适用工作负载:
  - CI/CD 构建和测试
  - 批处理和数据分析
  - 无状态 Web 服务（配合重试）
  - ML 训练任务

```yaml
# Karpenter 配置 Spot 实例
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spot-workloads
spec:
  template:
    spec:
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      - key: kubernetes.io/arch
        operator: In
        values: ["amd64"]
  disruption:
    consolidationPolicy: WhenUnderutilized
    expireAfter: 720h
```

### 自动伸缩策略

文件: `autoscaling-strategies.md`

四层自动伸缩体系:

```
业务负载 → HPA (Pod 级) → Cluster Autoscaler (节点级) → Karpenter (节点配置)
     ↑                                              ↓
     └────────── VPA (资源优化) ←───────────────────┘
```

**HPA 配置最佳实践**:
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: web-app-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: web-app
  minReplicas: 2
  maxReplicas: 50
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60  # 基于 Request 的利用率
  behavior:
    scaleDown:
      stabilizationWindowSeconds: 300  # 缩容前等待 5 分钟
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
```

**成本优化组合策略**:
```
业务高峰 (9:00):
  HPA 扩容 Pod (2→20) → Cluster Autoscaler 扩容节点 (3→8)
  
业务平峰 (14:00):
  HPA 保持 (20→10) → Cluster Autoscaler 缩容节点 (8→5)
  
业务低谷 (02:00):
  HPA 缩容 (10→2) → Cluster Autoscaler 缩容节点 (5→3)
  
持续优化:
  VPA 每周调整 Request → 节点利用率从 30%→60% → 节点数减少 40%
```

### 预算与告警

文件: `budget-alerting.md`

分层预算体系:

```yaml
# 层级 1: 命名空间级配额
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-a-quota
  namespace: team-a
spec:
  hard:
    requests.cpu: "20"
    requests.memory: 40Gi
    limits.cpu: "40"
    limits.memory: 80Gi
    persistentvolumeclaims: "10"
    services.loadbalancers: "5"
---
# 层级 2: 月度预算告警（OpenCost/Kubecost）
# 当命名空间成本超过预算的 80% 时发送预警
# 超过 100% 时发送紧急告警
# 超过 120% 时启动成本审查流程
```

告警阈值建议:

| 阈值 | 动作 | 通知对象 |
|------|------|---------|
| 80% 月度预算 | 预警通知 | 团队负责人 |
| 100% 月度预算 | 紧急告警 | 团队负责人 + 平台团队 |
| 120% 月度预算 | 成本审查 | 团队负责人 + 平台团队 + 财务 |
| 日成本突增 200% | 异常检测 | 平台团队 |

### 成本优化真实案例

文件: `optimization-cases.md`

**案例 1: 闲置 PVC 清理**
- 背景: 开发环境使用动态存储，但 PVC 很少被删除
- 问题: 200+ 闲置 PVC，月成本 $5,000
- 解决方案:
  ```bash
  # 自动扫描未挂载的 PVC
  kubectl get pvc --all-namespaces | grep -v Bound
  # 保留 7 天后自动删除（开发环境）
  ```
- 结果: 月节省 $4,200（84%）
- 关键教训: 开发环境需要自动清理策略

**案例 2: Request 优化**
- 背景: 所有 Pod 使用 Request=Limit 模式
- 问题: 节点平均利用率 25%，大量资源闲置
- 解决方案:
  1. VPA 分析 2 周历史数据
  2. 将 Request 调整为 P80 实际使用
  3. Limit 保持为 P95 峰值
  4. QoS 从 Guaranteed 改为 Burstable
- 结果: 节点利用率从 25% 提升到 65%，节省 40% 节点成本
- 风险: 需要监控 OOMKilled 事件，确保 Limit 足够

**案例 3: Spot 实例迁移**
- 背景: CI/CD 构建集群使用 On-Demand 实例，月成本 $8,000
- 问题: 构建任务是可中断的，但使用了昂贵的 On-Demand
- 解决方案:
  1. 构建任务添加重试机制（最大 3 次）
  2. 使用 Karpenter 配置 Spot 实例 NodePool
  3. 关键构建（发布）使用 On-Demand，日常构建使用 Spot
- 结果: 构建成本降低 70%（至 $2,400），构建时间增加 <5%
- 关键教训: 可中断工作负载是 Spot 的最佳场景

## 面试常见问题

**Q: 如何说服业务团队关注成本？**

A: 从四个层面推进:
1. **可见性**: 建立 Showback 机制，让团队看到自己在花多少钱
   ```
   示例: "team-a 命名空间本月花费 $3,200，其中 60% 是计算，30% 是存储"
   ```
2. **归属**: 将成本纳入团队 KPI，但强调效率而非单纯省钱
3. **工具**: 提供自助优化工具（Right-sizing 建议、成本仪表盘）
4. **案例**: 分享内部成功案例（"某团队优化后节省了 40%"）

**Q: Request 和 Limit 的成本影响？**

A: Request 决定节点调度成本（必须预留），Limit 决定突发能力。
- Request=Limit（Guaranteed）: 节点利用率低，成本高，但最稳定
- Request<<Limit（Burstable）: 节点利用率高，成本低，但有竞争风险
- 无 Request（BestEffort）: 最高利用率，但最早被驱逐

最佳实践: Request ≈ 平均使用（P50-P80），Limit ≈ P95 峰值。
这样既能保障节点利用率，又能应对突发负载。

**Q: FinOps 在 K8s 中的核心难点？**

A: 五大难点:
1. **共享分摊**: 多 Pod 共享节点，需要公平的分配算法
2. **动态波动**: 按天波动的使用 vs 按月预算，难以对齐
3. **多云统一**: AWS、GCP、Azure 计费模型不同，难以统一视图
4. **间接归属**: 网络、存储、LB 的成本归属到哪个团队？
5. **预留实例**: RI/ savings plan 的节省如何分摊到各团队？

**Q: 如何评估成本优化的 ROI？**

A: 成本优化 ROI = (节省金额 - 优化投入) / 优化投入
- 自动化优化（如 Karpenter）: ROI 极高，一次配置持续收益
- 手动 Right-sizing: ROI 中等，需要持续维护
- 架构重构: ROI 取决于规模，大集群收益显著

平台团队应优先投入高 ROI 的自动化优化。

**Q: Showback vs Chargeback？**

A:
- **Showback**: 展示成本但不实际收费。目的是提高意识。
  适用: 初期阶段，团队对成本敏感度低。

- **Chargeback**: 实际按用量收费。目的是建立财务问责。
  适用: 成熟阶段，需要精细化成本管理。

- **Hybrid**: Showback 为主，对超预算团队实施 Chargeback。
  适用: 大多数企业。

**Q: 云成本优化的常见误区？**

A: 五大误区:
1. **只关注计算成本**: 存储和网络成本可能占 30%+
2. **过度优化 Request**: Request 过低导致 OOMKilled，影响稳定性
3. **忽视预留实例**: On-Demand 比 RI 贵 40-60%，长期工作负载应买 RI
4. **忽略数据出口成本**: 跨区域流量可能非常昂贵
5. **一次性优化后不管**: 成本优化是持续过程，需要定期审查

**Q: 如何设计成本分摊模型？**

A: 设计原则:
1. **公平性**: 按实际资源消耗分摊，避免"大锅饭"
2. **透明性**: 分摊规则公开，团队可以验证自己的账单
3. **激励性**: 鼓励团队优化资源使用，而不是反向激励
4. **简单性**: 规则不要太复杂，否则难以理解和执行

推荐模型:
- 计算成本: 70% 按 Request + 30% 按实际使用
- 存储成本: 按实际使用量（PVC 容量）
- 网络成本: 按出口流量（或按 namespace 分摊）
- 共享成本（监控、日志）: 按节点数或 Pod 数均摊

## 参考资源

- [FinOps Foundation](https://www.finops.org/)
- [OpenCost 文档](https://www.opencost.io/docs/)
- [Kubecost 最佳实践](https://docs.kubecost.com/)
- [AWS Cost Optimization](https://aws.amazon.com/aws-cost-management/)
- [GCP Cloud Billing](https://cloud.google.com/billing)
- [Azure Cost Management](https://azure.microsoft.com/services/cost-management/)

## FinOps 实践进阶

### 云成本优化技术方案

**智能弹性伸缩方案**:
```yaml
# Karpenter + HPA + VPA 联动
# 1. Karpenter 处理节点级扩缩容
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
  - key: karpenter.k8s.aws/instance-category
    operator: In
    values: ["m", "c", "r"]
  - key: karpenter.k8s.aws/instance-generation
    operator: Gt
    values: ["5"]
  ttlSecondsAfterEmpty: 30  # 节点空闲 30 秒后回收
  ttlSecondsUntilExpired: 86400  # 24 小时后自动替换（混合实例）
---
# 2. HPA 处理 Pod 级扩缩容
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: api-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: api
  minReplicas: 2
  maxReplicas: 100
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 60
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60  # 扩容前等待 60 秒
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 300  # 缩容前等待 5 分钟
      policies:
      - type: Percent
        value: 10
        periodSeconds: 60
```

**混合实例策略（Spot + On-Demand）**:
```yaml
# Spot 实例容忍 + 优先级
apiVersion: apps/v1
kind: Deployment
metadata:
  name: batch-job
spec:
  template:
    spec:
      tolerations:
      - key: "node-type"
        operator: "Equal"
        value: "spot"
        effect: "NoSchedule"
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            preference:
              matchExpressions:
              - key: node-type
                operator: In
                values: ["spot"]
```

**Spot 实例中断处理**:
```bash
# AWS Node Termination Handler
kubectl apply -f https://github.com/aws/aws-node-termination-handler/releases/download/v1.20.0/all-resources.yaml

# 处理流程:
# 1. AWS 发送 Spot 实例中断通知（提前 2 分钟）
# 2. Node Termination Handler 捕获信号
# 3. 将节点标记为不可调度
# 4. 优雅驱逐 Pod（终止宽限期）
# 5. 应用收到 SIGTERM，开始优雅关闭
# 6. 2 分钟后实例终止
```

### 资源优化自动化

**Right-sizing 自动化**:
```bash
# 使用 Goldilocks 获取推荐
kubectl apply -f https://raw.githubusercontent.com/FairwindsOps/goldilocks/master/manifests/dashboard/install.yaml

# 查看推荐
kubectl get vpa -A
# NAME    MODE   CPU    MEM
# api     Off    250m   512Mi  (当前: 500m / 1Gi)
```

**自动清理**:
```bash
# 1. 清理未使用的 ConfigMap/Secret
kubectl get configmap -A | grep -v "kube-system" | awk 'NR>1 {print $1,$2}' | while read ns name; do
  refs=$(kubectl get all -n $ns -o json | grep -c $name || true)
  if [ "$refs" -eq 0 ]; then
    echo "Unused ConfigMap: $ns/$name"
  fi
done

# 2. 清理孤儿 PVC
kubectl get pvc -A | grep -v "Bound" | awk '{print $1,$2}' | while read ns name; do
  kubectl delete pvc -n $ns $name
done

# 3. 清理旧镜像
kubectl get nodes -o json | jq -r '.items[].status.images[] | select(.names[0] | contains("sha256") | not) | .names[0]' | sort | uniq -c | sort -rn | head -20
```

### FinOps 报告体系

**周报模板**:
```markdown
# 云成本周报 (YYYY-MM-DD ~ YYYY-MM-DD)

## 总览
- 本周总成本: $X,XXX (↑/↓ X%)
- 环比变化: $XXX
- 预算使用率: XX% (月度)

## 按命名空间 TOP 5
| 排名 | 命名空间 | 成本 | 变化 | 主要资源 |
|------|---------|------|------|---------|
| 1 | production | $X,XXX | +5% | CPU 增加（扩容） |
| 2 | staging | $XXX | -10% | 清理测试环境 |

## 异常告警
- [ ] team-alpha 成本增加 50%（需关注）
- [ ] team-beta 存在 3 个未绑定的 LoadBalancer

## 优化建议
1. team-gamma 的 Request 可缩减 30%
2. staging 环境建议夜间关机

## 行动项
- [ ] @platform-team 通知 team-alpha 成本异常
- [ ] @team-beta 清理未使用的 LoadBalancer
```

**月度成本审查会议议程**:
1. 总体成本趋势（过去 6 个月）
2. 按团队成本分析
3. 优化措施效果回顾
4. 下月优化计划
5. 预算调整建议

### 多云成本管理

**多云成本统一视图**:
```
              ┌─────────────┐
              │   FinOps    │
              │   Portal    │
              └──────┬──────┘
                     │
        ┌────────────┼────────────┐
        │            │            │
   ┌────┴────┐  ┌────┴────┐  ┌────┴────┐
   │  AWS    │  │  GCP    │  │  Azure  │
   │  Cost   │  │ Billing │  │  Cost   │
   │ Explorer│  │ Export  │  │  Mgmt   │
   └─────────┘  └─────────┘  └─────────┘
```

**多云策略**:
- **价格套利**: 同等工作负载选择最低价格云
- **避免锁定**: 使用 Terraform + K8s 保持可移植性
- **数据主权**: 敏感数据留在特定区域/云
- **灾难恢复**: 主云 + 备云架构

