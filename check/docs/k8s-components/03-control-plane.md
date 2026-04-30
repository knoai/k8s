# 03. 控制平面组件详解

## kube-apiserver — 集群的"前门"

### 职责

kube-apiserver 是 Kubernetes 控制平面的**前端**，暴露 K8s API。

**所有操作都经过 apiserver**：
- kubectl 命令 → 调用 apiserver REST API
- 其他控制平面组件 → 只与 apiserver 通信
- 工作节点组件 → 向 apiserver 注册和汇报

### 架构图

```
                    客户端请求
                         │
         ┌───────────────┼───────────────┐
         │               │               │
         ▼               ▼               ▼
   ┌──────────┐   ┌──────────┐   ┌──────────┐
   │  kubectl │   │   UI     │   │  CI/CD   │
   └────┬─────┘   └────┬─────┘   └────┬─────┘
        │              │              │
        └──────────────┼──────────────┘
                       ▼
              ┌─────────────────┐
              │   kube-apiserver │
              │     :6443        │
              ├─────────────────┤
              │ 1. 认证 (TLS)   │
              │ 2. 鉴权 (RBAC)  │
              │ 3. 准入控制      │
              │ 4. 请求处理      │
              └────────┬────────┘
                       │
                       ▼
              ┌─────────────────┐
              │      etcd       │
              └─────────────────┘
```

### 请求处理流程

```
1. 建立 TLS 连接
   └── 验证客户端证书（X.509）

2. 认证 (Authentication)
   ├── TLS 客户端证书认证
   ├── Bearer Token 认证（ServiceAccount Token）
   ├── Webhook Token 认证
   └── 匿名认证（可禁用）

3. 鉴权 (Authorization)
   ├── RBAC（基于角色）← 最常用
   ├── ABAC（基于属性）
   ├── Node（节点授权）
   └── Webhook（外部鉴权）

4. 准入控制 (Admission Control)
   ├── Mutating Webhook（修改请求）
   ├── Validating Webhook（验证请求）
   └── 内置准入插件

5. 请求处理
   └── 读写 etcd
```

### 认证方式

```
客户端 ──► apiserver
    │
    ├── 证书认证: client.crt + client.key
    ├── Token 认证: Authorization: Bearer <token>
    ├── ServiceAccount: /var/run/secrets/kubernetes.io/serviceaccount/token
    └── Webhook: 转发到外部认证服务（如 OpenID Connect）
```

### 高可用部署

```
         ┌──────────┐
         │ 负载均衡器 │
         │  (VIP)   │
         └────┬─────┘
              │
    ┌─────────┼─────────┐
    ▼         ▼         ▼
┌───────┐ ┌───────┐ ┌───────┐
│apisvr1│ │apisvr2│ │apisvr3│
└───┬───┘ └───┬───┘ └───┬───┘
    │         │         │
    └─────────┼─────────┘
              ▼
         ┌─────────┐
         │  etcd   │
         │ (3节点) │
         └─────────┘
```

**要点**：
- apiserver 是**无状态**的，可以多实例部署
- 所有实例共享同一个 etcd
- 前端使用负载均衡器（LB）分发流量
- 常用方案：HAProxy、Nginx、云厂商 LB

---

## etcd — 集群的"大脑"

### 职责

etcd 是 Kubernetes 的**分布式键值存储**，保存集群的所有配置数据和状态。

**存储的数据**：
- 所有 K8s 资源对象（Pod、Deployment、Service、ConfigMap...）
- 节点注册信息
- 事件（Event）
- Secret（加密存储）

### 数据结构

```
etcd 键空间（按资源类型组织）
│
├── /registry/namespaces/default
├── /registry/namespaces/kube-system
│
├── /registry/pods/default/my-pod
├── /registry/pods/default/my-pod2
│
├── /registry/deployments/default/my-deploy
│
├── /registry/services/default/my-svc
│
├── /registry/configmaps/default/my-cm
│
├── /registry/secrets/default/my-secret
│
├── /registry/nodes/node1
├── /registry/nodes/node2
│
└── /registry/events/...
```

### 架构与一致性

```
┌─────────────────────────────────────┐
│           etcd Cluster               │
│                                      │
│   ┌─────┐     ┌─────┐     ┌─────┐  │
│   │Node1│◄───►│Node2│◄───►│Node3│  │
│   │Leader│     │Follower│  │Follower│
│   └─────┘     └─────┘     └─────┘  │
│       │                              │
│       │ Raft 协议                    │
│       │                              │
│   所有写操作由 Leader 处理            │
│   读操作可由任意节点处理              │
└─────────────────────────────────────┘
```

**Raft 协议核心**：
- **Leader 选举**：节点之间通过心跳检测，选出 Leader
- **日志复制**：Leader 接收写请求，复制到 Follower，多数确认后提交
- **数据一致性**：保证所有节点最终一致（强一致性）

**集群成员数**：
- 推荐 3、5、7 个节点（奇数）
- 3 节点：可容忍 1 个故障
- 5 节点：可容忍 2 个故障
- 7 节点：可容忍 3 个故障

### etcd 性能影响

apiserver 的**所有操作**都要读写 etcd：

| 操作 | etcd 操作 |
|------|----------|
| kubectl get pods | etcd 读 |
| kubectl create deployment | etcd 写 |
| kubectl apply | etcd 读 + 写 |
| Watch 事件流 | etcd Watch |
| 控制器 List | etcd 范围读 |

**etcd 性能瓶颈的表现**：
- apiserver 响应慢
- kubectl 命令卡顿
- 集群事件延迟

**优化建议**：
- 使用 SSD 磁盘（etcd 对 IOPS 敏感）
- 控制事件保留时间（`--event-ttl`）
- 限制 List 操作（使用分页）
- 分离 etcd 与 apiserver 磁盘

---

## kube-scheduler — 调度器

### 职责

kube-scheduler 负责将**未分配节点**的 Pod 调度到合适的节点上运行。

### 调度流程

```
1. 监听 apiserver
   └── 发现新创建且未分配 nodeName 的 Pod

2. 预选（Predicates）
   └── 过滤掉不符合条件的节点

3. 优选（Priorities）
   └── 给剩余节点打分，选出最高分

4. 绑定（Bind）
   └── 通过 apiserver 将 Pod 绑定到选定节点
```

### 预选（Predicates）— 过滤

```
所有节点
    │
    ├── 节点名匹配？（nodeName）
    ├── 节点选择器匹配？（nodeSelector）
    ├── 资源充足？（requests ≤ 节点可用资源）
    ├── 端口不冲突？（hostPort）
    ├── 污点容忍？（taint/toleration）
    ├── 卷可挂载？（节点有需要的 PV）
    ├── 亲和性满足？（nodeAffinity）
    └── Pod 反亲和性满足？（podAntiAffinity）
    │
    ▼
候选节点列表（可能为空 → Pod Pending）
```

### 优选（Priorities）— 打分

```
候选节点
    │
    ├── LeastRequested：节点资源使用率越低分越高
    ├── BalancedResourceAllocation：CPU/内存使用率越均衡分越高
    ├── NodeAffinity：满足 nodeAffinity 偏好的分高
    ├── TaintToleration：容忍较少污点的节点分高
    ├── ImageLocality：节点已有镜像的分高
    └── InterPodAffinity：满足 Pod 亲和性的分高
    │
    ▼
得分最高的节点
```

### 调度绑定

```yaml
# 调度器通过 apiserver 更新 Pod 的 spec.nodeName
# 这就是"绑定"操作
spec:
  nodeName: worker-node-1   # ← 调度器设置这个字段
```

### 调度示例

```
Pod 要求：cpu=500m, memory=1Gi

节点 A：cpu 可用 200m, memory 2Gi   → 预选失败（CPU 不足）
节点 B：cpu 可用 1核, memory 512Mi  → 预选失败（内存不足）
节点 C：cpu 可用 2核, memory 4Gi   → 预选通过
节点 D：cpu 可用 3核, memory 8Gi   → 预选通过

优选打分：
  节点 C：使用率 25%  → 80分
  节点 D：使用率 14%  → 90分  ← 选中
```

---

## kube-controller-manager — 控制器管理器

### 职责

kube-controller-manager 运行**多个控制器**，每个控制器负责一种资源的"期望状态 vs 实际状态" reconcilation。

**核心设计**：
```
while true:
    actual_state = 获取当前状态
    desired_state = 获取期望状态
    if actual_state != desired_state:
        执行动作使 actual_state → desired_state
    sleep(interval)
```

### 内置控制器列表

| 控制器 | 作用 |
|--------|------|
| **Node Controller** | 监控节点健康，节点失联时标记为 NotReady，驱逐 Pod |
| **Replication Controller** | 维护 Pod 副本数（旧版，已被 ReplicaSet 替代） |
| **Deployment Controller** | 管理 ReplicaSet 的创建和更新，实现滚动更新 |
| **ReplicaSet Controller** | 维护 Pod 数量与 replicas 一致 |
| **StatefulSet Controller** | 管理有状态应用，维护有序身份和存储 |
| **DaemonSet Controller** | 确保每个（符合条件的）节点运行一个 Pod |
| **Job Controller** | 管理 Job 执行，跟踪完成次数 |
| **CronJob Controller** | 按 Cron 表达式触发 Job |
| **Endpoint Controller** | 维护 Service 和 Pod 的对应关系（Endpoints/EndpointSlice） |
| **Service Account Controller** | 为 Namespace 创建 default ServiceAccount |
| **Token Controller** | 为 ServiceAccount 创建 Token Secret |
| **Namespace Controller** | 清理被删除 Namespace 下的所有资源 |
| **PV/PVC Controller** | 管理 PV 和 PVC 的绑定/回收 |
| **HPA Controller** | 根据指标自动扩缩 Deployment |
| **VPA Controller** | 根据实际使用自动调整 requests/limits |
| **Disruption Budget Controller** | 保证升级时最小可用 Pod 数 |

### Deployment Controller 详解

```
用户创建 Deployment (replicas=3, image=nginx:v1)
         │
         ▼
┌──────────────────┐
│ Deployment       │  控制器发现：需要 3 个 v1 版本的 Pod
│ Controller       │  → 创建 ReplicaSet (nginx-v1, replicas=3)
└──────────────────┘
         │
         ▼
┌──────────────────┐
│ ReplicaSet       │  控制器发现：需要 3 个 Pod
│ Controller       │  → 创建 3 个 Pod
└──────────────────┘
         │
         ▼
┌──────────────────┐
│ Scheduler        │  调度 3 个 Pod 到节点
└──────────────────┘
         │
         ▼
┌──────────────────┐
│ kubelet          │  在节点上创建容器
└──────────────────┘
```

**滚动更新过程**：
```
用户更新 image: nginx:v1 → nginx:v2
         │
         ▼
Deployment Controller:
  1. 创建新的 ReplicaSet (nginx-v2, replicas=0)
  2. 逐步增加新 RS 的 replicas，减少旧 RS 的 replicas
  3. 按照 maxSurge / maxUnavailable 控制替换速度
  4. 新 RS replicas=3, 旧 RS replicas=0
  5. 旧 RS 被保留（用于回滚）
```

---

## cloud-controller-manager — 云控制器

### 职责

cloud-controller-manager 是 Kubernetes 1.6 引入的组件，用于将**云厂商特定逻辑**与核心 K8s 控制平面解耦。

**云厂商逻辑**：
- 创建云负载均衡器（LoadBalancer Service）
- 创建云路由表
- 管理云存储卷
- 节点云信息同步（云实例 ID、区域等）

### 架构

```
# 无云厂商（自建集群）
Controller Manager 包含所有控制器

# 有云厂商
Controller Manager 去掉云相关控制器
Cloud Controller Manager 运行云相关控制器
```

### 云控制器列表

| 控制器 | 作用 |
|--------|------|
| **Node Controller** | 从云平台获取节点信息，同步云实例元数据 |
| **Route Controller** | 在云平台上创建路由 |
| **Service Controller** | 创建云负载均衡器（ELB/SLB/CLB） |

**示例（阿里云）**：
```
用户创建 type=LoadBalancer 的 Service
         │
         ▼
Cloud Controller Manager
         │
         ▼
调用阿里云 OpenAPI
         │
         ▼
创建阿里云 SLB
         │
         ▼
SLB 后端绑定 NodePort
```

---

## 控制平面组件总结

| 组件 | 核心职责 | 是否有状态 | 是否可多实例 |
|------|---------|-----------|-------------|
| kube-apiserver | API 网关，处理所有请求 | 无 | 是 |
| etcd | 数据存储 | 有 | 是（3/5/7） |
| kube-scheduler | Pod 调度 | 无 | 是（Leader 选举） |
| kube-controller-manager | 运行各类控制器 | 无 | 是（Leader 选举） |
| cloud-controller-manager | 云厂商逻辑 | 无 | 是（Leader 选举） |

**Leader 选举**：
- scheduler 和 controller-manager 多实例部署时，只有一个处于 Active 状态
- 通过 etcd 的租约机制实现 Leader 选举
- Active 实例故障时，其他实例自动接管

```
apiserver × 3 ──► LB ──► 客户端
      │
      ├── etcd × 3
      │
      ├── scheduler (Active) × 1
      │   └── scheduler (Standby) × N
      │
      └── controller-manager (Active) × 1
          └── controller-manager (Standby) × N
```
