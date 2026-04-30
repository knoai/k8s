# Cilium 深度解析

> Cilium 是基于 eBPF 的 K8s CNI 和安全观测平台。它不仅是一个网络插件，更是云原生网络、安全、可观测性的统一解决方案。

---

## 1. Cilium 与 eBPF 的关系

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                     Cilium = eBPF + K8s 网络控制                             │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  eBPF 是 Linux 内核技术:                                                      │
│  • 在内核中运行沙盒程序                                                       │
│  • 无需修改内核源码或加载模块                                                  │
│  • JIT 编译为机器码，接近原生性能                                               │
│                                                                             │
│  Cilium 是 eBPF 的上层应用:                                                   │
│  • 将网络策略编译为 eBPF 程序                                                 │
│  • 将负载均衡逻辑编译为 eBPF 程序                                              │
│  • 将可观测性探针编译为 eBPF 程序                                              │
│  • 提供用户态控制平面（Agent、Operator）                                       │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    Cilium 控制平面                                   │   │
│  │                                                                      │   │
│  │  Cilium Agent (DaemonSet)                                            │   │
│  │    - 监听 K8s API (Pod/Service/Endpoint/NetworkPolicy/CNP)           │   │
│  │    - 编译 eBPF 程序并加载到内核                                       │   │
│  │    - 管理 BPF map (ipcache、lb、policy、ct)                          │   │
│  │    - 暴露 Prometheus 指标                                            │   │
│  │                                                                      │   │
│  │  Cilium Operator (Deployment)                                        │   │
│  │    - IPAM (分配 Pod IP)                                              │   │
│  │    - 管理 CiliumNode、CiliumEndpoint CRD                             │   │
│  │    - 处理节点间身份同步                                               │   │
│  │                                                                      │   │
│  │  Cilium CLI                                                          │   │
│  │    - 调试命令 (cilium endpoint, bpf, policy, status)                 │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              │                                              │
│         ┌────────────────────┼────────────────────┐                         │
│         │ BPF map / perf ring│                    │                         │
│         └────────────────────┼────────────────────┘                         │
│                              │                                              │
│  ┌───────────────────────────▼───────────────────────────────────────────┐ │
│  │                         eBPF 数据平面                                  │ │
│  │                                                                        │ │
│  │  XDP ──► TC Ingress ──► Socket Layer ──► TC Egress                     │ │
│  │                                                                        │ │
│  │  cilium_ipcache     cilium_lb4_services    cilium_policy               │ │
│  │  cilium_ct4_global  cilium_lb4_backends    cilium_metrics              │ │
│  │                                                                        │ │
│  └────────────────────────────────────────────────────────────────────────┘ │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Cilium 数据平面深度

### 2.1 数据包处理全路径

```
入站数据包 (Pod 到 Pod):

Pod A (10.244.1.5) ──► Pod B (10.244.2.3)

1. Pod A 发送数据包
   ↓
2. Pod A 的 eth0 (veth) ──► 宿主机 veth pair
   ↓
3. TC Egress eBPF 程序 (Pod A 的宿主机)
   • 查找目的 IP 在 ipcache 中的身份
   • 检查出站策略 (cilium_policy)
   • 如果是跨节点，封装或路由
   ↓
4. 物理网络传输
   ↓
5. 目的节点收到数据包
   ↓
6. TC Ingress eBPF 程序 (Pod B 的宿主机)
   • XDP (可选): 快速路径处理
   • 查找源 IP 身份
   • 检查入站策略
   • 查找 lb 服务 (如果是 Service IP)
   • 重定向到目标 Pod 的 veth
   ↓
7. Pod B 的 veth pair ──► Pod B 的 eth0
   ↓
8. Pod B 收到数据包

关键: 整个过程绕过了 iptables、netfilter、conntrack！
```

### 2.2 Identity-based Security（身份安全模型）

```
传统 IP-based 策略的问题:
  • Pod IP 是动态的，重启后变化
  • 策略基于 IP，需要频繁更新
  • 规模受限（IP 规则数量 ∝ Pod 数量）

Cilium Identity-based 策略:

Pod 创建 ──► Cilium 分配 Identity ──► 策略基于 Identity

Identity = f(标签集合)

示例:
  Pod A 标签: app=frontend, team=web, env=prod
  → Identity ID: 12345

  Pod B 标签: app=backend, team=api, env=prod
  → Identity ID: 12346

策略:
  Identity 12345 可以访问 Identity 12346 的 8080 端口

优势:
  • Pod 重启 IP 变化，但标签不变 → Identity 不变 → 策略不变
  • 策略数量 ∝ Identity 种类数，不是 Pod 数量
  • 支持通配符和复杂标签选择器

查看 Identity:
  cilium identity list
  cilium identity get 12345

ipcache 结构:
  10.244.1.5 → Identity 12345
  10.244.2.3 → Identity 12346
  0.0.0.0/0  → Identity 2 (world)
```

### 2.3 Kube-proxy Replacement

```
Cilium 可以完全替代 kube-proxy:

传统 kube-proxy (iptables):
  Service IP ──► iptables DNAT ──► Pod IP
  • 规则数量 O(n)
  • 依赖 conntrack
  • 不支持会话保持的高级算法

Cilium eBPF 负载均衡:
  Service IP ──► eBPF map 查找 ──► Pod IP
  • O(1) 查找
  • 无需 conntrack
  • 支持多种算法

启用方式:
helm install cilium cilium/cilium --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=auto \
  --set k8sServicePort=6443

负载均衡算法:
  • Random (默认)
  • Maglev (一致性哈希，适合有状态服务)

验证:
  cilium bpf lb list
  cilium bpf ct list global

优势:
  • 连接数无限制（不受 conntrack 表限制）
  • 支持 DSR (Direct Server Return)
  • 连接优雅终止
  • 健康检查集成
```

---

## 3. Cilium 网络策略

### 3.1 L3/L4 策略

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
    # 允许 frontend Pod 访问
    - fromEndpoints:
        - matchLabels:
            app: frontend
            k8s:io.kubernetes.pod.namespace: production
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    # 允许 monitoring namespace 的 prometheus 访问 metrics
    - fromEndpoints:
        - matchLabels:
            app: prometheus
            k8s:io.kubernetes.pod.namespace: monitoring
      toPorts:
        - ports:
            - port: "9090"
              protocol: TCP
  egress:
    # 允许访问数据库
    - toEndpoints:
        - matchLabels:
            app: database
            k8s:io.kubernetes.pod.namespace: production
      toPorts:
        - ports:
            - port: "3306"
              protocol: TCP
    # 允许访问 DNS
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
          rules:
            dns:
              - matchPattern: "*.cluster.local"
```

### 3.2 L7 策略（HTTP/gRPC/Kafka）

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-l7-policy
spec:
  endpointSelector:
    matchLabels:
      app: api-gateway
  ingress:
    - fromEntities:
        - cluster
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/v1/users/.*"
                headers:
                  - name: X-Api-Key
                    presence: true
              - method: POST
                path: "/api/v1/users"
              - method: GET
                path: "/health"
              - method: GET
                path: "/metrics"
    - fromEndpoints:
        - matchLabels:
            app: admin-panel
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
          rules:
            http:
              - method: "*"
                path: "/admin/.*"

# gRPC 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: grpc-policy
spec:
  endpointSelector:
    matchLabels:
      app: grpc-service
  ingress:
    - toPorts:
        - ports:
            - port: "50051"
              protocol: TCP
          rules:
            http:
              - method: POST
                path: "/helloworld.Greeter/SayHello"
```

### 3.3 Cluster-wide 策略

```yaml
# 集群级策略（所有 namespace 生效）
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: default-deny
spec:
  endpointSelector: {}  # 所有 Pod
  ingressDeny:
    - {}  # 默认拒绝所有入站
  egressDeny:
    - {}  # 默认拒绝所有出站
---
apiVersion: cilium.io/v2
kind: CiliumClusterwideNetworkPolicy
metadata:
  name: allow-dns
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s-app: kube-dns
            k8s:io.kubernetes.pod.namespace: kube-system
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
```

---

## 4. Cilium 可观测性

### 4.1 Hubble 架构

```
Hubble 组件:

┌─────────────────────────────────────────────────────────────┐
│  Hubble Server (每个节点)                                     │
│    - 嵌入在 Cilium Agent 中                                  │
│    - 通过 eBPF 采集流数据                                    │
│    - 提供 gRPC API                                           │
│                                                             │
│  Hubble Relay (集群级)                                       │
│    - 聚合所有节点的 Hubble Server                             │
│    - 提供统一查询接口                                        │
│                                                             │
│  Hubble UI (可选)                                            │
│    - 可视化服务拓扑                                          │
│    - 实时流查看                                              │
│                                                             │
│  Prometheus Metrics                                          │
│    - hubble_flows_processed_total                            │
│    - hubble_drop_total                                       │
│    - hubble_http_requests_total                              │
│    - hubble_dns_queries_total                                │
│    - hubble_tcp_flags_total                                  │
└─────────────────────────────────────────────────────────────┘

流数据 (Flow):
  {
    "time": "2024-01-15T10:30:00Z",
    "source": {"identity": 12345, "namespace": "prod", "pod_name": "frontend-xxx"},
    "destination": {"identity": 12346, "namespace": "prod", "pod_name": "backend-xxx"},
    "l4": {"tcp": {"source_port": 12345, "destination_port": 8080}},
    "verdict": "FORWARDED",
    "type": "L7",
    "l7": {"http": {"method": "GET", "url": "/api/users", "protocol": "HTTP/1.1"}}
  }
```

### 4.2 Hubble 命令行实战

```bash
# 启用 Hubble
helm upgrade cilium cilium/cilium --namespace kube-system \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}"

# 实时观察流量
hubble observe --server localhost:4245 --follow

# 观察特定 namespace
hubble observe --namespace production --follow

# 观察特定 Pod
hubble observe --pod frontend-xxx --namespace production

# 观察丢包
hubble observe --type drop
# 输出包含丢包原因: policy denied, TTL exceeded 等

# 观察 HTTP 流量
hubble observe --protocol http --namespace production

# 观察 DNS
hubble observe --protocol dns --namespace production

# 导出流数据到文件（审计/分析）
hubble observe --since 24h -o json > flows.json

# 查看服务依赖拓扑
hubble observe --server localhost:4245 | \
  awk '{print $3, "->", $5}' | sort | uniq -c | sort -rn
```

### 4.3 Cilium 监控指标

```yaml
# ServiceMonitor 配置
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: cilium-metrics
  namespace: monitoring
spec:
  selector:
    matchLabels:
      k8s-app: cilium
  endpoints:
    - port: metrics
      interval: 15s
      path: /metrics

# 关键指标 PromQL
# 1. Cilium 管理的 Endpoint 数量
sum(cilium_endpoint_state{endpoint_state="ready"})

# 2. 策略拒绝的包
rate(cilium_drop_total[5m])

# 3. 转发包速率
rate(cilium_forward_count_total[5m])

# 4. 当前连接数
sum(cilium_tcp_open_sockets)

# 5. IPcache 大小
sum(cilium_ipcache_entries)

# 6. Hubble 处理的流
rate(hubble_flows_processed_total[5m])

# 7. Hubble 丢包（按原因）
rate(hubble_drop_total[5m]) by (reason)
```

---

## 5. Cilium 高级特性

### 5.1 Cluster Mesh（多集群互联）

```
Cluster Mesh 允许多个 K8s 集群的 Pod 直接通信:

┌─────────────────────┐         ┌─────────────────────┐
│    Cluster A        │         │    Cluster B        │
│  (region: beijing)  │◄───────►│  (region: shanghai) │
│                     │  etcd   │                     │
│  Pod A (10.1.1.5)   │ 同步身份│  Pod B (10.2.1.5)   │
│                     │         │                     │
│  Service:           │         │  Service:           │
│  backend.beijing    │         │  backend.shanghai   │
└─────────────────────┘         └─────────────────────┘

Pod A 可以直接访问 Pod B 的 IP (10.2.1.5)
也可以访问 backend.shanghai 的 Service IP

配置:
  1. 每个集群部署 Cilium
  2. 创建 clustermesh-apiserver
  3. 交换集群证书
  4. Pod CIDR 不能重叠

helm install cilium cilium/cilium \
  --set cluster.id=1 \
  --set cluster.name=beijing \
  --set clustermesh.useAPIServer=true
```

### 5.2 Bandwidth Manager（带宽管理）

```yaml
# 启用带宽管理
helm upgrade cilium cilium/cilium --namespace kube-system \
  --set bandwidthManager.enabled=true

# 为 Pod 配置带宽限制
apiVersion: v1
kind: Pod
metadata:
  annotations:
    kubernetes.io/egress-bandwidth: "10M"
    kubernetes.io/ingress-bandwidth: "10M"
spec:
  containers:
    - name: app
      image: nginx

# 底层使用 eBPF + EDT (Earliest Departure Time) 实现
# 比 Linux tc 更精确、开销更低
```

### 5.3 WireGuard 加密

```bash
# 启用 WireGuard 加密 Pod 间通信
helm upgrade cilium cilium/cilium --namespace kube-system \
  --set encryption.enabled=true \
  --set encryption.type=wireguard

# 验证加密
# 在节点上抓包，应该只看到 UDP 加密流量
tcpdump -i any -n udp port 51871

# 查看 WireGuard 状态
cilium status | grep Encryption
```

---

## 6. Cilium 调试命令大全

```bash
# ========== 状态检查 ==========
cilium status                    # 整体状态
cilium status --verbose          # 详细信息
cilium version                   # 版本

# ========== Endpoint (Pod) ==========
cilium endpoint list             # 所有 endpoint
cilium endpoint get <id>         # 特定 endpoint
cilium endpoint health <id>      # 健康状态
cilium endpoint log <id>         # 日志

# ========== BPF Map ==========
cilium bpf endpoint list         # BPF endpoint 列表
cilium bpf ipcache list          # IP -> Identity 映射
cilium bpf lb list               # 负载均衡后端
cilium bpf policy list <id>      # 某 endpoint 的策略
cilium bpf ct list global        # 连接跟踪表
cilium bpf tunnel list           # 隧道列表

# ========== 策略 ==========
cilium policy get                # 查看策略
cilium policy selectors          # 策略选择器
cilium policy validate           # 验证策略

# ========== 身份 ==========
cilium identity list             # 所有身份
cilium identity get <id>         # 特定身份

# ========== 监控 ==========
cilium monitor                   # 实时监控
cilium monitor --type drop       # 只看丢包
cilium monitor --type trace      # 跟踪路径
cilium monitor --related-to <id> # 特定 endpoint

# ========== 健康检查 ==========
cilium-health status             # 节点间连通性
cilium-health ping <ip>          # Ping 特定 IP
```

---

## 7. Cilium 面试高频题

**Q: Cilium 相比 Calico 的核心优势是什么？**

<details>
<summary>答案</summary>

1. **性能**: eBPF O(1) vs iptables O(n)，高规则量下性能差距明显
2. **身份模型**: 基于标签的身份 vs 基于 IP 的地址，Pod 重建后策略不变
3. **可观测性**: 内置 Hubble 提供 L7 可见性，Calico 需要额外工具
4. **L7 策略**: 原生支持 HTTP/gRPC/Kafka 策略，Calico 需要额外代理
5. **功能丰富**: Cluster Mesh、带宽管理、WireGuard 加密原生支持

</details>

**Q: Cilium 如何实现 kube-proxy 替代？**

<details>
<summary>答案</summary>

Cilium 通过 eBPF map 实现 Service 负载均衡：
1. 监听 K8s Service/Endpoint 变化
2. 将后端信息写入 `cilium_lb4_services_v2` 和 `cilium_lb4_backends_v2` BPF map
3. 数据包到达时，TC eBPF 程序直接查 map 做 DNAT
4. 无需 iptables 规则链遍历，无需 conntrack
5. 支持 Maglev 一致性哈希、DSR 等高级特性

</details>

---

## 参考资源

- [Cilium 官方文档](https://docs.cilium.io/)
- [Cilium GitHub](https://github.com/cilium/cilium)
- [eBPF 文档](https://ebpf.io/what-is-ebpf)
- [Hubble 文档](https://docs.cilium.io/en/stable/observability/hubble/)
