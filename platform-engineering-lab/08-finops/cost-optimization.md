# K8s FinOps 成本优化深度实践

> 云原生环境的成本管理是平台工程的核心职责。本节从资源优化到计费策略，提供系统化的 FinOps 实践方法。

---

## 一、K8s 成本构成分析

### 1.1 成本分层模型

```
K8s 集群成本构成：

┌─────────────────────────────────────────┐
│  计算成本（Compute）60-70%              │
│   ├─ Worker 节点（EC2/ECS）             │
│   │   - 按需实例（On-Demand）           │
│   │   - 预留实例（Reserved）            │
│   │   - 抢占式实例（Spot/Preemptible）  │
│   │   -  Savings Plans / 包年包月       │
│   ├─ 控制平面（Master）                 │
│   │   - 托管服务（EKS/ACK/GKE）         │
│   │   - 自管 Master                     │
│   └─ 虚拟节点（Fargate/ECI/ASK）        │
│       - 按 Pod 计费                     │
├─────────────────────────────────────────┤
│  存储成本（Storage）15-20%              │
│   ├─ 云盘（EBS/ESSD/PD）                │
│   │   - 系统盘                          │
│   │   - 数据盘（PVC）                   │
│   ├─ 对象存储（S3/OSS/GCS）             │
│   │   - 镜像仓库                        │
│   │   - 备份/日志                       │
│   └─ 文件存储（EFS/NAS）                │
├─────────────────────────────────────────┤
│  网络成本（Network）5-10%               │
│   ├─ 负载均衡（ALB/NLB/CLB）            │
│   ├─ NAT 网关                           │
│   ├─ 出站流量（Egress）                 │
│   └─ 跨区域流量                         │
├─────────────────────────────────────────┤
│  其他成本 5-10%                         │
│   ├─ 监控（CloudWatch/Prometheus）      │
│   ├─ 日志（CloudWatch Logs/ES）         │
│   ├─ 密钥管理（KMS）                    │
│   └─ 容器镜像仓库（ECR/ACR）            │
└─────────────────────────────────────────┘
```

### 1.2 资源浪费典型场景

```
常见资源浪费：

1. CPU 浪费：
   - 现象：Pod CPU limit = 4 核，实际使用 0.5 核
   - 原因：开发过度申请资源
   - 占比：30-50% 的 CPU 资源被浪费

2. 内存浪费：
   - 现象：Pod memory limit = 8GB，实际使用 1GB
   - 原因：未做内存优化
   - 占比：20-40% 的内存资源被浪费

3. 空闲节点：
   - 现象：节点 CPU 使用率 < 10%，但持续运行
   - 原因：Cluster Autoscaler 缩容不及时
   - 占比：10-20% 的节点处于低利用率

4. 存储浪费：
   - 现象：PVC 申请 500GB，实际使用 50GB
   - 原因：未启用存储扩容
   - 占比：30-50% 的存储被浪费

5. 负载均衡浪费：
   - 现象：每个服务一个 LoadBalancer
   - 原因：未使用 Ingress
   - 成本：每个 ALB $15-25/月

6. 镜像浪费：
   - 现象：镜像大小 2GB，实际只需要 200MB
   - 原因：未优化 Dockerfile
   - 影响：拉取时间、存储成本
```

---

## 二、资源优化

### 2.1 VPA（垂直 Pod 自动伸缩）

```yaml
# VPA 配置：自动调整 Pod 资源请求
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: order-service-vpa
  namespace: production
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  updatePolicy:
    updateMode: "Auto"              # Auto/Initial/Off/Recreate
    minReplicas: 2                   # 最小副本数（防止全部重启）
  resourcePolicy:
    containerPolicies:
    - containerName: '*'
      minAllowed:
        cpu: 50m
        memory: 64Mi
      maxAllowed:
        cpu: 4
        memory: 8Gi
      controlledResources: ["cpu", "memory"]
      controlledValues: RequestsAndLimits  # 同时调整 requests 和 limits

# VPA 建议模式（不自动更新，只提供建议）
---
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: order-service-vpa-recommendation
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: order-service
  updatePolicy:
    updateMode: "Off"               # 只提供建议，不自动更新

# 查看建议
kubectl get vpa order-service-vpa-recommendation -o yaml
# status:
#   recommendation:
#     containerRecommendations:
#     - containerName: order-service
#       lowerBound:
#         cpu: 120m
#         memory: 256Mi
#       target:
#         cpu: 250m          ← 建议的 CPU request
#         memory: 512Mi      ← 建议的 Memory request
#       uncappedTarget:
#         cpu: 300m
#         memory: 600Mi
#       upperBound:
#         cpu: 500m
#         memory: 1Gi
```

### 2.2 节点优化

```bash
# === 节点利用率分析 ===

# 查看节点资源使用
kubectl top nodes
# NAME         CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# node-1       200m         5%     2048Mi          15%
# node-2       300m         7%     3072Mi          22%
# node-3       150m         3%     1536Mi          11%
# ← CPU 使用率 3-7%，严重浪费！

# 查看节点可分配资源
cat > node-analysis.sh <<'SCRIPT'
#!/bin/bash
echo "=== 节点资源利用率分析 ==="
for node in $(kubectl get nodes -o name | cut -d/ -f2); do
  echo "--- $node ---"
  
  # 节点总资源
  CAP_CPU=$(kubectl get node $node -o jsonpath='{.status.capacity.cpu}')
  CAP_MEM=$(kubectl get node $node -o jsonpath='{.status.capacity.memory}')
  
  # 可分配资源
  ALLOC_CPU=$(kubectl get node $node -o jsonpath='{.status.allocatable.cpu}')
  ALLOC_MEM=$(kubectl get node $node -o jsonpath='{.status.allocatable.memory}')
  
  # 已请求资源
  REQ_CPU=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node -o json | \
    jq -r '.items[].spec.containers[].resources.requests.cpu // "0"' | \
    sed 's/m//' | awk '{sum+=$1} END {print sum/1000 "cores"}')
  
  REQ_MEM=$(kubectl get pods --all-namespaces --field-selector spec.nodeName=$node -o json | \
    jq -r '.items[].spec.containers[].resources.requests.memory // "0"' | \
    awk '{sum+=$1} END {print sum/1024/1024 "Mi"}')
  
  echo "  Capacity: CPU=$CAP_CPU, MEM=$CAP_MEM"
  echo "  Allocatable: CPU=$ALLOC_CPU, MEM=$ALLOC_MEM"
  echo "  Requested: CPU=$REQ_CPU, MEM=$REQ_MEM"
done
SCRIPT
bash node-analysis.sh

# === 优化方案 ===

# 1. 使用 Karpenter（AWS）或 Cluster Autoscaler
# Karpenter 优势：更快的节点启动，更好的 bin packing

# 2. 节点合并
# 将低利用率节点上的 Pod 迁移到其他节点，然后释放空闲节点
kubectl drain node-3 --ignore-daemonsets --delete-emptydir-data
kubectl delete node node-3

# 3. 使用 Spot 实例
# 适用于：批处理、CI/CD、无状态服务
kubectl apply -f - <<'EOF'
apiVersion: karpenter.sh/v1beta1
kind: NodePool
metadata:
  name: spot-pool
spec:
  template:
    spec:
      requirements:
      - key: karpenter.sh/capacity-type
        operator: In
        values: ["spot"]
      - key: node.kubernetes.io/instance-type
        operator: In
        values: ["m5.large", "m5.xlarge", "m5.2xlarge"]
  limits:
    cpu: 1000
    memory: 2000Gi
EOF

# 4. 资源超售（CPU 超售）
# CPU 可以安全超售（requests < limits）
# 内存不建议超售（可能导致 OOM）
```

### 2.3 存储优化

```yaml
# === 存储成本优化 ===

# 1. 使用 gp3 替代 gp2（AWS）
# gp3 默认 3000 IOPS，成本比 gp2 低 20%
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3-optimized
provisioner: ebs.csi.aws.com
parameters:
  type: gp3
  iops: "3000"
  throughput: "125"
  encrypted: "true"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: WaitForFirstConsumer

# 2. 启用存储扩容（避免过度申请）
# 初始申请 10GB，按需扩容到 100GB
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-pvc
spec:
  accessModes: ["ReadWriteOnce"]
  resources:
    requests:
      storage: 10Gi    # 初始大小
  storageClassName: gp3-optimized

# 扩容命令
kubectl patch pvc data-pvc -p '{"spec":{"resources":{"requests":{"storage":"50Gi"}}}}'

# 3. 使用对象存储替代文件存储
# 日志、备份、静态文件 → S3/OSS（成本 1/10）

# 4. 镜像优化
# 使用 distroless / alpine / scratch 基础镜像
# 多阶段构建
# .dockerignore 排除不需要的文件
```

---

## 三、成本分摊与计费

### 3.1 标签化成本分摊

```yaml
# === 成本标签体系 ===

# 命名空间级别
apiVersion: v1
kind: Namespace
metadata:
  name: team-alpha-production
  labels:
    # 必需标签
    cost-center: "CC-12345"
    team: "alpha"
    environment: "production"
    project: "order-platform"
    owner: "team-alpha@mycompany.com"
    
    # 可选标签
    business-unit: "ecommerce"
    region: "us-east-1"
    compliance: "pci-dss"

# Pod 级别（自动继承或显式设置）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: order-service
  namespace: team-alpha-production
  labels:
    cost-center: "CC-12345"
    team: "alpha"
    environment: "production"
spec:
  template:
    metadata:
      labels:
        cost-center: "CC-12345"
        team: "alpha"
        app: order-service
    spec:
      containers:
      - name: order-service
        image: order-service:v1.2.3
        resources:
          requests:
            cpu: "500m"
            memory: "1Gi"
          limits:
            cpu: "2"
            memory: "4Gi"

# === 成本报告 ===
# 使用 OpenCost / Kubecost 生成报告
# 按标签维度：team、cost-center、environment、project
```

### 3.2 OpenCost 部署

```bash
# 安装 OpenCost
kubectl apply -f https://raw.githubusercontent.com/opencost/opencost/develop/kubernetes/opencost.yaml

# 查看成本数据
kubectl port-forward -n opencost svc/opencost 9003:9003
curl http://localhost:9003/allocation/compute \
  -d window=7d \
  -d aggregate=namespace \
  -d accumulate=true | jq .

# 输出：
# {
#   "code": 200,
#   "data": {
#     "team-alpha-production": {
#       "name": "team-alpha-production",
#       "properties": {
#         "cluster": "prod-cluster",
#         "namespace": "team-alpha-production"
#       },
#       "window": {
#         "start": "2024-01-08T00:00:00Z",
#         "end": "2024-01-15T00:00:00Z"
#       },
#       "cpuCost": 45.67,           # CPU 成本
#       "gpuCost": 0,               # GPU 成本
#       "ramCost": 23.45,           # 内存成本
#       "pvCost": 12.34,            # 存储成本
#       "networkCost": 5.67,        # 网络成本
#       "loadBalancerCost": 15.00,  # LB 成本
#       "totalCost": 102.13         # 总成本（7天）
#     },
#     "team-beta-production": {
#       "totalCost": 234.56
#     }
#   }
# }
```

---

## 四、预算与告警

```yaml
# === 预算告警 ===

# 使用 Prometheus + Alertmanager
groups:
- name: finops
  rules:
  # 月度预算使用率
  - alert: MonthlyBudgetHigh
    expr: |
      (
        sum by (team) (
          opencost_pod_cpu_hourly_cost * 24 * 30
          + opencost_pod_memory_hourly_cost * 24 * 30
        )
      ) 
      / 
      (
        team_monthly_budget  # 自定义指标
      ) > 0.8
    for: 1h
    labels:
      severity: warning
    annotations:
      summary: "Team {{ $labels.team }} has used {{ $value | humanizePercentage }} of monthly budget"

  # 异常成本增长
  - alert: CostSpikeDetected
    expr: |
      (
        sum by (team) (opencost_pod_total_hourly_cost)
        > 
        2 * avg by (team) (opencost_pod_total_hourly_cost[7d])
      )
    for: 2h
    labels:
      severity: warning
    annotations:
      summary: "Team {{ $labels.team }} cost is 2x higher than 7-day average"

  # 空闲节点成本
  - alert: IdleNodeCost
    expr: |
      (
        sum by (node) (node_cpu_hourly_cost)
        * on(node) group_left()
        (
          1 - (
            avg by (node) (irate(node_cpu_seconds_total{mode="idle"}[5m]))
          )
        ) < 0.1
      )
    for: 24h
    labels:
      severity: info
    annotations:
      summary: "Node {{ $labels.node }} CPU utilization < 10% for 24h"

# === 自动资源回收 ===
# 定期清理未使用的资源
apiVersion: batch/v1
kind: CronJob
metadata:
  name: resource-cleanup
  namespace: finops
spec:
  schedule: "0 2 * * *"  # 每天凌晨 2 点
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: resource-cleanup
          containers:
          - name: cleanup
            image: bitnami/kubectl
            command:
            - /bin/bash
            - -c
            - |
              # 删除 7 天未更新的临时命名空间
              kubectl get ns -l temp=true -o json | \
                jq -r '.items[] | select(.metadata.creationTimestamp < '"'$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)'"') | .metadata.name' | \
                xargs -r kubectl delete ns
              
              # 删除未绑定的 PVC（> 30 天）
              kubectl get pvc --all-namespaces -o json | \
                jq -r '.items[] | select(.status.phase == "Bound" | not) | .metadata.namespace + "/" + .metadata.name' | \
                xargs -r -I{} kubectl delete pvc -n $(echo {} | cut -d/ -f1) $(echo {} | cut -d/ -f2)
              
              # 删除已完成的 Job（> 7 天）
              kubectl get jobs --all-namespaces -o json | \
                jq -r '.items[] | select(.status.completionTime < '"'$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ)'"') | .metadata.namespace + "/" + .metadata.name' | \
                xargs -r -I{} kubectl delete job -n $(echo {} | cut -d/ -f1) $(echo {} | cut -d/ -f2)
          restartPolicy: OnFailure
```

---

## 五、面试要点

```
Q: K8s 环境常见的成本浪费有哪些？如何优化？

A: 五大浪费场景：

   1. CPU/内存过度申请：
      - 问题：requests 和 limits 设置过大
      - 优化：使用 VPA 自动调整，设置合理的 LimitRange
   
   2. 空闲节点：
      - 问题：Cluster Autoscaler 缩容不及时
      - 优化：使用 Karpenter，设置更激进的缩容策略
   
   3. 存储浪费：
      - 问题：PVC 申请过大，未启用扩容
      - 优化：使用 gp3，启用 allowVolumeExpansion
   
   4. 负载均衡浪费：
      - 问题：每个服务一个 LoadBalancer
      - 优化：使用 Ingress，共享一个 LB
   
   5. 镜像过大：
      - 问题：基础镜像包含不必要的组件
      - 优化：使用 distroless，多阶段构建

   通用策略：
   - 标签化成本分摊（按 team/project/environment）
   - 设置预算告警（月度/季度）
   - 定期资源清理（CronJob）
   - 使用 Spot 实例（可节省 70%）

Q: VPA 和 HPA 的区别？可以一起用吗？

A: 核心区别：

   VPA（垂直伸缩）：
   - 调整单个 Pod 的资源 requests/limits
   - 适用：资源使用模式变化大的应用
   - 限制：需要重启 Pod（除 Initial 模式）
   
   HPA（水平伸缩）：
   - 调整 Pod 副本数
   - 适用：无状态、可水平扩展的应用
   - 优势：无需重启，实时响应
   
   一起使用：
   - 不建议同时 Auto 模式（可能冲突）
   - 推荐组合：
     * VPA（Recommandation 模式）+ HPA（Auto 模式）
     * VPA 提供建议，HPA 自动扩缩容
     * 定期根据 VPA 建议手动调整资源
   
   最佳实践：
   - 无状态服务：HPA 为主
   - 有状态服务：VPA 为主
   - 混合：HPA 处理流量峰值，VPA 处理资源优化

Q: 如何防止团队间的资源抢占？

A: 多层防护：

   1. ResourceQuota：
      - 限制命名空间总资源
      - 防止单个团队耗尽集群
   
   2. LimitRange：
      - 设置默认资源限制
      - 防止过度申请
   
   3. PriorityClass：
      - 系统服务：system-cluster-critical
      - 核心业务：high-priority
      - 批处理：low-priority
   
   4. 节点亲和性/污点：
      - 为不同团队分配专用节点池
      - 物理隔离（成本高但最彻底）
   
   5. 成本分摊：
      - 按 team 标签统计成本
      - 月度成本报告
      - 超预算告警
```
