# K8s 网络深度解析

> Kubernetes 网络是容器编排中最复杂的领域之一。本节从 CNI 规范到具体实现（Calico/Cilium），深入分析 Pod 网络、Service 网络、Ingress 和策略网络的完整链路。

---

## 一、K8s 网络模型

### 1.1 核心要求

```
K8s 网络模型要求（必须满足）：

1. 所有 Pod 可以互相通信
   - 不需要 NAT
   - Pod IP 是真实的、可达的 IP

2. 所有节点可以与所有 Pod 通信
   - kubelet 可以访问任意 Pod

3. Pod 可以看到自己的 IP
   - Pod 内 ifconfig 看到的 IP 与其他 Pod 看到的一致

不满足的网络方案：
  - Docker 默认 bridge：需要端口映射（NAT）
  - 需要额外路由配置的 overlay 网络

满足的网络方案：
  - Flannel（VXLAN/Host-Gateway）
  - Calico（BGP/eBPF）
  - Cilium（eBPF/XDP）
  - Terway（VPC）
  - Weave Net
```

### 1.2 网络地址空间

```
K8s 集群典型地址规划：

┌─────────────────────────────────────────┐
│  VPC CIDR：10.0.0.0/8                   │
│                                         │
│  ├─ 节点子网：10.0.1.0/24               │
│  │   node-1: 10.0.1.10                  │
│  │   node-2: 10.0.1.11                  │
│  │   node-3: 10.0.1.12                  │
│  │                                       │
│  ├─ Pod CIDR：10.244.0.0/16             │
│  │   node-1: 10.244.0.0/24              │
│  │   node-2: 10.244.1.0/24              │
│  │   node-3: 10.244.2.0/24              │
│  │                                       │
│  └─ Service CIDR：10.96.0.0/12          │
│      kubernetes.default: 10.96.0.1        │
│      kube-dns: 10.96.0.10                │
│      my-service: 10.96.123.45            │
└─────────────────────────────────────────┘

关键原则：
  - Pod CIDR、Service CIDR、节点子网不能重叠
  - Pod CIDR 需要足够大（容纳所有 Pod）
  - Service CIDR 需要足够大（容纳所有 Service）
  - 如果与 VPC CIDR 重叠，会导致路由冲突！
```

---

## 二、CNI 规范

### 2.1 CNI 工作流程

```
Pod 创建时的网络配置流程：

kubelet → CRI（containerd）→ runc
    │
    │ 创建网络命名空间（netns）
    ▼
  /var/run/netns/<container-id>
    │
    │ 调用 CNI 插件
    ▼
  /opt/cni/bin/<plugin> ADD <config> <netns> <ifname>
    │
    ├─ 1. 创建 veth pair
    │   veth0（容器内） ↔ veth1（宿主机）
    │
    ├─ 2. 分配 IP 地址
    │   从 IPAM（Host-Local / DHCP / 云 API）获取
    │
    ├─ 3. 配置路由
    │   默认路由指向宿主机网关
    │
    ├─ 4. 配置网络策略（可选）
    │   iptables / eBPF 规则
    │
    └─ 5. 返回结果
       {
         "cniVersion": "0.4.0",
         "interfaces": [...],
         "ips": [{"version": "4", "address": "10.244.1.5/24", "gateway": "10.244.1.1"}],
         "routes": [{"dst": "0.0.0.0/0"}],
         "dns": {"nameservers": ["10.96.0.10"]}
       }

Pod 删除时的网络清理：
  /opt/cni/bin/<plugin> DEL <config> <netns> <ifname>
  - 释放 IP 地址
  - 删除 veth
  - 清理路由
  - 清理网络策略
```

### 2.2 主流 CNI 对比

```
┌──────────┬─────────────┬─────────────┬─────────────┬─────────────┐
│ 特性     │ Flannel     │ Calico      │ Cilium      │ Terway      │
├──────────┼─────────────┼─────────────┼─────────────┼─────────────┤
│ 网络模式 │ VXLAN       │ BGP/eBPF    │ eBPF/XDP    │ VPC ENI     │
│ 性能     │ 中（90%）   │ 高（95%）   │ 极高（99%） │ 极高（99%） │
│ 跨节点   │ VXLAN 封装  │ BGP 路由    │ eBPF 路由   │ VPC 路由    │
│ 策略     │ 无          │ Calico 策略 │ Cilium 策略 │ eBPF 策略   │
│ 加密     │ 无          │ WireGuard   │ WireGuard   │ VPC 加密    │
│ 可观测性 │ 无          │ 一般        │ Hubble      │ 一般        │
│ 复杂度   │ 低          │ 中          │ 中高        │ 中          │
│ 适用规模 │ <1000 节点  │ <5000 节点  │ <10000 节点 │ 大规模      │
│ 云依赖   │ 无          │ 无          │ 无          │ 阿里云      │
└──────────┴─────────────┴─────────────┴─────────────┴─────────────┘
```

---

## 三、Service 网络

### 3.1 kube-proxy 三种模式

```
┌─────────────┬──────────────────┬──────────────────┬──────────────────┐
│ 模式        │ iptables         │ IPVS             │ userspace（废弃）│
├─────────────┼──────────────────┼──────────────────┼──────────────────┤
│ 内核依赖    │ netfilter        │ IP Virtual Server│ 无               │
│ 性能        │ O(n) 遍历        │ O(1) hash        │ 用户态转发       │
│ 最大 Service│ ~5000            │ 无限制           │ 低               │
│ 会话亲和性  │ probability      │ hash             │ 支持             │
│ 健康检查    │ readiness        │ readiness        │ 内置             │
│ 负载均衡    │ 随机             │ rr/lc/sh/dh/...  │ 轮询             │
│ 适用场景    │ 中小型集群       │ 大型集群(推荐)   │ 不适用           │
└─────────────┴──────────────────┴──────────────────┴──────────────────┘

iptables 模式规则链：
  PREROUTING → KUBE-SERVICES → KUBE-SVC-<hash> → KUBE-SEP-<hash> → DNAT

  示例（Service: 10.96.0.10:53 → 3 个 Endpoint）：
  
  Chain KUBE-SERVICES (2 references)
  target     prot opt source               destination
  KUBE-SVC-ABC123DEF456  tcp  --  0.0.0.0/0  10.96.0.10  tcp dpt:53
  
  Chain KUBE-SVC-ABC123DEF456 (1 references)
  target     prot opt source               destination
  KUBE-SEP-ABC111DEF111  all  --  0.0.0.0/0  0.0.0.0/0   statistic mode random probability 0.33333333333
  KUBE-SEP-ABC222DEF222  all  --  0.0.0.0/0  0.0.0.0/0   statistic mode random probability 0.50000000000
  KUBE-SEP-ABC333DEF333  all  --  0.0.0.0/0  0.0.0.0/0
  
  Chain KUBE-SEP-ABC111DEF111 (1 references)
  target     prot opt source               destination
  DNAT       tcp  --  0.0.0.0/0  0.0.0.0/0   tcp to:10.244.1.5:53
  
  概率计算（rr 模拟）：
  - 第 1 条：probability 1/3，33.3% 命中
  - 第 2 条：probability 1/2（剩余 66.7% 的 50%），33.3% 命中
  - 第 3 条：100%（剩余 33.3%），33.3% 命中

IPVS 模式规则：
  ipvsadm -Ln
  
  TCP  10.96.0.10:53 rr
    -> 10.244.1.5:53             Masq    1      0          0
    -> 10.244.1.6:53             Masq    1      0          0
    -> 10.244.1.7:53             Masq    1      0          0
  
  负载均衡算法：
  - rr (Round Robin)：轮询
  - lc (Least Connection)：最少连接
  - dh (Destination Hash)：目标哈希
  - sh (Source Hash)：源哈希
  - sed (Shortest Expected Delay)：最短预期延迟
  - nq (Never Queue)：不排队
```

### 3.2 EndpointSlice

```
EndpointSlice（K8s 1.21+ 默认）：

替代旧的 Endpoints 对象：
  - Endpoints：单个对象存储所有 Endpoint
    * 1000 个 Endpoint 时，对象大小 > 1MB
    * 每次更新需要传输整个对象
    * 性能瓶颈
    
  - EndpointSlice：分片存储
    * 每个 Slice 最多 100 个 Endpoint
    * 1000 个 Endpoint = 10 个 Slice
    * 只更新变更的 Slice
    * 性能提升 10x+

结构：
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: my-service-abc12
  labels:
    kubernetes.io/service-name: my-service
addressType: IPv4
ports:
- name: http
  protocol: TCP
  port: 8080
endpoints:
- addresses:
  - 10.244.1.5
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: node-1
  targetRef:
    name: my-pod-abc12
    kind: Pod
- addresses:
  - 10.244.1.6
  conditions:
    ready: true
    serving: true
    terminating: false
  nodeName: node-2
```

---

## 四、Ingress 与负载均衡

### 4.1 Ingress 控制器对比

```
┌──────────┬─────────────┬─────────────┬─────────────┬─────────────┐
│ 特性     │ Nginx       │ Traefik     │ Istio       │ ALB (云)    │
├──────────┼─────────────┼─────────────┼─────────────┼─────────────┤
│ 协议     │ HTTP/HTTPS  │ HTTP/HTTPS  │ HTTP/HTTPS  │ HTTP/HTTPS  │
│          │ TCP/UDP     │ TCP/UDP     │ gRPC        │ gRPC        │
│          │             │             │ TCP/UDP     │ WebSocket   │
│ 路由     │ Host/Path   │ Host/Path   │ Host/Path   │ Host/Path   │
│          │             │ Headers     │ Headers     │ Headers     │
│          │             │             │ Weight      │ Weight      │
│ 性能     │ 高          │ 中          │ 高          │ 极高        │
│ 配置     │ ConfigMap   │ CRD         │ CRD         │ CRD/Annotation│
│ 动态配置 │ 需 reload   │ 自动        │ 自动        │ 自动        │
│ SSL 终止 │ 支持        │ 支持        │ 支持        │ 支持        │
│ WAF      │ 需 ModSecurity│ 需插件   │ 需插件      │ 内置        │
└──────────┴─────────────┴─────────────┴─────────────┴─────────────┘
```

### 4.2 Ingress-Nginx 内部机制

```
Ingress-Nginx 架构：

  ┌─────────────────────────────────────────┐
  │  Ingress Controller Pod                 │
  │                                         │
  │  ┌─────────────────────────────────────┐│
  │  │  Control Loop                       ││
  │  │   - Watch Ingress/Service/Endpoint  ││
  │  │   - 生成 Nginx 配置                 ││
  │  │   - 写入 /etc/nginx/nginx.conf      ││
  │  │   - 发送 SIGHUP 重载（或 lua 热更新）││
  │  └─────────────────────────────────────┘│
  │                   │                     │
  │                   ▼                     │
  │  ┌─────────────────────────────────────┐│
  │  │  Nginx Worker                       ││
  │  │   - HTTP/HTTPS 监听（80/443）       ││
  │  │   - 基于 Lua 的动态路由             ││
  │  │   - upstream 指向 Service Endpoint  ││
  │  │   - SSL 终止                        ││
  │  │   - 限流/缓存/压缩                  ││
  │  └─────────────────────────────────────┘│
  └─────────────────────────────────────────┘

Nginx 配置结构：
  http {
    upstream upstream_balancer {
      server 10.244.1.5:8080 max_fails=1 fail_timeout=10s;
      server 10.244.1.6:8080 max_fails=1 fail_timeout=10s;
      server 10.244.1.7:8080 max_fails=1 fail_timeout=10s;
    }
    
    server {
      listen 80;
      server_name app.example.com;
      
      location / {
        proxy_pass http://upstream_balancer;
        proxy_connect_timeout 5s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
      }
    }
  }

关键配置：
  - worker_processes：auto（等于 CPU 核数）
  - worker_connections：16384
  - use epoll（Linux 高性能 IO 多路复用）
  - multi_accept on
```

---

## 五、网络策略

### 5.1 NetworkPolicy 详解

```yaml
# NetworkPolicy 示例：只允许 frontend 访问 backend 的 8080 端口
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: backend
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 8080
  egress:
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 3306

策略解读：
  1. 选中所有 app=backend 的 Pod
  2. Ingress 规则：
     - 只允许来自 app=frontend 的 Pod 的流量
     - 只允许 TCP 8080 端口
     - 其他所有入站流量被拒绝
  3. Egress 规则：
     - 只允许到 app=database 的 Pod 的流量
     - 只允许 TCP 3306 端口
     - 其他所有出站流量被拒绝
  4. 注意：
     - 默认 deny all（设置了 policyTypes 后）
     - 需要显式允许 DNS（UDP 53）
     - 需要显式允许同命名空间通信（如果需要）

常见错误：
  # 错误：设置了 ingress 规则，但忘记允许 DNS
  # 结果：Pod 无法解析域名，外部调用失败
  
  # 修复：添加 DNS 规则
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
  - to:
    - podSelector:
        matchLabels:
          app: database
    ports:
    - protocol: TCP
      port: 3306
```

### 5.2 Cilium 网络策略（L7）

```yaml
# CiliumNetworkPolicy：支持 L7 策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/api/v1/users/.*"
        - method: POST
          path: "/api/v1/orders"
        - method: DELETE
          path: "/api/v1/orders/.*"
          
优势：
  - 基于 eBPF 实现，性能损耗 < 1%
  - 支持 L7 策略（HTTP 方法、路径）
  - 自动允许已建立的连接（状态跟踪）
  - 支持 DNS 策略（基于 FQDN）

DNS 策略示例：
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: egress-dns
spec:
  endpointSelector:
    matchLabels:
      app: frontend
  egress:
  - toFQDNs:
    - matchPattern: "*.mycompany.com"
    - matchName: "api.github.com"
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: UDP
```

---

## 六、DNS 在 K8s 中

### 6.1 CoreDNS 架构

```
CoreDNS 架构：

Pod → /etc/resolv.conf
  nameserver 10.96.0.10
  search default.svc.cluster.local svc.cluster.local cluster.local
  options ndots:5
    │
    ▼
CoreDNS Pod（2+ 副本）
  │
  ├─ 插件链：
  │   1. errors          # 错误日志
  │   2. log             # 访问日志
  │   3. health          # 健康检查 :8080
  │   4. ready           # 就绪检查 :8181
  │   5. kubernetes      # K8s DNS 解析
  │   6. prometheus      # 指标 :9153
  │   7. forward         # 转发到上游 DNS
  │   8. cache           # 缓存
  │   9. loop            # 环路检测
  │   10. reload         # 配置热重载
  │   11. loadbalance    # 负载均衡（round_robin）
  │
  ├─ K8s 插件解析逻辑：
  │   - <service>.<namespace>.svc.cluster.local → ClusterIP
  │   - <pod-ip>.<namespace>.pod.cluster.local → Pod IP
  │   - <name>.<namespace>.svc → 短名称（ndots < 5 时）
  │
  └─ 上游转发：
      - /etc/resolv.conf 中的 nameserver
      - 或 Corefile 中配置的 forward 地址

Corefile 配置：
  .:53 {
      errors
      health {
          lameduck 5s
      }
      ready
      kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
          ttl 30
      }
      prometheus :9153
      forward . /etc/resolv.conf {
          max_concurrent 1000
      }
      cache 30 {
          success 9984 300
          denial 9984 60
      }
      loop
      reload
      loadbalance
  }
```

### 6.2 DNS 性能优化

```bash
# ndots 问题诊断
dig +stats kubernetes.default.svc.cluster.local
# Query time: 1 msec  ← 完全限定域名，快

dig +stats kubernetes
# Query time: 234 msec  ← 不完全限定，慢！
# 原因：ndots:5，"kubernetes" 只有 1 个 dot
# 会依次尝试：
#   kubernetes.default.svc.cluster.local  → 存在
#   kubernetes.svc.cluster.local          → NXDOMAIN
#   kubernetes.cluster.local              → NXDOMAIN
#   kubernetes.ec2.internal               → NXDOMAIN（AWS）
#   kubernetes                            → 最终匹配

# 优化方案 1：使用完全限定域名
curl http://my-service.my-namespace.svc.cluster.local.
# 末尾的 . 表示 FQDN，不搜索域

# 优化方案 2：降低 ndots
# Pod 级别：
spec:
  dnsConfig:
    options:
      - name: ndots
        value: "2"

# 优化方案 3：部署 NodeLocal DNSCache
# 每个节点运行一个 DNS 缓存代理
# 减少跨节点 DNS 查询
kubectl apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml

# 优化效果：
# DNS P99 延迟：50ms → 2ms
# CoreDNS CPU：80% → 20%
# 上游 DNS 流量：减少 70%
```

---

## 七、面试要点

```
Q: K8s 网络模型为什么要求 Pod IP 直接可达？

A: 设计哲学：
   - 容器化应用应该像虚拟机一样工作
   - 每个 Pod 有自己的 IP，就像 VM 有自己的 IP
   - 无需端口映射（NAT），简化应用配置
   - 与主机网络解耦，便于迁移和扩展
   
   实现方式：
   - CNI 插件分配 Pod IP
   - 跨节点通过 overlay（VXLAN）或 underlay（BGP）路由
   - Service 提供稳定的虚拟 IP

Q: Calico BGP 模式和 Cilium eBPF 模式有什么区别？

A: 数据平面差异：
   
   Calico BGP：
   - 使用 Linux 内核的 BGP 守护进程（BIRD）
   - 每个节点宣告 Pod CIDR 路由
   - 数据包通过标准 Linux 路由表转发
   - 网络策略通过 iptables 实现
   - 性能：95%（iptables 开销）
   
   Cilium eBPF：
   - 使用 eBPF 程序替换 iptables
   - 直接在 kernel 中处理数据包
   - 无需经过 netfilter 框架
   - 网络策略通过 eBPF map 实现
   - 性能：99%
   
   选择建议：
   - 简单场景：Calico（稳定、文档丰富）
   - 高性能/可观测性：Cilium（eBPF、Hubble）
   - 阿里云：Terway（VPC 原生）

Q: kube-proxy iptables 模式的性能瓶颈在哪里？

A: 瓶颈点：
   1. O(n) 遍历：
      - 每个新连接需要遍历所有 Service 规则
      - 5000 Service ≈ 5 万条 iptables 规则
      - 遍历时间：0.5-2ms/连接
   
   2. 规则更新延迟：
      - Endpoint 变更时，需要重写整个 iptables 规则集
      - iptables-restore 耗时：100ms-1s
      - 更新期间可能丢包
   
   3. 连接跟踪表：
      - conntrack 表满时，新连接被拒绝
      - 默认 nf_conntrack_max = 65536
      - 高并发场景容易溢出
   
   解决方案：
   - 切换到 IPVS 模式：O(1) hash 查找
   - 限制 Service 数量：清理无用 Service
   - 调大 conntrack 表：524288
```
