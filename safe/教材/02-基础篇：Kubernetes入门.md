# 第2章 Kubernetes 入门

> **本章目标**：建立对 Kubernetes 架构、核心组件、资源对象的系统性理解。我们将深入探索控制平面的内部工作机制、Pod 的生命周期、Service 的网络原理，以及 kubectl 的高级用法。
>
> 读完本章后，你应该能够理解 K8s 的完整请求处理链、各种工作负载控制器的适用场景，以及如何通过 SecurityContext 保障 Pod 安全。

---

## 2.1 Kubernetes 架构概览

### 2.1.1 设计哲学：声明式 API 与控制器模式

Kubernetes 的核心设计哲学是**声明式 API（Declarative API）**和**控制器模式（Controller Pattern）**。这与传统的命令式（Imperative）管理有本质区别：

| 方式 | 你告诉系统 | 系统保证 |
|------|-----------|---------|
| **命令式** | "执行这个操作" | 只执行一次 |
| **声明式** | "我想要这个状态" | 持续收敛到目标状态 |

```yaml
# 命令式：直接创建 Pod（一次性）
kubectl run nginx --image=nginx

# 声明式：描述期望状态（持续维护）
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 3
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:1.25
```

**控制器模式的工作方式**：

```
用户提交期望状态 (Desired State)
        │
        ▼
┌───────────────┐
│  API Server   │  ← 存储到 etcd
└───────┬───────┘
        │ Watch 通知
        ▼
┌───────────────┐     ┌───────────────┐
│  Controller   │────►│   实际状态     │
│  (控制回路)    │     │  (Current)    │
│               │◄────│               │
│  比较 Desired   │     │  观察 Current  │
│  与 Current    │     │               │
│  差异 → 执行动作 │     │               │
└───────────────┘     └───────────────┘
```

每个控制器都是一个无限循环（control loop）：
1. 观察当前状态（通过 API Server 的 List/Watch）
2. 比较当前状态与期望状态
3. 如果有差异，执行相应动作使实际状态趋近期望状态
4. 回到步骤 1

这种设计的好处是**自愈能力**——如果某个 Pod 被意外删除，Deployment 控制器会检测到实际副本数 < 期望副本数，自动创建新的 Pod。

### 2.1.2 控制平面（Control Plane）组件

```
┌─────────────────────────────────────────────────────────────────────┐
│                         Control Plane                                │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌───────────┐ │
│  │kube-apiserver│  │    etcd     │  │kube-scheduler│  │kube-      │ │
│  │             │  │             │  │             │  │controller │ │
│  │ • REST入口   │  │ • 键值存储   │  │ • Pod调度   │  │-manager   │ │
│  │ • 认证鉴权   │  │ • 集群状态   │  │ • 资源匹配   │  │           │ │
│  │ • 准入控制   │  │ • Watch机制  │  │ • 亲和性    │  │ • 副本管理 │ │
│  │ • 数据校验   │  │ • 一致性    │  │ • 污点容忍   │  │ • 节点健康 │ │
│  │             │  │             │  │             │  │ • 端点管理 │ │
│  └──────┬──────┘  └──────┬──────┘  └──────┬──────┘  └─────┬─────┘ │
│         │                │                │               │       │
│         └────────────────┴────────────────┴───────────────┘       │
│                              │                                      │
│                              ▼                                      │
│                    ┌─────────────────┐                              │
│                    │   cloud-        │                              │
│                    │   controller-   │  ← 云厂商集成（AWS/Azure/GCP）│
│                    │   manager       │                              │
│                    └─────────────────┘                              │
└─────────────────────────────────────────────────────────────────────┘
```

#### kube-apiserver：集群的"中央枢纽"

kube-apiserver 是 Kubernetes 最核心的组件，它是所有操作的统一入口。它的设计遵循了 API 网关模式：

**请求处理链**：

```
客户端请求 (kubectl/curl)
        │
        ▼
┌─────────────────┐
│   TLS 终止      │  ← 验证客户端证书
└────────┬────────┘
         ▼
┌─────────────────┐
│   认证 (AuthN)   │  ← 确认"你是谁" (X.509/Token/Webhook)
└────────┬────────┘
         ▼
┌─────────────────┐
│   鉴权 (AuthZ)   │  ← 确认"你能做什么" (RBAC/ABAC/Webhook)
└────────┬────────┘
         ▼
┌─────────────────┐
│   准入控制       │  ← Mutating Webhooks → Validating Webhooks
│   (Admission)   │  ← 修改/验证资源对象
└────────┬────────┘
         ▼
┌─────────────────┐
│   etcd 读写      │  ← 持久化存储
└────────┬────────┘
         ▼
    返回响应
```

**Mutating vs Validating Admission Controllers**：

| 类型 | 执行时机 | 能否修改对象 | 失败策略 |
|------|---------|------------|---------|
| Mutating | 对象持久化之前 | 可以修改 | 可配置 |
| Validating | 对象持久化之前 | 不能修改 | 必须遵守 |

执行顺序：
1. 所有 Mutating Webhook 按顺序执行（可能修改对象）
2. 对象被持久化到 etcd
3. 所有 Validating Webhook 执行（只验证不修改）

```bash
# 查看启用的 Admission Controllers
kubectl exec -n kube-system kube-apiserver-<node> -- \
  kube-apiserver --help | grep enable-admission-plugins

# 默认启用的插件（v1.28+）：
# NamespaceLifecycle, LimitRanger, ServiceAccount, TaintNodesByCondition,
# PodSecurity, Priority, DefaultTolerationSeconds, DefaultStorageClass,
# StorageObjectInUseProtection, PersistentVolumeClaimResize,
# RuntimeClass, CertificateApproval, CertificateSigning,
# CertificateSubjectRestriction, ClusterTrustBundleAttestation,
# DefaultIngressClass, MutatingAdmissionWebhook, ValidatingAdmissionWebhook,
# ResourceQuota
```

**Watch 机制**：

API Server 支持 HTTP 长连接的 Watch 机制，这是控制器模式的基础设施：

```bash
# 使用 curl 演示 Watch 机制
curl -k -H "Authorization: Bearer <token>" \
  "https://<apiserver>:6443/api/v1/pods?watch=true"

# 返回的是一系列 JSON 流：
# {"type":"ADDED","object":{...}}
# {"type":"MODIFIED","object":{...}}
# {"type":"DELETED","object":{...}}
```

kube-scheduler、kube-controller-manager 以及所有自定义控制器都通过 Watch 监听资源变化，实现实时响应。

#### etcd：集群的"单一真相源"

etcd 是一个分布式键值存储，使用 Raft 共识算法保证数据一致性。

**Raft 协议的核心机制**：

```
┌─────────────────────────────────────────────┐
│              Raft 集群（3节点）               │
│                                             │
│    ┌──────────┐                             │
│    │ Leader   │◄──── 所有写请求             │
│    │  (主节点) │                             │
│    └────┬─────┘                             │
│         │ AppendEntries                     │
│    ┌────┴────┐                              │
│    ▼         ▼                              │
│ ┌──────┐  ┌──────┐                          │
│ │Follower│  │Follower│                       │
│ │(从节点)│  │(从节点)│                       │
│ └──────┘  └──────┘                          │
│                                             │
│ Leader选举：Timeout触发 → 发起投票 → 获得多数票 │
│ 日志复制：Leader写入 → 复制到Follower → 多数确认 │
└─────────────────────────────────────────────┘
```

**etcd 中的 K8s 数据**：

```bash
# etcd 存储的 K8s 数据前缀
/registry/
├── configmaps/
├── daemonsets/
├── deployments/
├── events/
├── namespaces/
├── nodes/
├── pods/
├── replicasets/
├── roles/
├── rolebindings/
├── secrets/
├── serviceaccounts/
├── services/
└── ...

# 查看 etcd 中的 Secret（危险操作！）
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/my-secret --print-value-only | base64 -d
```

**etcd 安全要点**：
1. etcd 默认存储数据**明文**（包括 Secret 的内容）
2. 必须启用**静态加密**（Encryption at Rest）
3. etcd 应使用独立的 CA 证书，不与其他组件共享
4. etcd  peer 通信和 client 通信都应启用 TLS

#### kube-scheduler：智能调度器

kube-scheduler 负责为新创建的 Pod 选择最合适的节点。它的调度算法分为两个阶段：

**调度流程**：

```
新 Pod 创建
    │
    ▼
┌─────────────────┐
│   过滤阶段      │  ← Predicates（硬性条件）
│   (Filtering)   │
│                 │
│ • PodFitsResources   → CPU/Memory 是否足够
│ • PodFitsHost        → nodeName 匹配
│ • PodFitsHostPorts   → 端口冲突检查
│ • PodMatchNodeSelector → 节点标签匹配
│ • NoDiskConflict     → 存储冲突检查
│ • NoVolumeZoneConflict → 可用区匹配
│ • TaintToleration    → 污点容忍检查
│
│ 结果：满足条件的节点列表
└────────┬────────┘
         ▼
┌─────────────────┐
│   打分阶段      │  ← Priorities（软性偏好）
│   (Scoring)     │
│                 │
│ • LeastRequested    → 优先选择资源空闲节点
│ • BalancedResourceAllocation → 资源均衡度
│ • ImageLocality     → 优先选择已有镜像的节点
│ • NodeAffinity      → 节点亲和性权重
│ • PodAffinity       → Pod 亲和性权重
│ • TaintToleration   → 污点容忍权重
│
│ 结果：节点得分排名
└────────┬────────┘
         ▼
    选择最高分节点
         │
    ┌────┴────┐
    │ Bind API │  ← 将 Pod 绑定到节点
    └────┬────┘
         ▼
    Pod 分配到节点
```

```bash
# 查看调度器的调度决策日志
kubectl logs -n kube-system kube-scheduler-<node>

# 查看 Pod 的调度结果
kubectl get pod <pod> -o yaml | grep nodeName
kubectl describe pod <pod> | grep -A 5 "Events"
# Events:
#   Type    Reason     Age   From     Message
#   ----    ------     ----  ----     -------
#   Normal  Scheduled  10s   default-scheduler  Successfully assigned default/my-pod to node-1
```

#### kube-controller-manager：集群的"管家"

kube-controller-manager 运行多个控制器，每个控制器负责一种资源的状态维护：

| 控制器 | 职责 | 监听对象 | 创建/修改对象 |
|--------|------|---------|-------------|
| **Node Controller** | 监控节点健康，处理 NotReady 节点 | Node | 标记节点状态 |
| **Replication Controller** | 维护 Pod 副本数 | ReplicationSet | Pod |
| **Deployment Controller** | 管理 Deployment 滚动更新 | Deployment | ReplicaSet |
| **StatefulSet Controller** | 管理有状态应用 | StatefulSet | Pod + PVC |
| **DaemonSet Controller** | 确保每个节点运行一个 Pod | DaemonSet | Pod |
| **Job Controller** | 管理批处理任务 | Job | Pod |
| **CronJob Controller** | 管理定时任务 | CronJob | Job |
| **Endpoint Controller** | 维护 Service 端点 | Service/Pod | Endpoints/EndpointSlice |
| **Service Account Controller** | 自动创建 ServiceAccount | Namespace | ServiceAccount |
| **Token Controller** | 管理 ServiceAccount Token | ServiceAccount | Secret |
| **Namespace Controller** | 清理删除中的 Namespace | Namespace | 所有资源 |
| **PV/PVC Controller** | 管理存储绑定 | PVC/PV | PV绑定关系 |

### 2.1.3 Worker Node 组件

```
┌──────────────────────────────────────────────────────────────┐
│                        Worker Node                            │
│                                                               │
│  ┌─────────────┐  ┌─────────────┐  ┌──────────────────────┐ │
│  │   kubelet   │  │ kube-proxy  │  │ Container Runtime    │ │
│  │             │  │             │  │ (containerd/CRI-O)   │ │
│  │ • Pod生命周期 │  │ • Service   │  │                      │ │
│  │ • CRI调用   │  │   负载均衡   │  │ • 镜像管理           │ │
│  │ • 探针检查  │  │ • 网络规则   │  │ • 容器创建/销毁       │ │
│  │ • 资源报告  │  │ • 会话保持   │  │ • Namespace/Cgroups  │ │
│  │ • 卷挂载   │  │             │  │ • Seccomp/Capabilities│ │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬───────────┘ │
│         │                │                    │             │
│         └────────────────┴────────────────────┘             │
│                          │                                   │
│                          ▼                                   │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                        Pods                             │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐ │ │
│  │  │ Container│  │ Container│  │    Pause Container   │ │ │
│  │  │ (app)    │  │(sidecar) │  │    (网络/IPC命名空间)  │ │ │
│  │  └──────────┘  └──────────┘  └──────────────────────┘ │ │
│  └────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────┘
```

#### kubelet：节点的"代理"

kubelet 是运行在每个 Worker 节点上的代理，它通过 CRI（Container Runtime Interface）与容器运行时交互。

**kubelet 的核心职责**：

1. **Pod 生命周期管理**：接收 API Server 的 PodSpec，通过 CRI 创建/销毁容器
2. **探针（Probe）执行**：
   - **Liveness Probe**：检查应用是否存活，失败则重启容器
   - **Readiness Probe**：检查应用是否准备好接收流量，失败则从 Service 端点移除
   - **Startup Probe**：检查应用是否已启动，在启动期间禁用 Liveness/Readiness
3. **资源监控**：通过 cAdvisor 收集容器资源使用数据，上报给 Metrics Server
4. **卷管理**：挂载/卸载 Pod 所需的存储卷
5. **网络配置**：调用 CNI 插件为 Pod 配置网络

**CRI 接口规范**：

```protobuf
// CRI 的核心接口（简化）
service RuntimeService {
    // 沙箱（Pod）管理
    rpc RunPodSandbox(RunPodSandboxRequest) returns (RunPodSandboxResponse);
    rpc StopPodSandbox(StopPodSandboxRequest) returns (StopPodSandboxResponse);
    rpc RemovePodSandbox(RemovePodSandboxRequest) returns (RemovePodSandboxResponse);
    
    // 容器管理
    rpc CreateContainer(CreateContainerRequest) returns (CreateContainerResponse);
    rpc StartContainer(StartContainerRequest) returns (StartContainerResponse);
    rpc StopContainer(StopContainerRequest) returns (StopContainerResponse);
    rpc RemoveContainer(RemoveContainerRequest) returns (RemoveContainerResponse);
    
    // 其他：Exec/Attach/PortForward/Stats 等
}
```

kubelet 通过 gRPC 调用 containerd 的 CRI 插件（或 CRI-O）来管理容器。

**PLEG（Pod Lifecycle Event Generator）**：

PLEG 是 kubelet 中的关键组件，负责监控 Pod 中容器的状态变化：

```
containerd 状态变化
        │
        ▼
┌───────────────┐
│     PLEG     │  ← 定期轮询（默认 1s）或基于事件
│               │
│  检测状态差异  │
│  (Container   │
│   Started/    │
│   Stopped/    │
│   Removed)    │
└───────┬───────┘
        │ 生成 PodLifecycleEvent
        ▼
┌───────────────┐
│   kubelet    │
│   SyncPod    │  ← 同步 Pod 状态到 API Server
└───────────────┘
```

如果 PLEG 不健康（如容器运行时响应慢），kubelet 会将节点标记为 `NotReady`。

#### kube-proxy：Service 的网络代理

kube-proxy 负责实现 Kubernetes Service 的抽象——为一组 Pod 提供统一的访问入口。

**工作模式对比**：

| 模式 | 实现方式 | 性能 | 适用场景 |
|------|---------|------|---------|
| **iptables** | 每个 Service 创建 iptables 规则 | 中（规则数增加时性能下降） | 小中型集群 |
| **ipvs** | 使用 IPVS 虚拟服务器 | 高（O(1)查找） | 中大型集群 |
| **nftables** | 使用 nftables（实验性） | 高 | 较新内核 |
| **kernelspace** | Windows 上的内核代理 | - | Windows 节点 |

```bash
# 查看 kube-proxy 使用的模式
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
# mode: "ipvs"

# 节点上查看 iptables 规则（iptables 模式）
sudo iptables -t nat -L KUBE-SERVICES -n | head -20

# 节点上查看 IPVS 规则（ipvs 模式）
sudo ipvsadm -Ln | head -30
```

---

## 2.2 Pod：最小调度单元

### 2.2.1 Pod 的设计理念

Pod 是 Kubernetes 中最小的可部署单元。为什么 K8s 选择 Pod 而不是直接使用容器？

**设计原因**：
1. **共享资源**：同一个 Pod 中的容器共享网络命名空间（IP 地址和端口空间）和 IPC 命名空间
2. **紧密耦合**：这些容器总是共同调度到同一节点，共同扩缩容
3. **辅助容器模式**：主应用容器 + sidecar 辅助容器（日志收集、监控代理、配置重载器等）

```
┌─────────────────────────────────────────────┐
│                  Pod (共享命名空间)            │
│                                              │
│  ┌──────────────────────────────────────┐   │
│  │        Pause Container (infra)        │   │
│  │        • 持有网络命名空间              │   │
│  │        • 持有 IPC 命名空间             │   │
│  │        • PID 1（回收僵尸进程）         │   │
│  └─────────────┬─────────────┬───────────┘   │
│                │             │               │
│  ┌─────────────▼─┐   ┌──────▼──────┐       │
│  │ App Container │   │ Sidecar     │       │
│  │ (nginx)       │   │ (fluent-bit)│       │
│  │               │   │             │       │
│  │ • 业务逻辑     │   │ • 日志收集   │       │
│  │ • 暴露 8080   │   │ • 读取日志   │       │
│  └───────────────┘   └─────────────┘       │
│                                              │
│  共享: IP (10.244.1.5), 端口空间, IPC, 存储卷 │
└─────────────────────────────────────────────┘
```

### 2.2.2 Pod 生命周期与状态机

Pod 从创建到销毁经历完整的状态转换：

```
用户创建 Pod
    │
    ▼
┌─────────┐   镜像拉取中    ┌─────────────┐   容器创建中    ┌─────────┐
│ Pending │ ─────────────► │ Container   │ ────────────► │ Running │
│ (挂起)  │                │ Creating    │               │ (运行中) │
│         │◄────────────── │ (容器创建)   │               │         │
│         │  调度失败/资源不足               │               │         │
└────┬────┘                                    └────┬────┘
     │                                              │
     │ 所有容器正常退出                              │ 某容器失败
     ▼                                              ▼
┌─────────┐                                  ┌─────────────┐
│Succeeded│                                  │ Failed      │
│(成功)   │                                  │ (失败)      │
└─────────┘                                  └─────────────┘
     │                                              │
     │ 被删除                                       │ 被删除
     ▼                                              ▼
┌─────────┐                                  ┌─────────────┐
│ Unknown │◄─────────────────────────────────│ Terminating │
│(未知)   │    节点失联超过 pod-eviction-timeout│ (终止中)    │
└─────────┘                                  └─────────────┘
```

**Pod Phase**：

| 状态 | 说明 | 常见原因 |
|------|------|---------|
| `Pending` | 已提交但未被调度 | 镜像拉取中、资源不足、无合适节点 |
| `Running` | 已调度且至少一个容器在运行 | 正常运行 |
| `Succeeded` | 所有容器正常退出 | Job 完成 |
| `Failed` | 至少一个容器异常退出 | 应用崩溃、OOM |
| `Unknown` | 无法获取 Pod 状态 | 节点失联 |

**Container States**：

```bash
kubectl get pod <pod> -o yaml | grep -A 5 containerStatuses
# containerStatuses:
# - containerID: containerd://xxx
#   image: nginx:1.25
#   name: nginx
#   ready: true
#   restartCount: 0
#   state:
#     running:
#       startedAt: "2024-01-01T00:00:00Z"
```

| 容器状态 | 说明 |
|---------|------|
| `Waiting` | 容器等待启动（如镜像拉取中） |
| `Running` | 容器正在运行 |
| `Terminated` | 容器已终止（正常或异常退出） |

### 2.2.3 Init Container

Init Container 在应用容器启动之前运行，用于初始化工作：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: myapp
spec:
  initContainers:
  - name: init-myservice
    image: busybox:1.36
    command: ['sh', '-c', 'until nslookup myservice; do sleep 2; done']
    # 等待 myservice 可用
  - name: init-mydb
    image: busybox:1.36
    command: ['sh', '-c', 'until nslookup mydb; do sleep 2; done']
    # 等待 mydb 可用
  containers:
  - name: myapp
    image: myapp:1.0
    ports:
    - containerPort: 80
```

**Init Container 特性**：
1. 按定义的顺序**串行**执行
2. 每个 Init Container 必须成功退出，下一个才会开始
3. 如果失败，kubelet 会根据 restartPolicy 重试
4. Init Container 不配置 readinessProbe、livenessProbe
5. Init Container 的资源 limit/request 取所有 Init Container + 应用容器的**最大值**

**典型使用场景**：
- 等待依赖服务就绪（数据库、配置中心）
- 生成配置文件
- 数据库 schema 迁移
- 从远程拉取数据

### 2.2.4 探针（Probe）详解

探针是 Kubernetes 保证应用健康的关键机制：

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    image: myapp:1.0
    livenessProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 10    # 容器启动后等待 10s 开始探测
      periodSeconds: 10          # 每 10s 探测一次
      timeoutSeconds: 5          # 探测超时 5s
      failureThreshold: 3        # 连续失败 3 次才判定失败
      successThreshold: 1        # 成功 1 次即恢复
    readinessProbe:
      httpGet:
        path: /ready
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
    startupProbe:
      httpGet:
        path: /healthz
        port: 8080
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 30       # 给足启动时间
```

**三种探针对比**：

| 探针类型 | 失败时动作 | 成功时动作 | 用途 |
|---------|-----------|-----------|------|
| **Liveness** | 重启容器 | 无 | 检测应用死锁、无限循环 |
| **Readiness** | 从 Service 端点移除 | 加入 Service 端点 | 检测应用是否准备好接收流量 |
| **Startup** | 重启容器 | 禁用 Startup Probe，启用 Liveness/Readiness | 给慢启动应用足够的启动时间 |

**探针类型**：

| 类型 | 说明 | 示例 |
|------|------|------|
| `httpGet` | HTTP GET 请求 | 检查 `/healthz` 返回 200 |
| `tcpSocket` | TCP 端口连接 | 检查端口是否可连接 |
| `grpc` | gRPC 健康检查 | 调用 gRPC 健康检查接口 |
| `exec` | 执行命令 | 检查文件是否存在 |

**探针配置最佳实践**：

1. **Liveness Probe 不要过于敏感**：
   ```yaml
   # ❌ 过于敏感：短时间流量高峰就重启
   livenessProbe:
     httpGet:
       path: /healthz
       port: 8080
     periodSeconds: 1
     failureThreshold: 1
   
   # ✅ 合理配置：给应用恢复时间
   livenessProbe:
     httpGet:
       path: /healthz
       port: 8080
     periodSeconds: 10
     timeoutSeconds: 5
     failureThreshold: 3  # 30s 后才重启
   ```

2. **Readiness 和 Liveness 使用不同端点**：
   ```yaml
   # /healthz = 基本存活（进程没死）
   # /ready = 准备好服务（数据库连接就绪、缓存预热完成）
   livenessProbe:
     httpGet:
       path: /healthz
   readinessProbe:
     httpGet:
       path: /ready
   ```

### 2.2.5 Pod 终止流程（Graceful Shutdown）

```
用户执行 kubectl delete pod
    │
    ▼
API Server 将 Pod 的 deletionTimestamp 设为当前时间 + gracePeriod
    │
    ▼
kubelet 观察到 Pod 处于 Terminating 状态
    │
    ├── 1. 执行 PreStop Hook（如果定义）
    │
    ├── 2. 发送 SIGTERM 给容器主进程 (PID 1)
    │        │
    │        ▼
    │   应用接收到 SIGTERM，开始优雅关闭
    │   • 停止接收新请求
    │   • 等待正在处理的请求完成
    │   • 关闭数据库连接
    │        │
    │        ▼
    │   应用退出（返回 exit code 0）
    │
    ├── 3. 等待 gracePeriod（默认 30s）
    │
    └── 4. 如果容器仍未退出，发送 SIGKILL
         │
         ▼
    容器强制终止，Pod 被删除
```

```yaml
apiVersion: v1
kind: Pod
spec:
  terminationGracePeriodSeconds: 60  # 默认 30s，根据应用调整
  containers:
  - name: web
    image: myapp:1.0
    lifecycle:
      preStop:
        exec:
          command: ["/bin/sh", "-c", "sleep 10 && curl -X POST localhost:8080/shutdown"]
        # PreStop 在 SIGTERM 之前执行，给应用通知时间
```

**重要安全提示**：如果应用不处理 SIGTERM，它将直接被 SIGKILL 强制终止，可能导致：
- 正在处理的请求中断
- 数据库事务未提交
- 文件损坏
- 客户端收到连接重置

---

## 2.3 工作负载控制器

### 2.3.1 Deployment：无状态应用管理

Deployment 是最常用的工作负载控制器，管理无状态应用：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deployment
  labels:
    app: web
spec:
  replicas: 3
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%           # 更新时最多多出 25% 的 Pod
      maxUnavailable: 25%     # 更新时最多有 25% 的 Pod 不可用
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        fsGroup: 2000
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: web
        image: nginx:1.25-alpine
        ports:
        - containerPort: 8080
        securityContext:
          allowPrivilegeEscalation: false
          readOnlyRootFilesystem: true
          capabilities:
            drop: ["ALL"]
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "256Mi"
            cpu: "200m"
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: cache
          mountPath: /var/cache/nginx
        - name: run
          mountPath: /var/run
        livenessProbe:
          httpGet:
            path: /healthz
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /ready
            port: 8080
          initialDelaySeconds: 5
          periodSeconds: 5
      volumes:
      - name: tmp
        emptyDir: {}
      - name: cache
        emptyDir: {}
      - name: run
        emptyDir: {}
```

**Deployment → ReplicaSet → Pod 关系**：

```
Deployment (web-deployment)
    │ spec.replicas: 3
    │ spec.template: {...}
    ▼
ReplicaSet (web-deployment-7c4b8d9f6)
    │ replicas: 3
    ▼
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Pod-xxx1 │  │ Pod-xxx2 │  │ Pod-xxx3 │
└──────────┘  └──────────┘  └──────────┘

更新镜像时：
Deployment 创建新 ReplicaSet
    │
    ▼
ReplicaSet (web-deployment-9a2e1c5d8)  ← 新
    │ replicas: 1 → 2 → 3
    ▼
┌──────────┐
│ Pod-yyy1 │
└──────────┘

同时旧 ReplicaSet 缩容：
ReplicaSet (web-deployment-7c4b8d9f6)  ← 旧
    │ replicas: 3 → 2 → 1 → 0
```

**滚动更新关键参数**：

| 参数 | 说明 | 默认值 | 安全建议 |
|------|------|--------|---------|
| `maxSurge` | 更新时最多可超出的 Pod 数 | 25% | 生产环境设为 1 或较小值 |
| `maxUnavailable` | 更新时最多不可用的 Pod 数 | 25% | 关键服务设为 0 |
| `minReadySeconds` | Pod 就绪后等待多久算可用 | 0 | 设为 10-30s |

```bash
# 查看滚动更新状态
kubectl rollout status deployment/web-deployment

# 查看 ReplicaSet 历史
kubectl get rs -l app=web

# 回滚到上一个版本
kubectl rollout undo deployment/web-deployment

# 回滚到特定版本
kubectl rollout undo deployment/web-deployment --to-revision=2

# 查看历史版本
kubectl rollout history deployment/web-deployment
```

### 2.3.2 StatefulSet：有状态应用管理

StatefulSet 用于管理需要以下特性的应用：
- 稳定的网络标识（Pod 名称不变）
- 稳定的持久化存储
- 有序部署和扩缩容

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  serviceName: "postgres-headless"
  replicas: 3
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16
        ports:
        - containerPort: 5432
        volumeMounts:
        - name: data
          mountPath: /var/lib/postgresql/data
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: fast-ssd
      resources:
        requests:
          storage: 10Gi
```

**StatefulSet 特性**：

```
Pod 名称: postgres-0, postgres-1, postgres-2（有序创建）
         │         │         │
         ▼         ▼         ▼
    DNS 名称: postgres-0.postgres-headless, postgres-1.postgres-headless, ...
         │         │         │
         ▼         ▼         ▼
    PVC 名称: data-postgres-0, data-postgres-1, data-postgres-2
         │         │         │
         ▼         ▼         ▼
    PV 绑定: 每个 Pod 有独立的持久卷
```

| 特性 | Deployment | StatefulSet |
|------|-----------|-------------|
| Pod 名称 | 随机（web-xxx） | 有序（postgres-0, postgres-1） |
| 创建顺序 | 同时创建 | 按序号顺序创建 |
| 删除顺序 | 同时删除 | 按序号逆序删除 |
| 网络标识 | 无固定 DNS | 固定 DNS（通过 Headless Service） |
| 存储 | 共享或临时 | 每个 Pod 独立 PVC |
| 扩缩容 | 无序 | 有序 |

### 2.3.3 DaemonSet：节点级守护

DaemonSet 确保每个（或某些）节点上运行一个 Pod：

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: node-exporter
spec:
  selector:
    matchLabels:
      app: node-exporter
  template:
    metadata:
      labels:
        app: node-exporter
    spec:
      hostNetwork: true           # 使用节点网络命名空间
      hostPID: true               # 访问节点 PID 命名空间
      containers:
      - name: node-exporter
        image: prom/node-exporter:v1.7.0
        ports:
        - containerPort: 9100
        volumeMounts:
        - name: proc
          mountPath: /host/proc
          readOnly: true
        - name: sys
          mountPath: /host/sys
          readOnly: true
      volumes:
      - name: proc
        hostPath:
          path: /proc
      - name: sys
        hostPath:
          path: /sys
```

**典型 DaemonSet 用途**：
- 日志收集器（fluent-bit、filebeat）
- 监控代理（node-exporter、Prometheus）
- 网络代理（CNI 插件、kube-proxy）
- 安全代理（Falco、Aqua Agent）

**安全注意事项**：DaemonSet 通常需要较高的权限（hostNetwork、hostPID、privileged），是重要的攻击面。

### 2.3.4 Job 与 CronJob

```yaml
# Job：一次性批处理任务
apiVersion: batch/v1
kind: Job
metadata:
  name: data-import
spec:
  backoffLimit: 4           # 失败重试次数
  activeDeadlineSeconds: 600 # 最大运行时间
  ttlSecondsAfterFinished: 86400 # 完成后保留时间
  template:
    spec:
      containers:
      - name: import
        image: importer:1.0
        command: ["python", "import.py"]
      restartPolicy: OnFailure  # Never / OnFailure
```

```yaml
# CronJob：定时任务
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup
spec:
  schedule: "0 2 * * *"     # 每天凌晨 2 点
  concurrencyPolicy: Forbid  # Allow / Forbid / Replace
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: backup-tool:1.0
            command: ["/backup.sh"]
          restartPolicy: OnFailure
```

| 参数 | 说明 |
|------|------|
| `concurrencyPolicy: Allow` | 允许并发执行 |
| `concurrencyPolicy: Forbid` | 如果上一个任务未完成，跳过本次 |
| `concurrencyPolicy: Replace` | 如果上一个任务未完成，终止旧任务，执行新任务 |

---

## 2.4 Service 与网络基础

### 2.4.1 Service 的本质

Service 为 Pod 提供稳定的网络访问入口，解决了 Pod IP 动态变化的问题。

**Service 的核心机制**：

```
Service (ClusterIP: 10.96.0.1)
    │ selector: app=web
    │
    ▼
┌─────────────────────────────────┐
│     EndpointSlice (或 Endpoints) │
│                                 │
│  - 10.244.1.5:8080  (Pod-1)     │
│  - 10.244.1.6:8080  (Pod-2)     │
│  - 10.244.2.3:8080  (Pod-3)     │
└─────────────────────────────────┘
         │
    kube-proxy (每个节点)
         │
    ┌────┴────┐
    ▼         ▼
iptables / IPVS 规则
    │
    ▼
负载均衡到后端 Pod
```

**Service 类型对比**：

| 类型 | ClusterIP | NodePort | LoadBalancer | ExternalName |
|------|-----------|----------|--------------|--------------|
| 暴露范围 | 集群内部 | 节点IP+端口 | 外部负载均衡 | DNS 别名 |
| 安全性 | 最高 | 需防火墙限制 | 配合安全组 | 较低 |
| 使用场景 | 内部服务 | 测试/开发 | 生产外部访问 | 外部服务代理 |

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web-service
spec:
  type: ClusterIP       # 默认，最安全
  selector:
    app: web
  ports:
  - protocol: TCP
    port: 80            # Service 端口
    targetPort: 8080    # Pod 端口
    name: http
```

**EndpointSlice**：

Kubernetes 1.21+ 默认使用 EndpointSlice 替代 Endpoints，解决了大规模集群下 Endpoints 对象过大的问题：

```bash
# 查看 EndpointSlice
kubectl get endpointslices

# 每个 EndpointSlice 最多包含 100 个端点（默认）
```

### 2.4.2 Headless Service

Headless Service 不为集群分配 ClusterIP，而是直接返回 Pod 的 IP 列表：

```yaml
apiVersion: v1
kind: Service
metadata:
  name: postgres-headless
spec:
  clusterIP: None       # 设置为 None，表示 Headless
  selector:
    app: postgres
  ports:
  - port: 5432
```

```bash
# DNS 解析返回所有 Pod IP
nslookup postgres-headless
# Server:  10.96.0.10
# Address: 10.96.0.10#53
#
# Name: postgres-headless.default.svc.cluster.local
# Address: 10.244.1.5
# Address: 10.244.1.6
# Address: 10.244.2.3
```

使用场景：
- StatefulSet 的 Pod 之间需要直接通信（如数据库集群的主从复制）
- 客户端需要知道所有后端 Pod 的 IP（如某些分布式系统）

### 2.4.3 CoreDNS：集群 DNS 解析

CoreDNS 是 Kubernetes 集群的 DNS 服务器：

```
Pod 发起 DNS 查询 (myservice.default.svc.cluster.local)
        │
        ▼
┌─────────────────┐
│   /etc/resolv.conf │
│   nameserver 10.96.0.10 │
└────────┬────────┘
         ▼
┌─────────────────┐
│   CoreDNS Pod   │  ← 运行在 kube-system
│   (ClusterIP: 10.96.0.10) │
│                 │
│   插件链：      │
│   1. kubernetes → 解析 svc/pod DNS
│   2. cache      → DNS 缓存
│   3. forward    → 转发到外部 DNS
│   4. errors/log → 错误处理
└────────┬────────┘
         ▼
    返回解析结果 (10.96.0.1)
```

**DNS 解析规则**：

| 记录类型 | 示例 | 解析结果 |
|---------|------|---------|
| A/AAAA | `myservice.default.svc.cluster.local` | Service ClusterIP |
| A/AAAA | `myservice`（同命名空间） | Service ClusterIP |
| A/AAAA | `10-244-1-5.default.pod.cluster.local` | Pod IP |
| SRV | `_http._tcp.myservice.default.svc.cluster.local` | 端口+IP |
| PTR | `1.0.96.10.in-addr.arpa` | 反向解析 |

**常见的 DNS 问题**：

```bash
# ndots 问题：Pod 的 /etc/resolv.conf
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
# 如果查询 "mysql"，会先尝试：
# 1. mysql.default.svc.cluster.local
# 2. mysql.svc.cluster.local
# 3. mysql.cluster.local
# 4. mysql
# 这可能导致外部域名解析变慢

# 解决方案：使用 FQDN（末尾加 .）
curl http://mysql.default.svc.cluster.local.
```

---

## 2.5 ConfigMap 与 Secret

### 2.5.1 ConfigMap：非敏感配置

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  # 键值对形式
  database.host: "mysql"
  database.port: "3306"
  
  # 多行配置
  app.properties: |
    server.port=8080
    log.level=info
    cache.enabled=true
```

**使用方式**：

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    image: myapp:1.0
    
    # 方式 1：环境变量注入
    env:
    - name: DB_HOST
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: database.host
    
    # 方式 2：整个 ConfigMap 作为环境变量
    envFrom:
    - configMapRef:
        name: app-config
    
    # 方式 3：挂载为文件
    volumeMounts:
    - name: config
      mountPath: /etc/config
  
  volumes:
  - name: config
    configMap:
      name: app-config
      # 可选：只挂载特定键
      items:
      - key: app.properties
        path: application.properties
```

**ConfigMap 更新机制**：
- 作为环境变量注入：ConfigMap 更新后，Pod 需要重建才能获取新值
- 作为 volume 挂载：kubelet 会定期（默认 60s）同步 ConfigMap 更新，Pod 内的文件会自动更新（但应用可能需要自行监听文件变化）

### 2.5.2 Secret：敏感信息

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:        # 自动 Base64 编码
  username: admin
  password: supersecret123
data:              # 手动 Base64 编码
  # echo -n 'admin' | base64
  # echo -n 'supersecret123' | base64
  # username: YWRtaW4=
  # password: c3VwZXJzZWNyZXQxMjM=
```

**Secret 的安全警告**：

1. **Secret 在 etcd 中默认明文存储**：
   ```bash
   # 任何人能访问 etcd 的人都能读取 Secret
   ETCDCTL_API=3 etcdctl get /registry/secrets/default/db-credentials
   ```

2. **Secret 在节点上以 tmpfs 挂载**：
   ```bash
   # 在节点上查看 Secret 文件
   kubectl get pod <pod> -o jsonpath='{.spec.volumes[*].secret.secretName}'
   # 文件实际存储在内存中（tmpfs），不会写入磁盘
   mount | grep secret
   # tmpfs on /var/lib/kubelet/pods/xxx/volumes/kubernetes.io~secret/db-credentials type tmpfs (rw,relatime)
   ```

3. **Secret 的 RBAC 风险**：
   ```bash
   # 默认情况下，同一命名空间中的任何用户都可以读取 Secret
   kubectl auth can-i get secrets -n default
   # yes
   ```

**Secret 安全最佳实践**：

```yaml
# 1. 启用 etcd 静态加密
# /etc/kubernetes/manifests/kube-apiserver.yaml
spec:
  containers:
  - command:
    - kube-apiserver
    - --encryption-provider-config=/etc/kubernetes/encryption-config.yaml

# encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    - configmaps
    providers:
    - aescbc:
        keys:
        - name: key1
          secret: <base64-encoded-32-byte-key>
    - identity: {}  # 回退：允许未加密读取

# 2. 使用外部 Secret 管理器
# External Secrets Operator
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: vault-backend
  target:
    name: db-credentials
  data:
  - secretKey: password
    remoteRef:
      key: secret/data/db
      property: password
```

### 2.5.3 不可变 ConfigMap 和 Secret

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  annotations:
    # 标记为不可变
    # 优点：减少 kubelet 轮询开销，提高性能
immutable: true
data:
  config.json: '{"key": "value"}'
```

标记为 `immutable: true` 后：
- kubelet 不需要 watch ConfigMap/Secret 的变化
- 如果尝试修改，API Server 会拒绝
- 在大规模集群中显著提升性能

---

## 2.6 SecurityContext：Pod 与容器安全

### 2.6.1 Pod 级别 SecurityContext

```yaml
apiVersion: v1
kind: Pod
spec:
  securityContext:
    # 运行身份
    runAsNonRoot: true        # 禁止以 root (UID 0) 运行
    runAsUser: 1000           # 指定运行用户 UID
    runAsGroup: 1000          # 指定运行组 GID
    fsGroup: 2000             # 卷挂载的组所有权
    
    # SELinux
    seLinuxOptions:
      level: "s0:c123,c456"
    
    # Seccomp
    seccompProfile:
      type: RuntimeDefault    # RuntimeDefault / Localhost / Unconfined
      # localhostProfile: my-profile.json
    
    # Sysctl
    sysctls:
    - name: net.ipv4.ip_unprivileged_port_start
      value: "80"
```

### 2.6.2 容器级别 SecurityContext

```yaml
spec:
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      # 禁止提权（禁止 setuid 等提权操作）
      allowPrivilegeEscalation: false
      
      # 只读根文件系统
      readOnlyRootFilesystem: true
      
      # 能力管理
      capabilities:
        drop:
        - ALL                    # 先丢弃所有能力
        add:
        - NET_BIND_SERVICE       # 只添加需要的
      
      # 以特权模式运行（极度危险，生产禁用）
      privileged: false
      
      # 只读 root 文件系统时，需要 tmpfs 挂载可写目录
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
```

**SecurityContext 字段速查表**：

| 字段 | 级别 | 说明 | 推荐值 |
|------|------|------|--------|
| `runAsNonRoot` | Pod | 禁止 root 运行 | `true` |
| `runAsUser` | Pod/Container | 指定 UID | `> 0`（如 1000） |
| `runAsGroup` | Pod/Container | 指定 GID | `> 0` |
| `fsGroup` | Pod | 卷挂载组 | 根据需求 |
| `allowPrivilegeEscalation` | Container | 禁止提权 | `false` |
| `readOnlyRootFilesystem` | Container | 只读根文件系统 | `true` |
| `capabilities.drop` | Container | 丢弃能力 | `["ALL"]` |
| `capabilities.add` | Container | 添加需要的能力 | 按需最小化 |
| `privileged` | Container | 特权模式 | `false`（绝不启用） |
| `seccompProfile.type` | Pod/Container | Seccomp 配置 | `RuntimeDefault` |
| `seLinuxOptions` | Pod/Container | SELinux 标签 | 按需配置 |

### 2.6.3 Pod Security Standards（PSS）

Kubernetes 1.23+ 引入 Pod Security Standards 替代已废弃的 PodSecurityPolicy（PSP）：

| 标准 | 说明 | 典型限制 |
|------|------|---------|
| **Privileged** | 无限制 | 允许特权容器、root 运行、所有能力 |
| **Baseline** | 最小限制 | 禁止特权容器、hostNetwork、hostPID |
| **Restricted** | 严格限制 | 非 root、只读根文件系统、无能力、Seccomp |

```yaml
# 通过 PodSecurity Admission 在命名空间级别实施
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

```bash
# 测试 Pod 是否符合标准
kubectl label namespace test pod-security.kubernetes.io/enforce=restricted
kubectl run test --image=nginx   # 会被拒绝，因为 nginx 默认以 root 运行
# Error from server (Forbidden): pods "test" is forbidden: 
# violates PodSecurity "restricted:latest": allowPrivilegeEscalation != false
```

---

## 2.7 kubectl 进阶用法

### 2.7.1 高级查询

```bash
# jsonpath 查询
kubectl get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\n"}{end}'

# 获取所有容器的镜像
kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .spec.containers[*]}{.image}{", "}{end}{"\n"}{end}'

# 自定义列输出
kubectl get pods -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName'

# 配合 jq 使用
kubectl get pods -o json | jq '.items[] | {name: .metadata.name, phase: .status.phase}'

# 查看 Pod 的所有事件
kubectl get events --field-selector involvedObject.name=<pod-name>
```

### 2.7.2 安全相关命令

```bash
# 检查权限
kubectl auth can-i list secrets
kubectl auth can-i create pods --as=system:serviceaccount:default:default
kubectl auth can-i '*' '*' --all-namespaces

# 查看 Pod 的 SecurityContext
kubectl get pod <pod> -o jsonpath='{.spec.securityContext}' | jq .
kubectl get pod <pod> -o jsonpath='{.spec.containers[*].securityContext}' | jq .

# 查看 ServiceAccount 的权限
kubectl get rolebindings,clusterrolebindings --all-namespaces -o json | \
  jq '.items[] | select(.subjects[]?.name=="<sa-name>") | .roleRef.name'

# 查看 Pod 使用的 ServiceAccount
kubectl get pod <pod> -o jsonpath='{.spec.serviceAccountName}'
```

### 2.7.3 调试与排障

```bash
# 创建临时调试 Pod
kubectl run debug --rm -it --image=nicolaka/netshoot -- bash

# 使用 Ephemeral Container 调试运行中的 Pod（v1.23+）
kubectl debug <pod> -it --image=nicolaka/netshoot --target=<container>

# 复制文件到/从 Pod
kubectl cp <pod>:/etc/nginx/nginx.conf ./nginx.conf
kubectl cp ./app.jar <pod>:/app/

# 端口转发（本地调试）
kubectl port-forward pod/<pod> 8080:80
kubectl port-forward svc/<service> 8080:80

# 查看资源使用
kubectl top pod
kubectl top node

# Dry Run（预览变更）
kubectl apply -f manifest.yaml --dry-run=server
kubectl apply -f manifest.yaml --dry-run=client
```

### 2.7.4 Server-Side Apply

Server-Side Apply（SSA）是 Kubernetes 1.18+ 引入的更安全的资源管理方式：

```bash
# 传统 apply 的问题：谁最后 apply 谁说了算
# SSA 解决：每个字段都有"所有者"，只有所有者能修改自己的字段

# 使用 SSA
kubectl apply -f manifest.yaml --server-side

# 强制应用（覆盖其他管理者的字段）
kubectl apply -f manifest.yaml --server-side --force-conflicts
```

---

## 2.8 生产案例：中型电商平台 K8s 基础架构

### 2.8.1 架构概览

某中型电商公司（日均 100 万 UV）的 Kubernetes 基础架构：

```
┌─────────────────────────────────────────────────────────────┐
│                     外部流量入口                              │
│              Cloudflare CDN → AWS ALB                        │
│                         │                                    │
│                         ▼                                    │
│              ┌─────────────────────┐                        │
│              │   Ingress Controller │  ← ingress-nginx       │
│              │   (3 replicas)       │                        │
│              └──────────┬──────────┘                        │
│                         │                                    │
└─────────────────────────┼────────────────────────────────────┘
                          │
┌─────────────────────────┼────────────────────────────────────┐
│                         ▼                                    │
│    ┌─────────────────────────────────────────────────────┐  │
│    │                 K8s Cluster                          │  │
│    │  (3 Master + 8 Worker Nodes)                         │  │
│    │                                                      │  │
│    │  Namespace 划分：                                     │  │
│    │  ├── production (核心交易服务)                        │  │
│    │  ├── staging    (预发布环境)                          │  │
│    │  ├── monitoring (Prometheus/Grafana)                 │  │
│    │  ├── logging    (Fluent-bit/Elasticsearch)           │  │
│    │  └── security   (Falco/OPA Gatekeeper)               │  │
│    │                                                      │  │
│    │  安全策略：                                          │  │
│    │  • production 命名空间: PSS Restricted                │  │
│    │  • NetworkPolicy: 只允许必要的服务间通信              │  │
│    │  • Secret: External Secrets + etcd 加密               │  │
│    │  • 镜像扫描: Trivy 集成 CI/CD                         │  │
│    └─────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### 2.8.2 安全实践

1. **Pod Security Standards**：`production` 命名空间强制 `restricted` 级别
2. **NetworkPolicy**：默认拒绝所有流量，显式允许必要通信
3. **Secret 管理**：External Secrets Operator 集成 AWS Secrets Manager
4. **镜像安全**：CI/CD 中使用 Trivy 扫描，禁止高漏洞镜像部署
5. **运行时安全**：Falco 监控异常行为，OPA Gatekeeper 执行策略

---

## 2.9 本章实验

### 实验 2.1：观察 Pod 生命周期（20 分钟）

```bash
# 步骤 1：创建一个简单的 Pod
kubectl run lifecycle-demo --image=nginx:alpine --restart=Never

# 步骤 2：观察状态变化
kubectl get pod lifecycle-demo -w

# 步骤 3：查看详细信息
kubectl describe pod lifecycle-demo

# 步骤 4：删除 Pod 并观察终止过程
kubectl delete pod lifecycle-demo --grace-period=30
# 在另一个终端观察：
kubectl get pod lifecycle-demo -o yaml | grep deletionTimestamp

# 思考问题：
# 1. 为什么先看到 ContainerCreating 状态？
# 2. 删除时 gracePeriod 是多少？如何修改？
# 3. 如果应用不处理 SIGTERM，会发生什么？
```

### 实验 2.2：Init Container 依赖等待（25 分钟）

```bash
# 步骤 1：创建一个有 Init Container 的 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: init-demo
spec:
  initContainers:
  - name: wait-for-service
    image: busybox:1.36
    command: ['sh', '-c', 'echo "Waiting for myservice..."; sleep 10; echo "Done waiting"']
  containers:
  - name: app
    image: nginx:alpine
    ports:
    - containerPort: 80
EOF

# 步骤 2：观察 Init Container 执行
kubectl get pod init-demo -w
kubectl logs init-demo -c wait-for-service
kubectl logs init-demo -c app

# 步骤 3：清理
kubectl delete pod init-demo
```

### 实验 2.3：探针行为观察（30 分钟）

```bash
# 步骤 1：创建一个带探针的 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: probe-demo
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh', '-c', 'echo "Starting..."; sleep 3600']
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      initialDelaySeconds: 5
      periodSeconds: 5
      failureThreshold: 3
EOF

# 步骤 2：观察 Pod 状态
kubectl get pod probe-demo -w
# 会看到 CrashLoopBackOff，因为 /tmp/healthy 不存在

# 步骤 3：查看事件
kubectl describe pod probe-demo

# 步骤 4：创建健康文件，观察恢复
kubectl exec probe-demo -- touch /tmp/healthy
kubectl get pod probe-demo

# 步骤 5：删除健康文件，观察重启
kubectl exec probe-demo -- rm /tmp/healthy
kubectl get pod probe-demo -w

# 清理
kubectl delete pod probe-demo
```

### 实验 2.4：Service 与 EndpointSlice（20 分钟）

```bash
# 步骤 1：创建 Deployment 和 Service
kubectl create deployment web --image=nginx:alpine --replicas=3
kubectl expose deployment web --port=80 --target-port=80

# 步骤 2：查看 EndpointSlice
kubectl get endpointslices
kubectl get endpointslices -l kubernetes.io/service-name=web -o yaml

# 步骤 3：缩容观察 EndpointSlice 变化
kubectl scale deployment web --replicas=1
kubectl get endpointslices -l kubernetes.io/service-name=web

# 步骤 4：测试 Service 连通性
kubectl run test --rm -it --image=busybox:1.36 -- wget -O- http://web

# 清理
kubectl delete deployment web
kubectl delete service web
```

### 实验 2.5：SecurityContext 验证（25 分钟）

```bash
# 步骤 1：创建安全 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: security-demo
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    runAsGroup: 1000
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh', '-c', 'id; sleep 3600']
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
EOF

# 步骤 2：验证运行身份
kubectl logs security-demo
# uid=1000 gid=1000

# 步骤 3：验证无法提权
kubectl exec security-demo -- su
# su: must be suid to work properly

# 步骤 4：验证只读文件系统
kubectl exec security-demo -- touch /test
# touch: /test: Read-only file system

# 步骤 5：验证无特权能力
kubectl exec security-demo -- capsh --print
# Current: =

# 清理
kubectl delete pod security-demo
```

### 实验 2.6：Pod Security Standards 实践（20 分钟）

```bash
# 步骤 1：创建受限命名空间
kubectl create namespace pss-test
kubectl label namespace pss-test pod-security.kubernetes.io/enforce=restricted

# 步骤 2：尝试创建不安全的 Pod（应该失败）
kubectl run bad-pod --image=nginx -n pss-test
# Error: violates PodSecurity "restricted:latest"

# 步骤 3：创建符合 restricted 的 Pod
cat <<EOF | kubectl apply -n pss-test -f -
apiVersion: v1
kind: Pod
metadata:
  name: good-pod
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop:
        - ALL
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
EOF

# 步骤 4：验证
kubectl get pods -n pss-test

# 清理
kubectl delete namespace pss-test
```

### 实验 2.7：Secret 安全分析（20 分钟）

```bash
# 步骤 1：创建 Secret
kubectl create secret generic my-secret --from-literal=password=secret123

# 步骤 2：验证 Secret 以 Base64 存储
kubectl get secret my-secret -o jsonpath='{.data.password}' | base64 -d
# secret123

# 步骤 3：挂载到 Pod 中观察
kubectl run secret-test --image=busybox:1.36 --overrides='
{
  "spec": {
    "containers": [{
      "name": "secret-test",
      "image": "busybox:1.36",
      "command": ["sh", "-c", "cat /secret/password; sleep 3600"],
      "volumeMounts": [{"name": "secret-vol", "mountPath": "/secret"}]
    }],
    "volumes": [{
      "name": "secret-vol",
      "secret": {"secretName": "my-secret"}
    }]
  }
}'

kubectl logs secret-test
# secret123

# 步骤 4：在节点上查看 Secret 文件（需要节点权限）
# kubectl get pod secret-test -o jsonpath='{.spec.nodeName}'
# ssh <node>
# find /var/lib/kubelet/pods -name "password" 2>/dev/null
# cat <path>
# 可以看到明文密码

# 清理
kubectl delete pod secret-test
kubectl delete secret my-secret
```

---

## 2.10 本章练习题

### 选择题

1. **kube-scheduler 的调度流程中，哪个阶段负责硬性条件过滤？**
   - A. Scoring
   - B. Filtering
   - C. Binding
   - D. Preemption

2. **以下哪个探针用于检查应用是否准备好接收流量？**
   - A. Liveness Probe
   - B. Readiness Probe
   - C. Startup Probe
   - D. Health Probe

3. **Pod 终止时，kubelet 首先发送的信号是？**
   - A. SIGKILL
   - B. SIGTERM
   - C. SIGINT
   - D. SIGHUP

4. **以下哪种 Service 类型最适合生产环境的内部服务？**
   - A. NodePort
   - B. LoadBalancer
   - C. ClusterIP
   - D. ExternalName

5. **Pod Security Standards 的哪个级别最严格？**
   - A. Privileged
   - B. Baseline
   - C. Restricted
   - D. Standard

### 简答题

1. 解释 Kubernetes 的声明式 API 和控制器模式如何协同工作，为什么这种设计使得 Kubernetes 具有自愈能力？

2. Deployment、StatefulSet 和 DaemonSet 分别适用于什么场景？从网络标识、存储、扩缩容角度对比它们。

3. 如果一个 Pod 的 Liveness Probe 和 Readiness Probe 配置为相同的端点，可能会产生什么问题？为什么建议分开配置？

### 实践题

1. 创建一个 StatefulSet 部署 3 个 Redis 实例，使用 Headless Service 使它们可以互相发现。验证每个 Pod 有独立的网络标识和存储。

2. 编写一个 Pod YAML，满足以下所有安全要求：
   - 非 root 用户运行
   - 只读根文件系统
   - 丢弃所有 capabilities
   - 禁止特权提升
   - 使用 RuntimeDefault seccomp
   - 资源限制（CPU 100m-200m，内存 128Mi-256Mi）

---

## 2.11 本章小结

| 概念 | 作用 | 安全关注点 |
|------|------|-----------|
| **Pod** | 最小调度单元，容器共享网络/IPC/存储 | SecurityContext、非 root、只读文件系统 |
| **Init Container** | Pod 启动前执行初始化任务 | 与主容器共享部分安全上下文 |
| **Probe** | 健康检查（Liveness/Readiness/Startup） | 合理配置避免过度敏感或过于宽松 |
| **Deployment** | 无状态应用，支持滚动更新 | 资源限制、镜像版本控制、回滚策略 |
| **StatefulSet** | 有状态应用，稳定网络标识和存储 | PVC 权限、有序扩缩容的安全影响 |
| **DaemonSet** | 每个节点运行一个 Pod | 通常需要 hostNetwork/hostPID，高风险 |
| **Service** | 为 Pod 提供稳定访问入口 | 类型选择、避免过度暴露 |
| **ConfigMap** | 非敏感配置 | 不可变标记、不存放密码 |
| **Secret** | 敏感信息 | etcd 加密、RBAC 最小化、外部管理器 |
| **Namespace** | 逻辑隔离 | PSS、ResourceQuota、NetworkPolicy |
| **SecurityContext** | Pod/容器安全配置 | runAsNonRoot、capabilities、seccomp |

**关键安全原则**：
1. **最小权限**：容器以非 root 运行，丢弃不必要的能力
2. **不可变基础设施**：只读根文件系统，不运行时修改
3. **纵深防御**：Namespace + RBAC + NetworkPolicy + PSS 多层防护
4. **Secret 加密**：启用 etcd 静态加密，考虑外部 Secret 管理器
5. **资源限制**：始终设置 resources.limits，防止资源耗尽攻击

**下一章预告**：我们将学习 Kubernetes 集群的部署、管理和故障排查，深入理解 kubeadm、etcd 管理和证书体系，为 CKA 认证做准备。
