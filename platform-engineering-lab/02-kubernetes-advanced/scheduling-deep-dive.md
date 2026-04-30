# K8s 调度深度解析

> Kubernetes 调度器是集群资源分配的核心组件。本节从算法原理到源码实现，深入分析调度流程、性能优化和自定义扩展。

---

## 一、调度器架构

### 1.1 整体流程

```
Pod 创建 → API Server → etcd
    │
    │ Watch（Informer）
    ▼
Scheduler
    │
    ├─ 1. 调度队列（Scheduling Queue）
    │   - ActiveQ：可立即调度的 Pod（优先队列）
    │   - BackoffQ：调度失败的 Pod（指数退避）
    │   - UnschedulableQ：暂时无法调度的 Pod
    │
    ├─ 2. 调度周期（Scheduling Cycle）
    │   │
    │   ├─ 2.1 预选（Filtering）
    │   │   排除不满足条件的节点
    │   │   → 从 N 节点过滤到 M 节点（M ≤ N）
    │   │
    │   ├─ 2.2 优选（Scoring）
    │   │   为剩余节点打分
    │   │   → M 个节点排序，选最高分
    │   │
    │   └─ 2.3 抢占（Preemption）【可选】
    │       如果没有节点满足，尝试抢占低优先级 Pod
    │
    ├─ 3. 绑定周期（Binding Cycle）
    │   │
    │   ├─ 3.1 假定绑定（Assume）
    │   │   更新本地缓存（nodeInfo），不调用 API Server
    │   │
    │   └─ 3.2 异步绑定（Bind）
    │       异步调用 API Server，更新 Pod.spec.nodeName
    │
    ▼
kubelet（目标节点）
    - 监听到 Pod 分配到本节点
    - CRI 创建容器
    - CNI 配置网络
    - 更新 Pod 状态为 Running
```

### 1.2 调度队列详解

```
Scheduling Queue 结构：

┌─────────────────────────────────────────┐
│  ActiveQ（优先队列）                     │
│   - 数据结构：堆（Heap）                  │
│   - 排序依据：优先级 > 创建时间            │
│   - 容量：无限制                         │
│   - 调度器从此队列取 Pod                 │
│                                         │
│   Pod A (Priority: 1000)                │
│   Pod B (Priority: 500)                 │
│   Pod C (Priority: 500, older)          │
│   Pod D (Priority: 100)                 │
└─────────────────────────────────────────┘
              │ 调度失败
              ▼
┌─────────────────────────────────────────┐
│  BackoffQ（退避队列）                    │
│   - 数据结构：堆                          │
│   - 排序依据：下次可调度时间               │
│   - 退避策略：指数退避                    │
│     第 1 次失败：1s                       │
│     第 2 次失败：2s                       │
│     第 3 次失败：4s                       │
│     ...                                  │
│     最大退避：100s                        │
│   - 超过最大退避次数 → UnschedulableQ     │
│                                         │
│   Pod E (nextSchedule: 08:30:05)        │
│   Pod F (nextSchedule: 08:30:12)        │
└─────────────────────────────────────────┘
              │ 退避超期或集群变化
              ▼
┌─────────────────────────────────────────┐
│  UnschedulableQ（不可调度队列）          │
│   - 数据结构：Map（快速查找）             │
│   - 进入条件：                            │
│     * 资源不足且无低优先级 Pod 可抢占     │
│     * 污点排斥且无容忍                    │
│     * 亲和性不满足                        │
│   - 触发重新调度：                        │
│     * 新节点加入                          │
│     * 节点资源释放                        │
│     * 污点变更                            │
│     * 每 30-60s 自动扫描                  │
└─────────────────────────────────────────┘

队列间流动：
  ActiveQ → 调度失败 → BackoffQ → 退避到期 → ActiveQ
  ActiveQ → 调度失败(多次) → UnschedulableQ → 集群变化 → ActiveQ
  BackoffQ → 退避超期 → ActiveQ
```

### 1.3 预选（Filtering）插件

```go
// 预选插件列表（默认启用）

1. NodeUnschedulable
   排除 spec.unschedulable=true 的节点
   
2. NodeName
   检查 pod.spec.nodeName 是否匹配
   
3. NodePorts
   检查端口冲突
   
4. NodeResourcesFit
   检查 CPU/Memory/GPU 是否满足
   策略：LeastAllocated / MostAllocated / RequestedToCapacityRatio
   
5. VolumeRestrictions
   检查 EBS/AzureDisk 等限制（不能跨节点挂载）
   
6. TaintToleration
   检查 Pod 是否容忍节点污点
   
7. NodeAffinity
   检查节点亲和性（requiredDuringScheduling）
   
8. PodTopologySpread
   检查拓扑分布约束
   
9. InterPodAffinity
   检查 Pod 间亲和性/反亲和性
   
10. VolumeBinding
    检查 PVC 是否可绑定（WaitForFirstConsumer）
    
11. VolumeZone
    检查 Volume 和节点是否在同一可用区
```

### 1.4 优选（Scoring）插件

```go
// 优选插件列表（默认启用）

1. NodeResourcesBalancedAllocation
   评分依据：CPU 和 Memory 使用率差异
   公式：10 - |cpuFraction - memoryFraction| * 10
   目标：选择 CPU 和 Memory 使用均衡的节点
   
   示例：
     节点 A：CPU 30%, Memory 30% → 分数 = 10 - 0 = 10（最高）
     节点 B：CPU 80%, Memory 20% → 分数 = 10 - 6 = 4
     节点 C：CPU 10%, Memory 90% → 分数 = 10 - 8 = 2

2. NodeResourcesLeastAllocated
   评分依据：资源空闲比例
   公式：(10 - cpuFraction * 10) * cpuWeight + (10 - memoryFraction * 10) * memoryWeight
   权重默认：CPU=1, Memory=1
   目标：选择资源使用率低的节点
   
   示例：
     节点 A：CPU 30%, Memory 30% → 分数 = 7 + 7 = 14
     节点 B：CPU 60%, Memory 60% → 分数 = 4 + 4 = 8

3. VolumeBinding
   评分依据：Volume 延迟绑定
   已绑定 Volume 的节点得分更高
   
4. InterPodAffinity
   评分依据：Pod 亲和性（preferredDuringScheduling）
   匹配的 Pod 越多，得分越高
   
5. NodeAffinity
   评分依据：节点亲和性（preferredDuringScheduling）
   匹配的标签越多，得分越高
   
6. PodTopologySpread
   评分依据：拓扑分布均衡性
   分布越均匀，得分越高
   
7. TaintToleration
   评分依据：污点容忍度
   优先选择没有污点的节点
   
8. ImageLocality
   评分依据：节点上是否已有镜像
   有镜像的节点得分更高
   
9. NodePreferAvoidPods
   评分依据：节点注解 "scheduler.alpha.kubernetes.io/preferAvoidPods"
   
评分归一化：
  每个插件得分范围：0-100
  最终得分 = 各插件得分 × 权重 之和
  权重配置在 KubeSchedulerConfiguration 中
```

---

## 二、调度性能优化

### 2.1 调度延迟分解

```
调度延迟 = 队列等待 + 预选 + 优选 + 抢占 + 绑定

集群规模：1000 节点，10000 Pod，创建 100 个新 Pod

阶段                  P50      P95      P99
─────────────────────────────────────────────
队列等待（ActiveQ）    1ms      5ms      20ms
预选（1000→200）      15ms     80ms     200ms
  - NodeResourcesFit   5ms      30ms     80ms
  - InterPodAffinity   8ms      40ms     100ms
  - PodTopologySpread  2ms      10ms     20ms
优选（200 排序）       5ms      20ms     50ms
抢占（如果需要）       0ms      0ms      500ms
绑定                   10ms     30ms     80ms
─────────────────────────────────────────────
总计                   31ms     135ms    850ms

优化后（NodeCache + Snapshot）：
预选（1000→200）      3ms      10ms     25ms
  - NodeResourcesFit   1ms      3ms      8ms
  - InterPodAffinity   1.5ms    5ms      12ms
总计                   19ms     65ms     175ms
```

### 2.2 性能优化手段

```yaml
# KubeSchedulerConfiguration
apiVersion: kubescheduler.config.k8s.io/v1
kind: KubeSchedulerConfiguration
profiles:
- schedulerName: default-scheduler
  plugins:
    # 禁用不用的插件，减少计算
    filter:
      disabled:
      - name: NodeResourcesFit  # 如果不需要，禁用
      enabled:
      - name: NodeResourcesFit
        weight: 1
    
    score:
      # 调整插件权重
      - name: NodeResourcesBalancedAllocation
        weight: 1
      - name: NodeResourcesLeastAllocated
        weight: 1
      - name: ImageLocality
        weight: 1
      # 降低 ImageLocality 权重（镜像拉取已优化）
      - name: ImageLocality
        weight: 0  # 禁用

  # 百分比插件配置
  pluginConfig:
  - name: NodeResourcesFit
    args:
      scoringStrategy:
        type: LeastAllocated  # 或 MostAllocated
        resources:
        - name: cpu
          weight: 1
        - name: memory
          weight: 1

# 调度器启动参数优化
# --percentage-of-nodes-to-score=50
# 默认：当节点数 > 100 时，只评分 50% 的节点
# 可以增大到 100（评分所有节点，更精确但更慢）
```

### 2.3 超大规模集群优化

```
10,000 节点集群的额外优化：

1. API Server 优化：
   - APF（API Priority and Fairness）
   - Watch Bookmark
   - LIST 分页
   
2. etcd 优化：
   - SSD / NVMe 磁盘
   - compaction 5 分钟间隔
   - defragment 每周
   
3. 调度器优化：
   - NodeCache：缓存节点状态
   - Snapshot：批量评分
   - 禁用非必要插件
   
4. 节点优化：
   - 降低 kubelet 同步频率
   - 共享 Informer
   - 减少 Event 上报

实测数据（10,000 节点）：
  - 调度延迟 P99：500ms（优化前 5s）
  - 10,000 Pod 批量创建：60s 完成
  - API Server CPU：< 30%
  - etcd fsync P99：< 5ms
```

---

## 三、自定义调度器

### 3.1 Scheduler Framework

```go
// 调度框架扩展点

package scheduler

// 扩展点（按执行顺序）：
// 1. QueueSort：决定 Pod 在队列中的顺序
// 2. PreFilter：预处理，收集信息
// 3. Filter：排除不满足条件的节点
// 4. PostFilter：过滤后处理（如抢占）
// 5. PreScore：评分前预处理
// 6. Score：为节点打分
// 7. Reserve：预留资源（避免竞争）
// 8. Permit：批准或延迟绑定
// 9. PreBind：绑定前准备（如创建 Volume）
// 10. Bind：执行绑定
// 11. PostBind：绑定后清理

// 自定义插件示例：GPU 拓扑感知调度

type GPUAwareScheduling struct {
    gpuTopology *GPUTopologyCache
}

func (g *GPUAwareScheduling) Name() string {
    return "GPUAwareScheduling"
}

// Filter：排除不满足 GPU 拓扑的节点
func (g *GPUAwareScheduling) Filter(
    ctx context.Context,
    state *framework.CycleState,
    pod *v1.Pod,
    nodeInfo *framework.NodeInfo,
) *framework.Status {
    gpuReq := getGPURequest(pod)
    if gpuReq == 0 {
        return framework.NewStatus(framework.Success)
    }
    
    nodeGPUInfo := g.gpuTopology.GetNodeGPUInfo(nodeInfo.Node().Name)
    
    // 检查是否有足够 GPU
    if len(nodeGPUInfo.AvailableGPUs) < gpuReq {
        return framework.NewStatus(
            framework.Unschedulable,
            "insufficient GPUs",
        )
    }
    
    // 检查 NVLink 拓扑（如果 Pod 请求多个 GPU）
    if gpuReq > 1 {
        if !nodeGPUInfo.HasNVLinkGroup(gpuReq) {
            return framework.NewStatus(
                framework.Unschedulable,
                "no NVLink group for requested GPUs",
            )
        }
    }
    
    return framework.NewStatus(framework.Success)
}

// Score：优先选择 NVLink 距离近的 GPU
func (g *GPUAwareScheduling) Score(
    ctx context.Context,
    state *framework.CycleState,
    pod *v1.Pod,
    nodeName string,
) (int64, *framework.Status) {
    gpuReq := getGPURequest(pod)
    if gpuReq <= 1 {
        return 100, nil  // 单 GPU 无需拓扑优化
    }
    
    nodeGPUInfo := g.gpuTopology.GetNodeGPUInfo(nodeName)
    
    // 计算最佳 NVLink 组的平均距离
    avgDistance := nodeGPUInfo.GetBestNVLinkGroupDistance(gpuReq)
    
    // 距离越近，得分越高
    // NVLink: 0-hop = 100分, 1-hop = 80分, 2-hop = 60分
    score := int64(100 - avgDistance*20)
    if score < 0 {
        score = 0
    }
    
    return score, nil
}
```

### 3.2 多调度器部署

```yaml
# 自定义调度器部署
apiVersion: v1
kind: ConfigMap
metadata:
  name: gpu-scheduler-config
  namespace: kube-system
data:
  scheduler-config.yaml: |
    apiVersion: kubescheduler.config.k8s.io/v1
    kind: KubeSchedulerConfiguration
    profiles:
    - schedulerName: gpu-scheduler
      plugins:
        filter:
          enabled:
          - name: GPUAwareScheduling
        score:
          enabled:
          - name: GPUAwareScheduling
            weight: 100

---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: gpu-scheduler
  namespace: kube-system
spec:
  replicas: 2
  selector:
    matchLabels:
      app: gpu-scheduler
  template:
    metadata:
      labels:
        app: gpu-scheduler
    spec:
      serviceAccountName: gpu-scheduler
      containers:
      - name: scheduler
        image: k8s.gcr.io/kube-scheduler:v1.28.0
        command:
        - kube-scheduler
        - --config=/etc/kubernetes/scheduler-config.yaml
        - --scheduler-name=gpu-scheduler
        volumeMounts:
        - name: config
          mountPath: /etc/kubernetes
      volumes:
      - name: config
        configMap:
          name: gpu-scheduler-config

---
# Pod 指定调度器
apiVersion: v1
kind: Pod
metadata:
  name: gpu-training
spec:
  schedulerName: gpu-scheduler  # 使用自定义调度器
  containers:
  - name: training
    image: pytorch-training:latest
    resources:
      limits:
        nvidia.com/gpu: 4
```

---

## 四、面试要点

```
Q: K8s 调度器的预选和优选有什么区别？

A: 预选（Filtering）：
   - 目的：排除不满足条件的节点
   - 输出：从 N 节点过滤到 M 节点（M ≤ N）
   - 插件：NodeResourcesFit、TaintToleration、NodeAffinity 等
   - 特性：是/否判断，无分数
   
   优选（Scoring）：
   - 目的：在剩余节点中选择最优的
   - 输出：M 个节点的分数排序
   - 插件：NodeResourcesLeastAllocated、InterPodAffinity 等
   - 特性：0-100 分数，选择最高分
   
   关系：
   - 先预选，后优选
   - 预选排除的节点不参与优选
   - 最终选择优选得分最高的节点

Q: 为什么调度器使用本地缓存（Assume）而不是直接调用 API Server？

A: 性能优化：
   - 调度是高频操作（每秒数十次）
   - 如果每次调度都调用 API Server，延迟高且压力大
   - Assume 在本地缓存中预占资源，异步绑定
   
   一致性保证：
   - 绑定失败时，缓存回滚
   - 下一个 Pod 调度时看到最新状态
   - 极端情况下可能超卖（概率极低）
   
   实际效果：
   - 调度延迟从 500ms 降到 50ms
   - API Server 压力减少 80%

Q: 如何处理调度器性能瓶颈？

A: 排查方法：
   1. 查看调度延迟：
      kubectl get --raw /metrics | grep scheduler
      scheduler_e2e_scheduling_duration_seconds_bucket
   
   2. 查看队列深度：
      scheduler_pending_pods
   
   3. 查看插件耗时：
      framework_extension_point_duration_seconds
   
   优化方案：
   1. 禁用非必要插件
   2. 调整 percentage-of-nodes-to-score
   3. 增大 status-processors（多调度器模式）
   4. 优化 API Server 和 etcd
   5. 使用 NodeCache 和 Snapshot
```
