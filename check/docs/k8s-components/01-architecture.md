# 01. Kubernetes 架构概览

## 什么是 Kubernetes

Kubernetes（简称 K8s）是一个开源的容器编排平台，用于自动化部署、扩展和管理容器化应用程序。

**核心能力**：
- **服务发现与负载均衡**：Service 自动分配 IP 和 DNS，流量自动分发
- **存储编排**：自动挂载本地存储、云存储、网络存储
- **自动部署与回滚**：Deployment 支持滚动更新和回滚
- **自动扩缩容**：HPA 根据 CPU/内存指标自动调整副本数
- **自愈**：Pod 失败自动重启、替换、重新调度
- **密钥与配置管理**：ConfigMap/Secret 管理配置和敏感数据

---

## 整体架构图

```
┌─────────────────────────────────────────────────────────────┐
│                      Control Plane                          │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │ kube-apiserver│  │   etcd       │  │kube-scheduler│       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│  ┌──────────────┐  ┌─────────────────────────────────┐      │
│  │kube-controller│  │  cloud-controller-manager       │      │
│  │   -manager    │  │  (云厂商场景)                   │      │
│  └──────────────┘  └─────────────────────────────────┘      │
└──────────────────────────┬──────────────────────────────────┘
                           │ HTTPS (6443)
┌──────────────────────────┼──────────────────────────────────┐
│                      Worker Nodes                           │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │   kubelet    │  │ kube-proxy   │  │   CRI        │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐       │
│  │    Pod A     │  │    Pod B     │  │    Pod C     │       │
│  └──────────────┘  └──────────────┘  └──────────────┘       │
└─────────────────────────────────────────────────────────────┘
```

**控制平面（Control Plane）**：
- 负责集群的决策（调度）和检测/响应集群事件（Pod 故障、资源不足等）
- 通常部署在独立的节点上（master 节点），生产环境建议多节点高可用

**工作节点（Worker Node）**：
- 运行用户应用程序（Pod）
- 每个节点运行 kubelet、kube-proxy 和容器运行时
- 节点数量可动态增减

---

## 组件通信关系

```
                    kubectl / REST / WebSocket
                           │
                           ▼
┌─────────────────────────────────────────┐
│         kube-apiserver (6443)            │
│  ┌──────────┐  ┌──────────┐  ┌────────┐ │
│  │ 认证      │  │ 鉴权      │  │ 准入控制│ │
│  │(AuthN)    │  │(AuthZ/RBAC)│  │(Admission)│
│  └──────────┘  └──────────┘  └────────┘ │
└──────┬──────────────────────────────────┘
       │
       ├────────── Watch ──────────► 各 Controller
       ├────────── Watch ──────────► kube-scheduler
       ├────────── Watch ──────────► kubelet (各节点)
       │
       ▼
   ┌─────────┐
   │  etcd   │  ← 集群状态的唯一数据源
   └─────────┘
```

**通信特点**：
1. **所有组件只与 apiserver 通信**，组件之间不直接通信
2. etcd 只与 apiserver 通信，其他组件不直接访问 etcd
3. kubelet 向 apiserver 注册节点并汇报状态
4. 各 Controller 通过 Watch 机制监听 apiserver 的事件流

---

## 最小可运行集群

 kubeadm 部署的最小集群：

```
┌─────────────┐
│   Master    │  ← 控制平面 + 工作节点（可调度 Pod）
│  (1 node)   │
└─────────────┘
```

生产环境推荐架构：

```
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Master 1 │  │ Master 2 │  │ Master 3 │  ← 控制平面高可用
└──────────┘  └──────────┘  └──────────┘
┌──────────┐  ┌──────────┐  ┌──────────┐
│ Worker 1 │  │ Worker 2 │  │ Worker N │  ← 运行业务 Pod
└──────────┘  └──────────┘  └──────────┘
```

---

## 数据流总览

### 创建一个 Pod 的完整流程

```
1. 用户: kubectl apply -f pod.yaml
         │
2. 认证: apiserver 验证用户身份
         │
3. 鉴权: apiserver 检查用户是否有 create pods 权限
         │
4. 准入: Admission Controller 修改/验证请求
         │
5. 写入: apiserver 将 Pod 对象写入 etcd
         │
6. 通知: apiserver 发送 Add 事件给所有 Watch 客户端
         ├──► kube-scheduler 发现 "新 Pod 待调度"
         │
7. 调度: scheduler 选择合适节点，更新 Pod 的 nodeName
         │
8. 通知: apiserver 发送 Update 事件
         ├──► 目标节点的 kubelet 发现 "我的 Pod"
         │
9. 创建: kubelet 调用 CRI 创建容器
         │
10.上报: kubelet 持续上报 Pod 状态给 apiserver
         │
11.写入: apiserver 更新 Pod status 到 etcd
```

---

## 核心设计哲学

### 1. 声明式 API

**命令式**：告诉系统"如何做"
```bash
# 命令式（传统方式）
ssh node1 "docker run nginx"
ssh node2 "docker run nginx"
# 如果 nginx 挂了，需要手动重启
```

**声明式**：告诉系统"期望状态是什么"
```yaml
# 声明式（K8s 方式）
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: nginx
        image: nginx:1.21
```
用户声明"我想要 2 个 nginx Pod"，K8s 负责持续保证实际状态 = 期望状态。

### 2. 控制器模式（Control Loop）

```
         ┌──────────────┐
         │   期望状态    │
         │  (etcd)      │
         └──────┬───────┘
                │
                ▼
         ┌──────────────┐
         │   控制器      │
         │  (Controller)│
         └──────┬───────┘
                │
         ┌──────┴───────┐
         ▼              ▼
    ┌─────────┐   ┌──────────┐
    │ 观察差异 │   │ 执行动作  │
    │ diff    │   │ reconcile│
    └────┬────┘   └────┬─────┘
         │             │
         └──────┬──────┘
                ▼
         ┌──────────────┐
         │   实际状态    │
         └──────────────┘
```

**所有 K8s 组件本质上都是控制器**：
- kube-scheduler：确保 Pod 被调度到合适节点
- kubelet：确保节点上的容器按期望运行
- Deployment Controller：确保 ReplicaSet 副本数正确
- ReplicaSet Controller：确保 Pod 数量正确

### 3. 最终一致性

K8s 不保证操作是瞬时完成的，但保证**最终**实际状态会收敛到期望状态。

例如：你修改 Deployment 的 replicas 从 2 到 5：
1. apiserver 接收请求，写入 etcd（立即完成）
2. Deployment Controller 观察到变化，创建 3 个新的 ReplicaSet（几秒内）
3. ReplicaSet Controller 创建 3 个新的 Pod（几秒内）
4. Scheduler 为 3 个新 Pod 分配节点（几秒内）
5. Kubelet 创建 3 个容器（取决于镜像大小，可能几秒到几分钟）
6. 最终：5 个 Pod 全部 Running

---

## 推荐阅读顺序

```
L1: 01-architecture.md（本文） → 02-core-concepts.md
L2: 03-control-plane.md（深入 apiserver/etcd/scheduler/controller）
L3: 04-worker-node.md（kubelet/kube-proxy/CRI）
L4: 05-networking.md → 06-storage.md
L5: 07-security.md
L6: 08-observability.md
L7: 09-expert.md（高级扩展机制）
```
