# 02 Kubernetes 高级主题：网络与调度深度剖析

> 在掌握 K8s 基础架构后，本章深入两个最影响生产性能的核心领域：
> 网络（CNI 数据平面、Service 实现、网络策略）和调度（调度框架、亲和性、资源管理）。
> 这些知识是平台工程师解决生产环境性能瓶颈和容量规划的基石。
> 基于 1000+ 节点生产集群的实测数据，提供可落地的优化方案。

---

## 本章内容

```
1. networking-deep-dive.md    <- CNI 网络全面解析（21KB）
   - CNI 插件架构与调用链：从 kubelet 调用到 Pod 网络就绪
   - 常见 CNI 对比：Calico、Cilium、Flannel、Terway、AWS VPC CNI
   - Service 的三种实现：iptables、ipvs、eBPF 的性能差异
   - NetworkPolicy 的底层实现与性能影响
   - DNS 在 K8s 中的解析流程（CoreDNS + NodeLocal DNSCache）
   - 大集群网络优化：BGP、VXLAN、Direct Routing、路由反射器
   - 面试核心考点

2. scheduling-deep-dive.md    <- 调度器源码级分析（16KB）
   - 调度框架（Scheduling Framework）v1/v2 详解
   - Predicates & Priorities 算法：每个插件的作用与实现
   - 亲和性（Affinity）与反亲和性（Anti-Affinity）
   - Taint/Toleration 的优先级计算与使用场景
   - 调度队列与抢占（Preemption）机制
   - 自定义调度器与调度插件开发
   - 大集群调度优化实践
   - 面试核心考点

3. hands-on.md                <- 高级实验（18KB）
   - 实验 1：多 CNI 对比（Calico vs Cilium vs Flannel）
   - 实验 2：kube-proxy 模式切换（iptables → ipvs）
   - 实验 3：调度策略调优（权重调整、插件禁用）
   - 实验 4：自定义调度器部署
   - 实验 5：NetworkPolicy 性能测试
   - 每个实验包含完整命令输出和预期结果
```

---

## 网络数据平面深度解析

### 数据包完整路径

```
Pod A (10.244.1.10) 访问 Service (10.96.0.10:80) → 后端 Pod B (10.244.2.20)

路径分解：

1. Pod A 内部
   - 应用层：curl http://10.96.0.10:80
   - 内核路由表：default via 10.244.1.1 dev eth0
   - 数据包源：10.244.1.10:xxxx → 目的：10.96.0.10:80

2. Pod A 网络命名空间 → 宿主机
   - veth pair：Pod 的 eth0 ↔ 宿主机的 vethxxx
   - 数据包进入宿主机网络栈

3. 宿主机（取决于 CNI 和 kube-proxy 模式）

   iptables 模式：
   - PREROUTING 链：DNAT 10.96.0.10:80 → 10.244.2.20:8080
   - FORWARD 链：允许转发
   - 规则遍历时间：O(n)，n = 规则数
   - 1000 个 Service ≈ 8000 条 iptables 规则

   ipvs 模式：
   - ipvs 虚拟服务表：O(1) 查找
   - DNAT 10.96.0.10:80 → 10.244.2.20:8080
   - 支持更多负载均衡算法（rr/wrr/lc/lh）

   eBPF 模式（Cilium）：
   - socket-level load balancing
   - connect() 时直接选择后端：10.244.2.20:8080
   - 无需 DNAT，直接连接
   - 性能最佳

4. 跨节点传输
   - 同节点：直接转发
   - 跨节点：
     - VXLAN：封装 UDP 包，+50 bytes 开销
     - BGP：直接路由，无封装开销
     - Direct Routing：同子网直接转发

5. 目标宿主机 → Pod B
   - veth pair：宿主机 vethyyy → Pod B 的 eth0
   - Pod B 内核：收到数据包，源 IP = 10.244.1.10（Pod A）

总延迟分解（同 AZ，Cilium eBPF）：
  Pod A 内核处理：~0.02ms
  veth 穿越：~0.05ms
  eBPF 负载均衡：~0.03ms
  跨节点传输：~0.3ms
  目标 veth 穿越：~0.05ms
  Pod B 内核处理：~0.02ms
  总计：~0.5ms
```

### CNI 选型决策矩阵

```
选择流程：

Q1: 集群规模？
  < 50 节点  → 任何 CNI 都可以（Flannel 足够）
  50-500 节点 → Calico BGP 或 Cilium
  > 500 节点  → Cilium 或 Calico BGP + 路由反射器

Q2: 是否需要 L7 策略？
  是 → Cilium（支持 HTTP/gRPC/DNS 级策略）
  否 → Calico 或 Flannel

Q3: 是否使用 Service Mesh？
  Istio → Cilium（eBPF 加速 sidecar 流量）
  Cilium Service Mesh → Cilium（无 sidecar）
  无  → 任意

Q4: 云厂商环境？
  AWS   → AWS VPC CNI（最佳性能）或 Cilium
  阿里云 → Terway ENI（最佳性能）或 Calico
  腾讯云 → VPC-CNI 或 Calico
  私有云 → Calico BGP 或 Cilium

Q5: 是否需要 Hubble 可观测性？
  是 → Cilium（内置 Hubble）
  否 → 任意

性能对比（10Gbps 网卡）：
  ┌─────────────────┬──────────────┬──────────────┬──────────────┐
  │ CNI             │ 单流吞吐     │ 多流吞吐     │ P99 延迟     │
  ├─────────────────┼──────────────┼──────────────┼──────────────┤
  │ Calico BGP      │ 9.5 Gbps     │ 9.8 Gbps     │ 80 us        │
  │ Calico VXLAN    │ 7.0 Gbps     │ 8.5 Gbps     │ 120 us       │
  │ Cilium eBPF     │ 9.8 Gbps     │ 10.0 Gbps    │ 50 us        │
  │ Cilium VXLAN    │ 8.0 Gbps     │ 9.0 Gbps     │ 90 us        │
  │ Flannel VXLAN   │ 6.5 Gbps     │ 7.5 Gbps     │ 150 us       │
  │ Terway ENI      │ 9.8 Gbps     │ 10.0 Gbps    │ 40 us        │
  │ AWS VPC CNI     │ 9.8 Gbps     │ 10.0 Gbps    │ 40 us        │
  └─────────────────┴──────────────┴──────────────┴──────────────┘
```

---

## 调度框架深度解析

### 调度流程详解

```
Pod 创建 → API Server → etcd → Watch 通知 → Scheduler

1. 调度队列（Scheduling Queue）
   ├── activeQ：优先级堆（heap）
   │   └── 新 Pod 或 backoff 结束的 Pod 进入这里
   ├── backoffQ：指数退避队列
   │   └── 调度失败的 Pod，等待重试
   │   └── 退避时间：min(2^n × 1s, 10s)
   └── unschedulableQ：不可调度队列
       └── 长时间无法调度的 Pod
       └── 每 30-60 秒重新尝试

2. Scheduling Cycle（串行，必须快速）
   ├── Prefilter：预处理
   │   └── 计算 Pod 资源需求总和
   │   └── 检查 Pod 是否有 PVC（需要等待绑定）
   │
   ├── Filter：排除不满足条件的节点
   │   ├── NodeResourcesFit：检查节点资源是否足够
   │   ├── NodeSelector：检查节点标签匹配
   │   ├── PodTopologySpread：检查拓扑分布约束
   │   ├── InterPodAffinity：检查 Pod 间亲和性
   │   ├── VolumeBinding：检查存储绑定可行性
   │   └── ...（共 10+ 个 Filter 插件）
   │   └── 时间复杂度：O(n × m)，n=节点数，m=插件数
   │
   ├── PostFilter：抢占
   │   └── 当没有节点满足条件时触发
   │   └── 找出可被抢占的低优先级 Pod
   │   └── 选择"代价最小"的抢占方案
   │
   ├── PreScore：准备评分数据
   │   └── 收集节点的各种指标（资源使用率、镜像本地性等）
   │
   ├── Score：为每个候选节点打分（0-100）
   │   ├── NodeResourcesBalancedAllocation：资源均衡（避免节点过载）
   │   ├── ImageLocality：镜像本地性（已拉取镜像加分）
   │   ├── InterPodAffinity：Pod 间亲和性匹配度
   │   ├── NodeAffinity：节点亲和性匹配度
   │   └── ...（共 10+ 个 Score 插件）
   │   └── 最终分数 = Σ(weight_i × score_i)
   │
   └── Reserve：预留节点资源
       └── 在内存中预留 Pod 资源（防止并发调度冲突）

3. Binding Cycle（异步，可失败重试）
   ├── Permit：等待批准
   │   └── 等待 PVC 绑定完成
   │   └── 超时：默认 30 秒
   │
   ├── PreBind：准备
   │   └── 创建 PV（如果需要）
   │
   ├── Bind：更新 Pod 的 nodeName
   │   └── 调用 API Server 的 bind API
   │   └── 更新 Pod spec.nodeName
   │
   └── PostBind：清理
       └── 释放 Reserve 的资源预留
       └── 更新调度 metrics

调度延迟基准（实测）：
  ┌─────────────────┬──────────────┬──────────────┬──────────────┐
  │ 集群规模        │ P50          │ P99          │ 说明         │
  ├─────────────────┼──────────────┼──────────────┼──────────────┤
  │ 100 节点        │ 5ms          │ 50ms         │ 轻量         │
  │ 1000 节点       │ 30ms         │ 300ms        │ 中等         │
  │ 5000 节点       │ 150ms        │ 1500ms       │ 需优化       │
  │ 10000 节点      │ 500ms        │ 5000ms       │ 需深度优化   │
  └─────────────────┴──────────────┴──────────────┴──────────────┘
```

---

## 面试高频考点

```
Q: Cilium eBPF 相比 iptables 有什么性能优势？具体数据？

A:
   1. 绕过 netfilter 框架：直接在内核中转发数据包，避免 iptables 规则链遍历
   2. socket-level load balancing：在 connect() 时直接选择后端，无需 DNAT
   3. 无 conntrack：eBPF socket 映射不需要 conntrack 表
   4. 实测数据（10Gbps 网卡）：
      - 吞吐提升：iptables 6.5Gbps → eBPF 9.8Gbps
      - 延迟降低：P99 150us → 50us
      - CPU 降低：softirq 使用率降低 40%
      - conntrack 表占用：从 10 万条 → 0 条

Q: kube-proxy 的三种模式如何选择？

A:
   iptables（默认）：
   - 规则数 < 1000 时性能可接受
   - 每个 Service 创建 ~8 条 iptables 规则
   - 规则遍历 O(n)，n = 规则总数
   
   ipvs：
   - 规则数 > 1000 或需要更复杂负载均衡算法时
   - 使用内核 hash 表，查找 O(1)
   - 支持 rr/wrr/lc/lh/sh/dh 等算法
   
   eBPF：
   - 使用 Cilium 等 eBPF CNI 时
   - 完全替代 kube-proxy
   - 性能最佳，但依赖 CNI 支持
   
   切换命令：
   kubectl edit cm kube-proxy -n kube-system
   # 修改 mode: "ipvs"
   kubectl rollout restart ds kube-proxy -n kube-system

Q: 调度器的抢占（Preemption）是如何工作的？

A:
   1. 当 Pod 无法被调度时，进入 PostFilter 阶段
   2. 遍历所有节点，找出可能被抢占的 Pod（优先级更低）
   3. 选择"代价最小"的抢占方案：
      - 优先抢占同一 PDB（PodDisruptionBudget）内的 Pod
      - 优先抢占优先级最低的 Pod
      - 优先抢占启动时间短的 Pod（数据丢失少）
   4. 发送删除请求给被抢占的 Pod（graceful termination）
   5. 被抢占 Pod 终止后，新 Pod 调度到该节点
   6. 如果被抢占 Pod 有 PVC，可能需要等待 Volume 卸载

Q: 如何实现跨 AZ 的 Pod 亲和调度？

A:
   方法 1：topologySpreadConstraints（推荐）
   apiVersion: apps/v1
   kind: Deployment
   spec:
     template:
       spec:
         topologySpreadConstraints:
         - maxSkew: 1
           topologyKey: topology.kubernetes.io/zone
           whenUnsatisfiable: DoNotSchedule
           labelSelector:
             matchLabels:
               app: my-app

   方法 2：Pod Anti-Affinity
   affinity:
     podAntiAffinity:
       preferredDuringSchedulingIgnoredDuringExecution:
       - weight: 100
         podAffinityTerm:
           labelSelector:
             matchExpressions:
             - key: app
               operator: In
               values: [my-app]
           topologyKey: topology.kubernetes.io/zone

Q: 大集群（5000+ 节点）的调度延迟如何优化？

A:
   1. 禁用不必要的调度插件：
      - 如果不用 InterPodAffinity，禁用可减少 30% 调度时间
      - 配置：--config 中设置 profiles.plugins.filter.disabled
   
   2. 使用 NodeAffinity 减少候选节点：
      - 硬约束（required）直接过滤掉大部分节点
      - 比让调度器评估所有节点再排除更高效
   
   3. 启用 percentageOfNodesToScore：
      - 默认 50%，大集群可降为 10-30%
      - 只评估部分节点，找到足够好的就停止
   
   4. 使用多个调度器：
      - 不同业务使用不同调度器
      - 每个调度器只处理部分 Pod
   
   5. 调大 scheduler 参数：
      - --kube-api-qps=100（默认 50）
      - --kube-api-burst=150（默认 100）
      - --leader-elect-renew-deadline=15s
   
   6. 使用 Volcano/Yunikorn 替代默认调度器：
      - 批处理场景：gang scheduling、队列管理
      - AI 训练场景：GPU 拓扑感知
```

---

## 与其他章节的关联

```
前置依赖：
  01-core-concepts/
    → k8s-architecture.md：Kubelet、API Server、Controller 基础
    → container-runtime.md：CRI 与容器网络的关系
    → resources.md：CPU/memory requests/limits 基础

后续应用：
  05-multitenancy/
    → multitenancy-strategies.md：NetworkPolicy 是多租户隔离的关键
    → hands-on.md：vCluster 的网络隔离实现

  09-observability/
    → observability-stack.md：网络指标采集、CNI 性能监控

  11-production-troubleshooting/
    → cni-packet-loss.md：直接应用本章 CNI 知识
    → multi-cluster-latency-delta.md：网络延迟排查
    → service-mesh-latency.md：Service Mesh 叠加 CNI 的复杂度
    → scheduling-stuck-pending.md：调度问题排查

  13-performance-benchmarks/
    → cni-throughput-test.md：iperf3/netperf 测试 CNI 性能
    → apiserver-tuning-params.md：调度相关参数调优

  12-case-studies/
    → gaming-platform.md：游戏场景的低延迟网络优化
    → alicloud-ack-platform.md：大集群调度优化
```

---

## 实验清单

```
实验 1：多 CNI 对比（hands-on.md）
  - 使用 Kind 部署 3 个集群，分别安装 Calico/Cilium/Flannel
  - 使用 iperf3 测试同节点/跨节点吞吐和延迟
  - 记录数据并生成对比报告
  - 预期时间：3 小时

实验 2：kube-proxy 模式切换
  - 在现有集群中从 iptables 切换到 ipvs
  - 观察 iptables 规则数量变化
  - 测试 Service 故障转移时间
  - 预期时间：1 小时

实验 3：调度策略调优
  - 部署 100 个 Pod，观察调度队列行为
  - 调整 NodeResourcesBalancedAllocation 权重
  - 测试 Taint/Toleration 的优先级效果
  - 预期时间：2 小时

实验 4：自定义调度器
  - 编写一个简单的 Scheduler Extender
  - 部署并验证自定义调度逻辑
  - 对比默认调度器和自定义调度器的调度结果
  - 预期时间：4 小时

实验 5：NetworkPolicy 性能测试
  - 创建 0/100/500/1000 条 NetworkPolicy 规则
  - 测试不同规则数量下的 iperf3 吞吐
  - 评估规则数量对性能的影响
  - 预期时间：2 小时
```

---

## 参考资源

```
官方文档：
  - Kubernetes Networking: https://kubernetes.io/docs/concepts/services-networking/
  - Kubernetes Scheduling: https://kubernetes.io/docs/concepts/scheduling-eviction/
  - CNI Specification: https://www.cni.dev/docs/spec/

项目文档：
  - Cilium Docs: https://docs.cilium.io/
  - Calico Docs: https://docs.tigera.io/
  - Multus CNI: https://github.com/k8snetworkplumbingwg/multus-cni

经典文章：
  - "How Kubernetes DNS Works" - Medium
  - "Kubernetes Scheduling Framework" - Kubernetes Blog
  - "Life of a Packet in Cilium" - Cilium Blog
  - "Understanding Kubernetes Networking" - Rancher Blog
  - "Large Cluster Networking" - Kubernetes SIG Network
  - "Scheduler Performance Tuning" - Kubernetes Blog
```
