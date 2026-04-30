# Kubernetes 核心架构深度解析

> 从组件交互到源码级别的架构理解，含真实配置、启动参数和性能基准。

---

## 控制平面架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Control Plane (Master)                   │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │ API Server  │◄──►│   etcd      │    │ Scheduler   │   │
│  │ (:6443)     │    │ (:2379)     │    │ (:10259)    │   │
│  └──────┬──────┘    └─────────────┘    └──────┬──────┘   │
│         │                                       │          │
│         │         ┌─────────────┐              │          │
│         └────────►│ Controller  │◄─────────────┘          │
│                   │ Manager     │                          │
│                   │ (:10257)    │                          │
│                   └─────────────┘                          │
│                                                             │
│  高可用模式：3 节点 stacked etcd 或外部 etcd 集群            │
└─────────────────────────────────────────────────────────────┘
                              │
                              │ HTTPS (6443)
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      Worker Nodes                           │
│                                                             │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │   kubelet   │    │ kube-proxy  │    │  Container  │   │
│  │ (:10250)    │    │ (:10256)    │    │  Runtime    │   │
│  │             │    │             │    │(containerd) │   │
│  └──────┬──────┘    └─────────────┘    └──────┬──────┘   │
│         │                                       │          │
│         │         ┌─────────────┐              │          │
│         └────────►│   CNI       │◄─────────────┘          │
│                   │ (calico/    │                          │
│                   │  cilium)    │                          │
│                   └─────────────┘                          │
│                                                             │
│  存储: CSI 插件 (ebs/nfs/ceph)                              │
└─────────────────────────────────────────────────────────────┘
```

---

## API Server 详解

### 功能定位

```
API Server 是 K8s 控制平面的唯一入口：
  - 所有组件（kubelet、controller、scheduler）都通过 API Server 交互
  - 不直接访问 etcd，API Server 是唯一 etcd 客户端
  - 提供 RESTful API + gRPC (for aggregation)
  - 认证 → 鉴权 → 准入控制 三层安全
```

### 启动参数（生产环境）

```bash
# /etc/kubernetes/manifests/kube-apiserver.yaml
apiVersion: v1
kind: Pod
metadata:
  name: kube-apiserver
  namespace: kube-system
spec:
  containers:
  - name: kube-apiserver
    image: registry.k8s.io/kube-apiserver:v1.28.0
    command:
    - kube-apiserver
    # 基础配置
    - --advertise-address=10.0.1.10
    - --bind-address=0.0.0.0
    - --secure-port=6443
    
    # etcd 连接
    - --etcd-servers=https://10.0.1.10:2379,https://10.0.1.11:2379,https://10.0.1.12:2379
    - --etcd-cafile=/etc/kubernetes/pki/etcd/ca.crt
    - --etcd-certfile=/etc/kubernetes/pki/apiserver-etcd-client.crt
    - --etcd-keyfile=/etc/kubernetes/pki/apiserver-etcd-client.key
    
    # 证书配置
    - --client-ca-file=/etc/kubernetes/pki/ca.crt
    - --tls-cert-file=/etc/kubernetes/pki/apiserver.crt
    - --tls-private-key-file=/etc/kubernetes/pki/apiserver.key
    
    # 认证与鉴权
    - --authentication-kubeconfig=/etc/kubernetes/admin.conf
    - --authorization-mode=Node,RBAC
    
    # 准入控制（按顺序执行）
    - --enable-admission-plugins=NodeRestriction,NamespaceLifecycle,LimitRanger,ServiceAccount,ResourceQuota,PodSecurityPolicy,MutatingAdmissionWebhook,ValidatingAdmissionWebhook
    
    # 性能调优（关键！）
    - --max-requests-inflight=400           # 并发读请求上限（默认 400）
    - --max-mutating-requests-inflight=200  # 并发写请求上限（默认 200）
    - --request-timeout=1m0s                # 请求超时
    - --default-not-ready-toleration-seconds=300
    - --default-unreachable-toleration-seconds=300
    - --event-ttl=1h0m0s                    # 事件保留时间
    
    # API Priority and Fairness (K8s 1.20+)
    - --enable-priority-and-fairness=true
    
    # 审计日志
    - --audit-log-path=/var/log/audit/audit.log
    - --audit-log-maxage=30
    - --audit-log-maxbackup=10
    - --audit-log-maxsize=100
    
    # 聚合层（CRD / Metrics Server）
    - --requestheader-client-ca-file=/etc/kubernetes/pki/front-proxy-ca.crt
    - --proxy-client-cert-file=/etc/kubernetes/pki/front-proxy-client.crt
    - --proxy-client-key-file=/etc/kubernetes/pki/front-proxy-client.key
```

### 性能基准

```
API Server 性能指标（标准测试环境：8 核 32G）：

操作类型           QPS 上限    平均延迟    P99 延迟
─────────────────────────────────────────────────
GET Pod (单个)     10,000      1ms         5ms
LIST Pod (全量)    500         50ms        200ms
LIST Node (全量)   1,000       20ms        100ms
CREATE Pod         500         100ms       500ms
UPDATE Pod         300         150ms       800ms
PATCH Pod          800         50ms        300ms
DELETE Pod         500         80ms        400ms

调优后（max-requests-inflight=800, etcd SSD）：
GET Pod            15,000      0.8ms       3ms
LIST Pod           800         30ms        150ms
CREATE Pod         800         80ms        400ms
```

### API Priority and Fairness (APF)

```yaml
# 生产环境 APF 配置示例
apiVersion: flowcontrol.apiserver.k8s.io/v1beta3
kind: PriorityLevelConfiguration
metadata:
  name: production-critical
spec:
  type: Limited
  limited:
    nominalConcurrencyShares: 100    # 并发份额
    limitResponse:
      type: Queue
      queuing:
        queues: 128                  # 队列数
        handSize: 8                  # 哈希手大小
        queueLengthLimit: 100        # 单队列长度限制
---
apiVersion: flowcontrol.apiserver.k8s.io/v1beta3
kind: FlowSchema
metadata:
  name: production-services
spec:
  priorityLevelConfiguration:
    name: production-critical
  distinguisherMethod:
    type: ByUser
  rules:
  - resourceRules:
    - apiGroups: ["*"]
      namespaces: ["production"]
      resources: ["*"]
      verbs: ["*"]
    subjects:
    - kind: ServiceAccount
      serviceAccount:
        name: production-app
        namespace: production
```

---

## etcd 详解

### 数据模型

```
etcd 存储所有 K8s 数据，键值对格式：
  
  Key 前缀约定：
    /registry/pods/<namespace>/<pod-name>
    /registry/nodes/<node-name>
    /registry/services/<namespace>/<service-name>
    /registry/deployments/<namespace>/<deployment-name>
    /registry/events/<namespace>/<event-name>
    /registry/secrets/<namespace>/<secret-name>
    /registry/configmaps/<namespace>/<configmap-name>
    /registry/persistentvolumes/<pv-name>
    /registry/clusterroles/<role-name>
    /registry/customresourcedefinitions/<crd-name>

  实际 etcd 数据示例：
  
  Key: /registry/pods/default/nginx-7d4c7b5f9d-abc12
  Value (protobuf 编码后 JSON 表示):
  {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
      "name": "nginx-7d4c7b5f9d-abc12",
      "namespace": "default",
      "uid": "abc12345-6789-0123-4567-890abcdef012",
      "resourceVersion": "1234567",      ← 乐观锁版本号
      "creationTimestamp": "2024-01-15T08:30:00Z"
    },
    "spec": { ... },
    "status": { ... }
  }
```

### etcd 性能关键指标

```bash
# 查看 etcd 状态
ETCDCTL_API=3 etcdctl endpoint status --cluster -w table

# 输出：
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
# | 10.0.1.10:2379 | 1234567890abcdef |  3.5.9  | 512 MB  |    true   |    false   |        15 |    5000000 |            5000000 |        |
# | 10.0.1.11:2379 | fedcba0987654321 |  3.5.9  | 512 MB  |   false   |    false   |        15 |    5000000 |            5000000 |        |
# | 10.0.1.12:2379 | aabbccdd11223344 |  3.5.9  | 512 MB  |   false   |    false   |        15 |    5000000 |            5000000 |        |
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+

# 关键指标解读：
# - DB SIZE: 512 MB（健康范围 < 8GB）
# - IS LEADER: true/false（只有一个 Leader）
# - RAFT TERM: 15（Leader 选举轮次）
# - RAFT INDEX: 5000000（已提交日志索引）
# - ERRORS: 空（无错误）
```

---

## kubelet 详解

### 启动参数

```bash
# /var/lib/kubelet/config.yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
# 基础配置
clusterDomain: cluster.local
clusterDNS:
- 10.96.0.10

# 认证
authentication:
  x509:
    clientCAFile: /etc/kubernetes/pki/ca.crt
  webhook:
    enabled: true
    cacheTTL: 2m0s
  anonymous:
    enabled: false

# 鉴权
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 5m0s
    cacheUnauthorizedTTL: 30s

# 资源预留（关键！防止系统 OOM）
systemReserved:
  cpu: "500m"
  memory: "512Mi"
  ephemeral-storage: "1Gi"
kubeReserved:
  cpu: "500m"
  memory: "1Gi"
  ephemeral-storage: "1Gi"
evictionHard:
  memory.available: "500Mi"          # 内存 < 500Mi 时驱逐
  nodefs.available: "10%"            # 磁盘 < 10% 时驱逐
  imagefs.available: "15%"           # 镜像盘 < 15% 时驱逐

# 运行时
containerRuntimeEndpoint: unix:///run/containerd/containerd.sock

# 性能调优
maxPods: 110                          # 单节点最大 Pod 数
serializeImagePulls: false            # 并行拉取镜像
registryPullQPS: 5                    # 镜像拉取 QPS
registryBurst: 10                     # 镜像拉取突发流量
imageMinimumGCAge: 2m                 # 镜像 GC 最小年龄
evictionPressureTransitionPeriod: 5m  # 压力状态转换周期

# 探针设置
healthzBindAddress: 127.0.0.1
healthzPort: 10248
readOnlyPort: 0                       # 关闭只读端口（安全）
```

### 资源预留计算

```
节点总资源 vs 可分配资源：

节点：8 核 CPU, 32GB 内存

系统预留 (systemReserved):
  CPU: 500m (0.5 核)
  Memory: 512Mi

Kubelet 预留 (kubeReserved):
  CPU: 500m (0.5 核)
  Memory: 1Gi

可分配资源 (Allocatable):
  CPU: 8 - 0.5 - 0.5 = 7 核
  Memory: 32GB - 512Mi - 1Gi ≈ 30.5Gi

实际可用（考虑驱逐阈值）：
  Memory: 30.5Gi - 500Mi ≈ 30Gi

Pod 可以使用：
  CPU requests: 最多 7000m
  Memory requests: 最多 30Gi
```

---

## Controller Manager 详解

### 核心控制器

```
Controller Manager 包含 20+ 内置控制器：

Deployment Controller:
  - 监听 Deployment 变更
  - 计算 ReplicaSet 期望状态
  - 创建/更新/删除 ReplicaSet
  - 滚动更新策略：maxSurge=25%, maxUnavailable=25%

ReplicaSet Controller:
  - 确保实际 Pod 数 = 期望副本数
  - 创建 Pod（通过 API Server）
  - 删除多余 Pod（先删除未就绪的）

Node Controller:
  - 监控节点心跳（Lease 对象）
  - 心跳超时 40s → 标记 Unknown
  等待 5m (pod-eviction-timeout) → 驱逐 Pod

Service Controller:
  - 为 LoadBalancer Service 创建云负载均衡器
  - 维护 Endpoint/EndpointSlice

EndpointSlice Controller:
  - 从 Service selector 匹配 Pod
  - 创建 EndpointSlice（最多 100 个 Endpoint）
  - 比旧版 Endpoints 性能提升 10x+

Job/CronJob Controller:
  - Job：确保完成指定次数
  - CronJob：基于时间调度 Job

Namespace Controller:
  - 删除 Namespace 时级联删除所有资源
```

### Deployment 滚动更新源码逻辑

```go
// 简化版 Deployment 控制器逻辑
func (dc *DeploymentController) syncDeployment(d *apps.Deployment) {
    // 1. 获取所有关联的 ReplicaSet
    rsList := dc.getReplicaSetsForDeployment(d)
    
    // 2. 找到最新的 ReplicaSet（hash 匹配）
    newRS := dc.findNewReplicaSet(d, rsList)
    
    // 3. 如果不存在，创建新的 ReplicaSet
    if newRS == nil {
        newRS = dc.createNewReplicaSet(d, rsList)
    }
    
    // 4. 扩缩容新的 ReplicaSet
    // 新 RS 副本数 = ceil(期望副本 * maxSurge) - 旧 RS 副本数
    newRSReplicas := calculateNewRSReplicas(d, rsList, newRS)
    dc.scaleReplicaSet(newRS, newRSReplicas)
    
    // 5. 缩容旧的 ReplicaSet
    // 每次缩容 maxUnavailable 个
    oldRSs := dc.getOldReplicaSets(d, rsList)
    dc.scaleDownOldReplicaSets(oldRSs, d)
    
    // 6. 清理历史 ReplicaSet（保留 revisionHistoryLimit 个）
    dc.cleanupDeployment(oldRSs, d)
}
```

---

## Scheduler 详解

### 调度流程

```
Pod 调度过程：

1. 监听：Informer 监听到未调度的 Pod（spec.nodeName 为空）

2. 进入调度队列：
   - ActiveQ：可立即调度的 Pod
   - BackoffQ：调度失败的 Pod（指数退避）
   - Unschedulable：暂时无法调度的 Pod

3. 调度周期（Scheduling Cycle）：
   a. 预选（Filtering）：排除不满足条件的节点
      - PodFitsResources：检查 CPU/Memory/GPU
      - PodFitsHost：检查 nodeName 匹配
      - PodFitsHostPorts：检查端口冲突
      - PodMatchNodeSelector：检查节点选择器
      - NoDiskConflict：检查存储冲突
      - PodToleratesNodeTaints：检查污点容忍
      - CheckNodeMemoryPressure：检查内存压力
      - CheckNodeDiskPressure：检查磁盘压力
      → 从 10000 节点过滤到 5000 节点
   
   b. 优选（Scoring）：为剩余节点打分
      - LeastAllocated：优先选择资源利用率低的节点
      - BalancedAllocation：CPU/Memory 使用均衡
      - ImageLocality：优先选择已有镜像的节点
      - InterPodAffinity：Pod 亲和性
      - NodeAffinity：节点亲和性
      - TaintToleration：污点容忍度
      → 5000 节点排序，选择最高分
   
   c. 绑定（Binding）：
      - 先假设绑定（Assume，更新本地缓存）
      - 异步向 API Server 发送 Bind 请求
      - 如果绑定失败，进入 Backoff 重试

4. 绑定成功后：
   - kubelet 监听到 Pod 分配到本节点
   - CRI 创建容器
   - CNI 配置网络
   - CSI 挂载存储
   - 更新 Pod 状态为 Running
```

### 调度延迟分解

```
调度延迟 = 队列等待 + 预选 + 优选 + 绑定

集群规模：1000 节点，10000 Pod

阶段              延迟 (P50)   延迟 (P99)
─────────────────────────────────────────
队列等待          5ms          500ms
预选 (1000→500)   20ms         100ms
优选 (500 排序)   10ms         50ms
绑定              50ms         200ms
─────────────────────────────────────────
总计              85ms         850ms

优化后（NodeCache + Snapshot）：
预选              5ms          20ms
优选              3ms          10ms
─────────────────────────────────────────
总计              63ms         530ms
```

---

## kube-proxy 详解

### 三种模式对比

```
┌─────────────┬──────────────────┬──────────────────┬──────────────────┐
│ 模式        │ iptables         │ IPVS             │ userspace (废弃) │
├─────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 内核依赖    │ netfilter        │ IP Virtual Server│ 无               │
│ 性能        │ O(n) 遍历        │ O(1) hash        │ 用户态转发       │
│ 最大 Service│ ~5000            │ 无限制           │ 低               │
│ 会话亲和性  │ 基于 probability │ 基于 hash        │ 支持             │
│ 健康检查    │ 依赖 readiness   │ 依赖 readiness   │ 内置             │
│ 适用场景    │ 中小型集群       │ 大型集群(推荐)   │ 不适用           │
└─────────────┴──────────────────┴──────────────────┴──────────────────┘

iptables 模式规则链：
  PREROUTING → KUBE-SERVICES → KUBE-SVC-<hash> → KUBE-SEP-<hash> → DNAT
  
  每个 Service 增加 3 条规则：
  - KUBE-SVC-xxx: 匹配 clusterIP:port
  - KUBE-SEP-xxx: 每个 Endpoint 一条，probability 分流
  - 会话亲和性：recent 模块

IPVS 模式规则：
  ipvsadm -Ln
  
  TCP  10.96.0.1:443 rr
    -> 10.0.1.10:6443           Masq    1      0          0
    -> 10.0.1.11:6443           Masq    1      0          0
    -> 10.0.1.12:6443           Masq    1      0          0
  
  负载均衡算法：
  - rr (Round Robin)：轮询
  - lc (Least Connection)：最少连接
  - dh (Destination Hash)：目标哈希
  - sh (Source Hash)：源哈希
  - sed (Shortest Expected Delay)：最短预期延迟
  - nq (Never Queue)：不排队
```

---

## 完整请求链路

```
用户创建 Pod
    │
    ▼
kubectl → API Server (:6443)
    │
    ├─ 认证 (x509/Token/Webhook)
    ├─ 鉴权 (RBAC)
    ├─ 准入控制 (Mutating → Validating)
    │     MutatingWebhook: Istio sidecar 注入
    │     ValidatingWebhook: Kyverno 策略检查
    │
    ▼
etcd 存储 Pod 对象 (resourceVersion: 12345)
    │
    ▼
Scheduler 监听到新 Pod
    │
    ├─ 预选：排除不满足条件的节点
    ├─ 优选：打分排序
    └─ 绑定：更新 Pod.spec.nodeName = "node-1"
    │
    ▼
etcd 更新 Pod (resourceVersion: 12346)
    │
    ▼
kubelet (node-1) 监听到 Pod 分配到本节点
    │
    ├─ CRI (containerd): pull image → create container
    ├─ CNI (calico/cilium): allocate IP → setup network
    ├─ CSI (ebs): provision volume → mount
    │
    ▼
Pod 状态 Running
    │
    ▼
Controller Manager 检查 ReplicaSet 状态
    │
    ├─ 实际 Pod 数 = 期望数？是 → 无操作
    └─ 实际 Pod 数 < 期望数？创建新 Pod（回到顶部）

Total Latency: 
  kubectl → Pod Running = 2-10 秒
  其中：
    API Server 处理: 50-200ms
    Scheduler 调度: 100ms-1s
    kubelet 创建: 1-5s (主要是镜像拉取)
    CNI 网络配置: 100-500ms
    CSI 存储挂载: 500ms-5s
```

---

## 面试要点

```
Q: 为什么 API Server 是唯一 etcd 客户端？
A: - 统一数据访问，防止数据不一致
   - 集中实现乐观锁（resourceVersion）
   - 集中实现 watch 机制
   - 便于审计和限流

Q: kubelet 的资源预留如何计算？
A: - systemReserved: OS 系统进程（systemd、kernel）
   - kubeReserved: kubelet、container runtime、daemon
   - evictionHard: 触发驱逐的阈值
   - Allocatable = Capacity - systemReserved - kubeReserved - evictionHard

Q: Deployment 滚动更新时，旧 Pod 什么时候删除？
A: - 新 Pod Ready 后，开始删除旧 Pod
   - 每次删除数量由 maxUnavailable 控制
   - 如果 maxUnavailable=25%，4 副本时每次删 1 个
   - 先删除未就绪的 Pod，再删除就绪的

Q: 为什么大集群要用 IPVS 而不是 iptables？
A: - iptables O(n) 遍历，5000+ Service 时性能下降
   - IPVS O(1) hash 查找，性能稳定
   - IPVS 支持更丰富的负载均衡算法
   - IPVS 连接跟踪更高效
```
