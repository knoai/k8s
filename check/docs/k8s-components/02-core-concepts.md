# 02. 核心对象与概念

## Pod — K8s 的最小调度单元

### 为什么需要 Pod

**问题**：为什么 K8s 不直接调度容器？

**答案**：实际应用往往由多个紧密协作的容器组成：
- 主应用容器 + 日志收集 sidecar
- 主应用容器 + 监控 agent sidecar
- 主应用容器 + 配置重载 sidecar

这些容器需要：
1. **共享网络命名空间**（同一 IP、同一端口空间）
2. **共享存储卷**（同一文件系统）
3. **紧密的生命周期绑定**（同生共死）

Pod 就是满足这些需求的抽象。

### Pod 结构

```
┌─────────────────────────────────────┐
│              Pod                    │
│  IP: 10.244.1.5                     │
│  ┌───────────────────────────────┐  │
│  │  Network Namespace            │  │
│  │  ┌─────────┐  ┌───────────┐  │  │
│  │  │  App    │  │  Sidecar  │  │  │
│  │  │Container│  │ Container │  │  │
│  │  └────┬────┘  └─────┬─────┘  │  │
│  │       │             │        │  │
│  │       └──────┬──────┘        │  │
│  │              ▼               │  │
│  │       Shared Volume          │  │
│  └──────────────────────────────┘  │
└─────────────────────────────────────┘
```

**Pod 内的容器**：
- `pause` 容器（infra）：创建并持有网络命名空间，是 Pod 的"根"
- 业务容器：用户的应用容器
- init 容器：在业务容器启动前运行，用于初始化

### Pod 生命周期

```
Pending → Running → Succeeded/Failed → Unknown
   │          │
   ▼          ▼
 ContainerCreating  CrashLoopBackOff
 ImagePullBackOff   OOMKilled
 Evicted            Terminating
```

**状态说明**：

| 状态 | 含义 |
|------|------|
| `Pending` | 已创建但尚未调度或容器尚未创建 |
| `Running` | 已绑定节点，至少一个容器在运行 |
| `Succeeded` | 所有容器成功退出（exit 0） |
| `Failed` | 所有容器退出，至少一个非 0 |
| `Unknown` | 无法获取 Pod 状态（通常节点失联） |
| `CrashLoopBackOff` | 容器反复崩溃重启 |
| `ImagePullBackOff` | 拉取镜像失败 |
| `OOMKilled` | 容器内存超限被系统杀死 |
| `Evicted` | 节点资源不足，Pod 被驱逐 |
| `Terminating` | Pod 正在删除中 |

### Pod 状态与容器状态

```yaml
status:
  phase: Running                    # Pod 级别状态
  conditions:                       # Pod 条件
    - type: PodScheduled
      status: "True"
    - type: Initialized
      status: "True"
    - type: ContainersReady
      status: "True"
    - type: Ready
      status: "True"
  containerStatuses:
    - name: nginx
      state:
        running:
          startedAt: "2024-01-15T10:00:00Z"
      ready: true
      restartCount: 0
```

**Pod Conditions**：
- `PodScheduled`：Pod 已被分配到节点
- `Initialized`：所有 init 容器已完成
- `ContainersReady`：所有容器 ready
- `Ready`：Pod 可以接收流量（ readiness probe 通过）

---

## 工作负载资源（Workload）

### Deployment — 无状态应用

```
用户 → Deployment → ReplicaSet → Pod
```

**核心能力**：
- **滚动更新**：逐步替换旧 Pod，保证服务不中断
- **回滚**：可以回退到之前的版本
- **扩缩容**：修改 replicas 数量

**更新策略**：
```yaml
spec:
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 25%        # 更新时最多多出 25% 的 Pod
      maxUnavailable: 25%  # 更新时最多不可用 25% 的 Pod
```

**滚动更新过程**：
```
t=0:  [v1][v1][v1]           # 3 个旧版本 Pod
t=1:  [v1][v1][v1][v2]       # 创建 1 个新版本（maxSurge=1）
t=2:  [v1][v1][v2]           # 删除 1 个旧版本
t=3:  [v1][v2][v2]           # 继续替换
t=4:  [v2][v2][v2]           # 全部替换完成
```

### StatefulSet — 有状态应用

**适用场景**：需要稳定身份、稳定存储的应用
- 数据库（MySQL、PostgreSQL、MongoDB）
- 消息队列（Kafka、RabbitMQ）
- 分布式协调（ZooKeeper、etcd）

**与 Deployment 的区别**：

| 特性 | Deployment | StatefulSet |
|------|-----------|-------------|
| Pod 命名 | 随机后缀 | 有序编号（-0, -1, -2） |
| 网络身份 | 不固定 | 稳定（DNS: pod-name.service-name） |
| 存储 | 共享 PVC 模板 | 每个 Pod 独立 PVC |
| 更新 | 并行/滚动 | 按序（先删后建，默认） |
| 缩容 | 随机删除 | 从后往前删除（先删 -N） |

```
web-0   →  PVC: data-web-0
web-1   →  PVC: data-web-1
web-2   →  PVC: data-web-2
```

### DaemonSet — 每个节点一个 Pod

**适用场景**：
- 日志收集（Fluentd、Filebeat）
- 监控代理（Prometheus Node Exporter、Datadog Agent）
- 网络代理（Calico Node、Weave Net）
- 安全代理

**调度特点**：
- 默认在所有节点（包括 master）运行
- 可通过 `nodeSelector` / `tolerations` 控制
- 新节点加入时自动创建 Pod

### Job / CronJob — 批处理任务

**Job**：执行一次的任务
```yaml
apiVersion: batch/v1
kind: Job
spec:
  completions: 5       # 总共完成 5 次
  parallelism: 2       # 同时运行 2 个
  backoffLimit: 4      # 失败重试 4 次
```

**CronJob**：定时执行的任务
```yaml
apiVersion: batch/v1
kind: CronJob
spec:
  schedule: "0 2 * * *"  # 每天凌晨 2 点
  jobTemplate:
    spec:
      template:
        spec:
          activeDeadlineSeconds: 3600  # 1 小时超时
```

---

## Service — 服务发现与负载均衡

### 为什么需要 Service

Pod 的 IP 是**临时**的：
- Pod 重启后 IP 会变化
- Deployment 滚动更新时 Pod 不断被替换
- 如何稳定访问一组 Pod？

**Service 提供稳定的访问入口**（虚拟 IP + DNS）。

### Service 类型

| 类型 | 说明 | 使用场景 |
|------|------|---------|
| `ClusterIP` | 集群内部虚拟 IP | 集群内服务互访 |
| `NodePort` | 节点端口（30000-32767） | 外部临时访问 |
| `LoadBalancer` | 云厂商负载均衡器 | 生产环境外部暴露 |
| `ExternalName` | DNS CNAME 记录 | 映射外部服务 |

### ClusterIP 原理

```
Pod A (10.244.1.2)          Pod B (10.244.1.3)
    │                            │
    └──────► my-svc:80 ◄────────┘
              │
              ▼
        ┌────────────┐
        │ ClusterIP  │  ← 虚拟 IP，存在于 iptables/IPVS 规则中
        │ 10.96.0.1  │     不绑定任何网络接口
        └─────┬──────┘
              │
        ┌─────┴─────┐
        ▼           ▼
   10.244.1.2   10.244.1.3
```

**流量分发方式**：
- `iptables` 模式（默认）：随机分发
- `IPVS` 模式（推荐）：支持更多负载均衡算法（rr, lc, dh, sh, sed, nq）

---

## Namespace — 资源隔离

**作用**：逻辑上隔离不同团队/项目/环境的资源

```
Namespace: dev
├── Deployment: web
├── Service: web-svc
└── ConfigMap: web-config

Namespace: prod
├── Deployment: web
├── Service: web-svc
└── ConfigMap: web-config
```

**特点**：
- 同一 Namespace 内资源名不能重复
- 不同 Namespace 资源名可重复
- Service DNS：`service-name.namespace.svc.cluster.local`
- 大多数资源属于某个 Namespace
- **不属于 Namespace 的资源**：Node、Namespace 本身、ClusterRole、PersistentVolume 等

---

## Label 与 Selector

### Label — 资源标签

```yaml
metadata:
  labels:
    app: nginx
    tier: frontend
    env: production
    version: v1.2.3
```

### Selector — 标签选择器

```yaml
# 等值选择
selector:
  matchLabels:
    app: nginx
    env: production

# 集合选择
selector:
  matchExpressions:
    - key: tier
      operator: In
      values: [frontend, backend]
    - key: env
      operator: NotIn
      values: [dev]
```

**使用 Selector 的资源**：
- Service → 选择 Endpoint（目标 Pod）
- Deployment/StatefulSet/DaemonSet → 选择管理的 Pod
- NetworkPolicy → 选择应用策略的 Pod

---

## 探针（Probe）

### 三种探针

| 探针 | 作用 | 失败后果 |
|------|------|---------|
| `livenessProbe` | 容器是否存活 | 重启容器 |
| `readinessProbe` | 容器是否就绪接收流量 | 从 Service Endpoint 移除 |
| `startupProbe` | 容器是否启动完成 | 禁用 liveness/readiness |

### 探针方式

```yaml
spec:
  containers:
  - name: app
    livenessProbe:
      httpGet:              # HTTP GET 探测
        path: /healthz
        port: 8080
      initialDelaySeconds: 10
      periodSeconds: 5
      timeoutSeconds: 3
      failureThreshold: 3   # 连续 3 次失败才判定失败
    readinessProbe:
      tcpSocket:            # TCP 端口探测
        port: 8080
    startupProbe:
      exec:                 # 执行命令探测
        command:
        - cat
        - /tmp/healthy
```

**探针时机**：
```
容器启动
  │
  ├──► startupProbe 开始探测
  │      │
  │      ├── 成功 ──► 启用 liveness + readiness
  │      │
  │      └── 失败 ──► 超过 failureThreshold 则重启容器
  │
  └──► 如果无 startupProbe，直接启用 liveness + readiness
```

---

## 资源管理

### Requests vs Limits

```yaml
resources:
  requests:
    cpu: "100m"      # 100 millicores = 0.1 CPU
    memory: "128Mi"  # 128 Mebibytes
  limits:
    cpu: "500m"
    memory: "256Mi"
```

| 概念 | 说明 |
|------|------|
| `requests` | 调度时使用的资源需求（保证能获得的资源） |
| `limits` | 运行时可使用的最大资源 |

**CPU**：
- requests：保证的 CPU 份额（cfs_quota）
- limits：CPU 使用上限（超出会被节流，不会杀死）
- 单位：`1` = 1 个 CPU 核心，`100m` = 0.1 核心

**内存**：
- requests：调度时参考（节点可用内存必须 ≥ requests 之和）
- limits：内存使用上限（超出会被 OOMKilled）

### QoS 等级

K8s 根据 requests/limits 设置自动分配 QoS：

| QoS | 条件 | 驱逐优先级 |
|-----|------|-----------|
| `Guaranteed` | requests == limits，且只设置了 limits | 最低（最后被驱逐） |
| `Burstable` | 不满足 Guaranteed 和 BestEffort | 中等 |
| `BestEffort` | 未设置 requests 和 limits | 最高（最先被驱逐） |

```yaml
# Guaranteed
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "100m"
    memory: "128Mi"

# Burstable
resources:
  requests:
    cpu: "100m"
    memory: "128Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

# BestEffort
resources: {}  # 或完全不写
```
