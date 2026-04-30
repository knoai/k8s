# Kubernetes 组件从基础到专家

> 一份系统化的 K8s 组件学习资料，覆盖架构设计、核心组件、网络存储、安全可观测性及高级扩展机制。

## 学习路径图

```
Level 1: 基础篇
├── 01-架构概览
├── 02-核心概念
└── 03-最小可运行集群

Level 2: 控制平面
├── 04-API Server
├── 05-etcd
├── 06-Scheduler
├── 07-Controller Manager
└── 08-Cloud Controller Manager

Level 3: 工作节点
├── 09-kubelet
├── 10-kube-proxy
└── 11-Container Runtime (CRI)

Level 4: 网络与存储
├── 12-Service 与网络
├── 13-CNI 插件
├── 14-DNS
├── 15-Ingress
├── 16-存储系统 (PV/PVC/CSI)
└── 17-ConfigMap / Secret

Level 5: 安全
├── 18-RBAC
├── 19-Pod 安全策略
├── 20-NetworkPolicy
└── 21-Admission Controller

Level 6: 可观测性
├── 22-Metrics 与监控
├── 23-日志系统
└── 24-Tracing

Level 7: 专家级
├── 25-API Machinery
├── 26-调度框架 (Scheduling Framework)
├── 27-CRD 与 Operator
├── 28-准入控制器 Webhook
├── 29-动态准入控制
└── 30-自定义控制器开发
```

---

## 目录

| 章节 | 文件 | 级别 |
|------|------|------|
| 01. 架构概览 | [01-architecture.md](01-architecture.md) | L1 |
| 02. 核心对象与概念 | [02-core-concepts.md](02-core-concepts.md) | L1 |
| 03. 控制平面组件 | [03-control-plane.md](03-control-plane.md) | L2 |
| 04. 工作节点组件 | [04-worker-node.md](04-worker-node.md) | L3 |
| 05. 网络体系 | [05-networking.md](05-networking.md) | L4 |
| 06. 存储体系 | [06-storage.md](06-storage.md) | L4 |
| 07. 安全体系 | [07-security.md](07-security.md) | L5 |
| 08. 可观测性 | [08-observability.md](08-observability.md) | L6 |
| 09. 专家进阶 | [09-expert.md](09-expert.md) | L7 |
| 10. 面试常见问题 | [10-interview.md](10-interview.md) | - |
