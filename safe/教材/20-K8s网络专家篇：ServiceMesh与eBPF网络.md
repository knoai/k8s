# 第20章 K8s 网络专家篇：Service Mesh、eBPF 与多集群网络

> **本章目标**：进入 K8s 网络的高级领域，理解 Service Mesh 架构、eBPF 网络编程、多集群互联方案，以及生产环境网络故障排查方法论。
>
> 读完本章后，你应该能够：理解 Service Mesh 的核心价值；配置 Istio 流量管理和安全策略；理解 eBPF 在网络中的应用；设计多集群网络方案；排查复杂网络故障。

---

## 20.1 Service Mesh 架构

### 20.1.1 为什么需要 Service Mesh

**传统微服务网络痛点**：

```
┌─────────────────────────────────────────────────────────────┐
│  每个微服务自己实现（代码重复、语言绑定、升级困难）：          │
│  ├─ 服务发现     → 每个服务集成 Consul/Eureka               │
│  ├─ 负载均衡     → 每个服务自己实现轮询/随机                  │
│  ├─ 熔断限流     → 每个服务引入 Hystrix/Resilience4j        │
│  ├─ 重试超时     → 每个服务配置重试策略                       │
│  ├─ mTLS 加密    → 每个服务管理证书                           │
│  ├─ 认证授权     → 每个服务实现 JWT/OAuth2 验证               │
│  └─ 可观测性     → 每个服务集成 Prometheus/Jaeger            │
│                                                             │
│  问题：                                                       │
│  - 代码重复：同样逻辑在每个服务中重复实现                      │
│  - 语言绑定：Java 的 Hystrix 无法给 Go 服务使用               │
│  - 升级困难：修改一处逻辑需要升级所有服务                      │
│  - 配置分散：策略配置分散在各服务的配置文件中                  │
└─────────────────────────────────────────────────────────────┘
```

**Service Mesh 方案**：

```
┌─────────────────────────────────────────────────────────────┐
│                     数据平面（Data Plane）                    │
│                                                             │
│  ┌─────────┐         ┌─────────┐         ┌─────────┐       │
│  │   App   │◄───────►│  Envoy  │◄───────►│  Envoy  │◄─────▶│
│  │ (业务)   │localhost│ (代理)  │  网络   │ (代理)  │       │
│  │         │:15001   │         │         │         │       │
│  │ 0.0.0.0:8080    0.0.0.0:15001                          │
│  └─────────┘         └─────────┘         └─────────┘       │
│       ▲                                                    │
│       │                                                    │
│  ┌────┴────┐                                              │
│  │ Istiod  │  ← 控制平面：配置分发(xDS)、证书管理(CA)      │
│  │(xDS CA) │                                              │
│  └─────────┘                                              │
│                                                             │
│  核心价值：                                                   │
│  - 能力下沉：网络能力从应用代码剥离到 Sidecar                  │
│  - 语言无关：Java/Go/Python/Node.js 服务统一受益              │
│  - 统一治理：集中配置管理所有服务的网络行为                    │
│  - 零信任：默认加密 + 认证授权                                │
└─────────────────────────────────────────────────────────────┘
```

### 20.1.2 Istio 架构详解

```
                    控制平面（Control Plane）
                           │
         ┌─────────────────┼─────────────────┐
         │                 │                 │
         ▼                 ▼                 ▼
    ┌─────────┐      ┌─────────┐      ┌─────────┐
    │ Istiod  │      │ Istiod  │      │ Istiod  │
    │         │      │         │      │         │
    │ ┌─────┐ │      │ ┌─────┐ │      │ ┌─────┐ │
    │ │Pilot│ │      │ │Pilot│ │      │ │Pilot│ │
    │ │(xDS)│ │      │ │(xDS)│ │      │ │(xDS)│ │
    │ └─────┘ │      │ └─────┘ │      │ └─────┘ │
    │ ┌─────┐ │      │ ┌─────┐ │      │ ┌─────┐ │
    │ │Citadel│      │ │Citadel│      │ │Citadel│
    │ │(CA) │ │      │ │(CA) │ │      │ │(CA) │ │
    │ └─────┘ │      │ └─────┘ │      │ └─────┘ │
    └─────────┘      └─────────┘      └─────────┘
         │                 │                 │
         │    xDS 配置分发  │                 │
         │   (ADS/CDS/EDS/  │                 │
         │    LDS/RDS/SDS) │                 │
         │                 │                 │
    ┌────┴─────────────────┴─────────────────┴────┐
    │              数据平面（Data Plane）            │
    │                                               │
    │  Pod A          Pod B          Pod C          │
    │  ┌─────┐        ┌─────┐        ┌─────┐       │
    │  │ App │◄──────►│ App │◄──────►│ App │       │
    │  └─────┘ 15001  └─────┘ 15001  └─────┘       │
    │    ▲              ▲              ▲            │
    │    │              │              │            │
    │  ┌─┴─┐          ┌─┴─┐          ┌─┴─┐         │
    │  │Envoy│        │Envoy│        │Envoy│        │
    │  │Sidecar│      │Sidecar│      │Sidecar│      │
    │  └─────┘        └─────┘        └─────┘       │
    └───────────────────────────────────────────────┘

Istio 控制平面组件（Istiod 内部）：
├─ Pilot：xDS 配置分发（服务发现、路由、负载均衡配置）
├─ Citadel：证书签发和轮换（自动 mTLS）
├─ Galley：配置验证和分发
└─ Sidecar Injector：自动注入 Envoy Sidecar

xDS API 类型：
├─ LDS（Listener Discovery Service）：监听器配置
├─ RDS（Route Discovery Service）：路由配置
├─ CDS（Cluster Discovery Service）：集群（上游服务）配置
├─ EDS（Endpoint Discovery Service）：端点（Pod IP）配置
├─ SDS（Secret Discovery Service）：TLS 证书配置
└─ ADS（Aggregated Discovery Service）：聚合所有配置
```

**部署 Istio**：

```bash
# 下载 Istio
export ISTIO_VERSION=1.20.0
curl -L https://istio.io/downloadIstio | sh -
cd istio-${ISTIO_VERSION}
export PATH=$PWD/bin:$PATH

# 安装（demo profile 含所有功能）
istioctl install --set profile=demo -y

# 启用自动 Sidecar 注入
kubectl label namespace default istio-injection=enabled

# 验证
kubectl get pods -n istio-system
istioctl verify-install
```

### 20.1.3 Istio 核心功能详解

#### 1. 自动 mTLS

```bash
# 查看 mTLS 状态
istioctl authn tls-check <pod>.<namespace>

# 默认 PERMISSIVE 模式（允许明文和 TLS）
# 生产环境应切换到 STRICT
kubectl apply -f - << 'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: default
spec:
  mtls:
    mode: STRICT
EOF

# 命名空间级别强制 mTLS
kubectl apply -f - << 'EOF'
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: production
spec:
  mtls:
    mode: STRICT
EOF
```

#### 2. 流量管理

```yaml
# 金丝雀发布（Canary）
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1
      weight: 80
    - destination:
        host: reviews
        subset: v2
      weight: 20

---
# 超时与重试
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: ratings
spec:
  hosts:
  - ratings
  http:
  - route:
    - destination:
        host: ratings
    timeout: 5s
    retries:
      attempts: 3
      perTryTimeout: 2s
      retryOn: gateway-error,connect-failure,refused-stream

---
# 熔断
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: ratings
spec:
  host: ratings
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 100
      http:
        http1MaxPendingRequests: 50
        maxRequestsPerConnection: 10
    outlierDetection:
      consecutiveErrors: 5
      interval: 30s
      baseEjectionTime: 30s
      maxEjectionPercent: 50
```

#### 3. 安全策略

```yaml
# 授权策略：只允许 frontend 访问 backend
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  selector:
    matchLabels:
      app: backend
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/production/sa/frontend"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/api/*"]
    when:
    - key: request.auth.claims[iss]
      values: ["https://accounts.google.com"]
```

### 20.1.4 Istio Ambient Mesh（无 Sidecar 模式）

```
Sidecar 模式的问题：
┌─────────────────────────────┐
│ Pod                         │
│  ┌─────┐  ┌─────┐          │
│  │ App │  │Envoy│ 150MB+   │
│  │     │  │     │          │
│  └─────┘  └─────┘          │
│       每个 Pod 一个 Sidecar   │
│       资源开销大，启动慢       │
└─────────────────────────────┘

Ambient Mesh 方案：
┌─────────────────────────────────────────┐
│              节点层面                      │
│  ┌─────────────────────────────────┐    │
│  │         zTunnel (DaemonSet)     │    │
│  │    （每个节点一个，L4 代理）      │    │
│  │    资源开销：~50MB 每节点         │    │
│  └─────────────────────────────────┘    │
│              ▲      ▲                   │
│              │      │                   │
│  ┌───────────┘      └───────────┐      │
│  │                              │      │
│  ▼                              ▼      │
│ Pod A                          Pod B   │
│ (无Sidecar)                   (无Sidecar)│
│                                         │
│  ┌─────────────────────────────────┐   │
│  │    Waypoint Proxy (可选)         │   │
│  │    （按 Service/Namespace，L7）   │   │
│  │    只在需要 L7 处理时部署          │   │
│  └─────────────────────────────────┘   │
└─────────────────────────────────────────┘

特点：
- L4 处理：节点级 zTunnel，无 per-Pod 开销
- L7 处理：按需部署 Waypoint Proxy
- 兼容现有 Sidecar 模式
- 资源开销降低 60-70%
```

### 20.1.5 Linkerd：轻量级替代

```bash
# 安装 Linkerd
curl --proto '=https' --tlsv1.2 -sSfL https://run.linkerd.io/install | sh

# 验证集群兼容性
linkerd check --pre

# 安装控制平面
linkerd install --crds | kubectl apply -f -
linkerd install | kubectl apply -f -

# 验证
linkerd check

# 注入 Sidecar
kubectl get deploy -o yaml | linkerd inject - | kubectl apply -f -
```

**Istio vs Linkerd 对比**：

| 特性 | Istio | Linkerd |
|------|-------|---------|
| 资源占用 | 较高（Envoy ~150MB） | 低（~100MB） |
| 功能丰富度 | 极高（全功能） | 核心功能 |
| 复杂度 | 高 | 低 |
| 性能 | 高 | 极高 |
| 社区 | CNCF 毕业 | CNCF 毕业 |
| 适用 | 大型企业、复杂场景 | 中小团队、快速上手 |
| Sidecarless | Ambient Mesh（实验） | 不支持 |

---

## 20.2 eBPF 网络编程

### 20.2.1 eBPF 技术原理

```
用户空间                内核空间
    │                       │
    │  bpf() 系统调用       │
    ▼                       ▼
┌─────────┐           ┌─────────────┐
│ eBPF    │──────────▶│  验证器      │
│ 程序    │           │（安全检查）   │
│ (C/Go)  │           │             │
│         │           │ 检查项：      │
│         │           │ - 无无限循环 │
│         │           │ - 无空指针   │
│         │           │ - 内存访问合法│
└─────────┘           └──────┬──────┘
                             │
                             ▼
                      ┌─────────────┐
                      │  JIT 编译器  │
                      │（编译为机器码）│
                      └──────┬──────┘
                             │
                             ▼
                      ┌─────────────┐
                      │  挂载点      │
                      │  XDP/TC/    │
                      │  kprobe/    │
                      │  tracepoint │
                      └─────────────┘

安全保证：
- 验证器确保程序不会崩溃内核
- 有限的指令数（~100万条）
- 有限的循环次数
- 只能访问特定的内核辅助函数
```

**eBPF 在网络中的应用**：

| 挂载点 | 用途 | 代表工具 | 性能影响 |
|--------|------|---------|---------|
| **XDP** | 网卡驱动层包处理 | Cilium L4LB | 极低（~ns 级） |
| **TC (Traffic Control)** | 流量分类和过滤 | Cilium 网络策略 | 低 |
| **Socket Filter** | 套接字层过滤 | Falco | 低 |
| **SockOps** | 套接字操作优化 | Cilium 加速 | 低 |
| **kprobe** | 内核函数跟踪 | Tetragon | 中 |
| **tracepoint** | 内核事件跟踪 | bpftrace | 低 |

### 20.2.2 Cilium 的 eBPF 实现

```
┌─────────────────────────────────────────────────────────────┐
│                     Cilium eBPF 数据平面                     │
├─────────────────────────────────────────────────────────────┤
│  XDP 层（可选）                                              │
│  ├─ 负载均衡（DDoS 防护、LB）                                │
│  ├─ 快速路径处理                                             │
│  └─ 在网卡驱动层处理，性能最高                               │
├─────────────────────────────────────────────────────────────┤
│  TC (Traffic Control) 层                                     │
│  ├─ Ingress eBPF 程序：策略执行、NAT、负载均衡              │
│  ├─ Egress eBPF 程序：策略执行、加密                        │
│  └─ 替代 iptables 规则链                                     │
├─────────────────────────────────────────────────────────────┤
│  Socket 层                                                   │
│  ├─ Sockops：加速 Pod 间通信（绕过 TCP/IP 栈）              │
│  └─ Socket LB：绕过 kube-proxy，直接负载均衡                │
├─────────────────────────────────────────────────────────────┤
│  内核辅助函数                                                │
│  ├─ 连接追踪（替代 conntrack，无锁）                        │
│  ├─ 身份映射（IP -> 身份，O(1) 查找）                       │
│  └─ 策略查找（eBPF Map，O(1) 复杂度）                       │
└─────────────────────────────────────────────────────────────┘

Cilium 性能优势对比：

| 操作 | iptables | IPVS | Cilium eBPF |
|------|----------|------|-------------|
| Service 查找 | O(n) 规则遍历 | O(1) hash | O(1) hash |
| 连接追踪 | conntrack 锁竞争 | conntrack | 无锁 eBPF map |
| 策略执行 | iptables 链遍历 | iptables | O(1) 直接跳转 |
| 尾延迟 | 高（规则多） | 中 | 低且稳定 |
| 可扩展性 | 差（规则线性增长） | 中 | 优秀 |
```

### 20.2.3 eBPF 程序示例

```c
// hello.c - 简单的 eBPF XDP 程序
#include <linux/bpf.h>
#include <bpf/bpf_helpers.h>

SEC("xdp")
int hello(struct xdp_md *ctx) {
    void *data_end = (void *)(long)ctx->data_end;
    void *data = (void *)(long)ctx->data;
    
    // 解析以太网头部
    struct ethhdr *eth = data;
    if ((void *)(eth + 1) > data_end)
        return XDP_DROP;
    
    // 只放行 IPv4 包
    if (eth->h_proto == __constant_htons(ETH_P_IP))
        return XDP_PASS;
    
    return XDP_DROP;
}

char _license[] SEC("license") = "GPL";
```

```bash
# 编译 eBPF 程序
clang -O2 -target bpf -c hello.c -o hello.o

# 使用 bpftool 加载到网卡
sudo bpftool prog load hello.o /sys/fs/bpf/hello
sudo bpftool net attach xdp pinned /sys/fs/bpf/hello dev eth0

# 查看加载的程序
sudo bpftool prog list
sudo bpftool prog dump xlated id <id>

# 卸载
sudo bpftool net detach xdp dev eth0
sudo rm /sys/fs/bpf/hello
```

---

## 20.3 多集群网络

### 20.3.1 多集群网络方案对比

| 方案 | 原理 | 特点 | 适用场景 |
|------|------|------|---------|
| **Cilium ClusterMesh** | eBPF + etcd 同步 | 高性能，身份感知 | 同构集群，需要高级策略 |
| **Submariner** | VXLAN/IPsec 隧道 | 开源通用，支持多种 CNI | 异构集群 |
| **Istio Multi-Cluster** | 服务网格互联 | 应用层互联，mTLS | 已有 Istio |
| **VPC Peering** | 云厂商网络 | 最简单，云原生 | 同云多区 |
| **VPN/专线** | 网络层隧道 | 通用，性能好 | 混合云、跨云 |

### 20.3.2 Cilium ClusterMesh

```
┌─────────────────────┐         ┌─────────────────────┐
│    Cluster 1        │         │    Cluster 2        │
│                     │         │                     │
│  ┌───────────────┐  │         │  ┌───────────────┐  │
│  │ Cilium Agent  │  │◄─etcd──►│  │ Cilium Agent  │  │
│  │ (clustermesh) │  │  同步   │  │ (clustermesh) │  │
│  └───────┬───────┘  │         │  └───────┬───────┘  │
│          │          │         │          │          │
│  ┌───────┴───────┐  │         │  ┌───────┴───────┐  │
│  │  Service A    │  │◄────────►│  │  Service A    │  │
│  │  (10.0.1.0/24)│  │   Pod   │  │  (10.0.2.0/24)│  │
│  └───────────────┘  │  直接通信 │  └───────────────┘  │
└─────────────────────┘         └─────────────────────┘

ClusterMesh 特点：
- Pod IP 在集群间可直接路由
- 服务发现跨集群自动同步
- 网络策略跨集群生效
- 身份（Identity）跨集群一致
```

**部署 ClusterMesh**：

```bash
# 集群 1
cilium clustermesh enable --context cluster1
cilium clustermesh connect --destination-context cluster2

# 验证
cilium clustermesh status --context cluster1

# 创建全局 Service
kubectl apply -f - << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: global-service
  annotations:
    io.cilium/global-service: "true"
spec:
  type: ClusterIP
  selector:
    app: backend
  ports:
  - port: 80
EOF
```

### 20.3.3 多集群安全策略

```yaml
# Cilium ClusterMesh 网络策略
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: cross-cluster-policy
  namespace: production
spec:
  endpointSelector:
    matchLabels:
      app: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
        # 允许来自其他集群的 frontend
        k8s:io.kubernetes.pod.namespace: production
```

---

## 20.4 网络可观测性

### 20.4.1 Hubble（Cilium 可观测性）

```bash
# 启用 Hubble
helm upgrade cilium cilium/cilium -n kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# 命令行观察流量
hubble observe --namespace production
hubble observe --pod my-pod --follow
hubble observe --to-ip 10.0.1.100

# 查看流量 dropped 原因
hubble observe --verdict DROPPED

# Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 12000:80
# 访问 http://localhost:12000
```

### 20.4.2 Istio 遥测

```bash
# Kiali：服务拓扑可视化
istioctl dashboard kiali

# Grafana：指标Dashboard
istioctl dashboard grafana

# Jaeger：分布式追踪
istioctl dashboard jaeger

# 查看服务指标
kubectl exec -it <pod> -c istio-proxy -- curl localhost:15090/stats/prometheus
```

---

## 20.5 网络故障排查方法论

### 20.5.1 排查流程图

```
Pod 无法访问 Service
        │
        ▼
┌───────────────┐
│ 1. DNS 解析    │
│ nslookup svc   │
└───────┬───────┘
        │
    ┌───┴───┐
    │失败   │成功
    ▼       ▼
检查     ┌───────────────┐
CoreDNS  │ 2. Service IP │
配置     │ 是否可达      │
         │ curl svc:port │
         └───────┬───────┘
                 │
             ┌───┴───┐
             │失败   │成功
             ▼       ▼
        检查        ┌───────────────┐
        kube-proxy │ 3. Pod IP     │
        / iptables │ 是否可达      │
                 │ curl pod:port │
                 └───────┬───────┘
                         │
                     ┌───┴───┐
                     │失败   │成功
                     ▼       ▼
                检查     检查应用
                CNI      端口监听
                网络     防火墙
```

### 20.5.2 核心排查命令

```bash
# ========== 1. DNS 排查 ==========
kubectl run test --rm -i --tty --image=busybox -- nslookup kubernetes.default
kubectl logs -n kube-system -l k8s-app=kube-dns

# ========== 2. Service 排查 ==========
kubectl get svc <name>
kubectl get endpoints <name>
kubectl get endpointslices -l kubernetes.io/service-name=<name>
sudo iptables -t nat -L KUBE-SERVICES -n | grep <svc-ip>
sudo ipvsadm -Ln | grep <svc-ip>

# ========== 3. Pod 网络排查 ==========
kubectl get pod -o wide
sudo nsenter -t <pod-pid> -n ip addr
sudo nsenter -t <pod-pid> -n ip route
sudo tcpdump -i any host <pod-ip> -nn

# ========== 4. CNI 排查 ==========
cat /etc/cni/net.d/*.conf
kubectl logs -n kube-system -l k8s-app=calico-node
kubectl logs -n kube-system -l k8s-app=cilium
cilium status
cilium endpoint list

# ========== 5. 跨节点通信排查 ==========
ping <other-node-ip>
ip route show
sudo ip -d link show flannel.1
sudo bridge fdb show | grep flannel
```

### 20.5.3 网络性能测试

```bash
# iperf3 带宽测试
kubectl run iperf-server --image=networkstatic/iperf3 -- iperf3 -s
kubectl expose pod iperf-server --port=5201
kubectl run iperf-client --rm -i --tty --image=networkstatic/iperf3 -- iperf3 -c iperf-server

# netperf 延迟测试
kubectl run netserver --image=pwfk/netperf -- netserver
kubectl run netperf-test --rm -i --tty --image=pwfk/netperf -- netperf -H netserver -t TCP_RR
```

---

## 20.6 本章实验

### 实验 20.1：Istio 金丝雀发布（25 分钟）

```bash
# 步骤 1：安装 Istio
istioctl install --set profile=demo -y
kubectl label namespace default istio-injection=enabled

# 步骤 2：部署 bookinfo 示例
kubectl apply -f samples/bookinfo/platform/kube/bookinfo.yaml

# 步骤 3：创建 DestinationRule
kubectl apply -f - << 'EOF'
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: reviews
spec:
  host: reviews
  subsets:
  - name: v1
    labels:
      version: v1
  - name: v2
    labels:
      version: v2
EOF

# 步骤 4：100% 流量到 v1
kubectl apply -f - << 'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1
      weight: 100
EOF

# 步骤 5：切换到 50/50
kubectl apply -f - << 'EOF'
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: reviews
spec:
  hosts:
  - reviews
  http:
  - route:
    - destination:
        host: reviews
        subset: v1
      weight: 50
    - destination:
        host: reviews
        subset: v2
      weight: 50
EOF

# 步骤 6：观察 Kiali
istioctl dashboard kiali
```

### 实验 20.2：Cilium L7 网络策略（20 分钟）

```bash
# 步骤 1：确保 Cilium 和 Hubble 已启用

# 步骤 2：创建测试命名空间和应用
kubectl create ns l7-test
kubectl run backend --image=kennethreitz/httpbin -n l7-test
kubectl expose pod backend --port=80 -n l7-test

# 步骤 3：创建 L7 策略
kubectl apply -n l7-test -f - << 'EOF'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: httpbin-policy
spec:
  endpointSelector:
    matchLabels:
      run: backend
  ingress:
  - fromEndpoints:
    - matchLabels:
        run: frontend
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/get"
EOF

# 步骤 4：测试允许的请求
kubectl run frontend --rm -i --tty -n l7-test --image=curlimages/curl -- curl http://backend/get

# 步骤 5：测试被拒绝的请求
kubectl run frontend --rm -i --tty -n l7-test --image=curlimages/curl -- curl http://backend/post -X POST

# 步骤 6：使用 Hubble 观察
kubectl exec -n kube-system -it ds/cilium -c cilium -- hubble observe --namespace l7-test
```

### 实验 20.3：跨节点网络抓包分析（20 分钟）

```bash
# 步骤 1：在不同节点上创建 Pod
kubectl run pod-a --image=busybox -- sleep 3600
kubectl run pod-b --image=busybox -- sleep 3600
# 记录 Pod IP 和所在节点

# 步骤 2：在 Pod A 所在节点抓包
sudo tcpdump -i any host <pod-b-ip> -w /tmp/cross-node.pcap -nn

# 步骤 3：在 Pod A 中访问 Pod B
kubectl exec pod-a -- ping <pod-b-ip>

# 步骤 4：分析抓包
sudo tcpdump -r /tmp/cross-node.pcap -nn -v | head -20
# 观察封装方式：VXLAN(UDP 4789)、IPIP、或直接路由
```

---

## 20.7 Istio Ambient Mesh 深度实践

### 20.7.1 Ambient Mesh 架构详解

Istio Ambient Mesh（1.18+）引入无 Sidecar 模式：

```
Ambient Mesh 架构：

┌─────────────────────────────────────────────────────────────┐
│                        集群                                  │
│                                                              │
│   ┌─────────────┐       ┌─────────────┐                    │
│   │  ztunnel    │◄─────►│  ztunnel    │   L4 安全覆盖层    │
│   │ (每个节点)   │  mTLS  │ (每个节点)   │                   │
│   └──────┬──────┘       └──────┬──────┘                   │
│          │                      │                           │
│   ┌──────┴──────┐       ┌──────┴──────┐                   │
│   │   App Pod   │       │   App Pod   │   无 Sidecar!     │
│   │  (无 Envoy)  │       │  (无 Envoy)  │                   │
│   └─────────────┘       └─────────────┘                   │
│                                                              │
│   ┌─────────────────────────────────────────┐              │
│   │         waypoint proxy (按命名空间)       │              │
│   │   ┌─────────┐  ┌─────────┐  ┌────────┐ │              │
│   │   │  Envoy  │  │  Envoy  │  │ Envoy  │ │  L7 按需启用  │
│   │   └─────────┘  └─────────┘  └────────┘ │              │
│   └─────────────────────────────────────────┘              │
│                                                              │
└─────────────────────────────────────────────────────────────┘

ztunnel = 轻量级 L4 代理（基于 Rust，资源占用极低）
waypoint = 可选 L7 代理（需要时创建）
```

**Ambient vs Sidecar 对比**：

| 维度 | Sidecar 模式 | Ambient 模式 |
|------|-------------|-------------|
| 资源开销 | 每 Pod 一个 Envoy（50-100MB） | 每节点一个 ztunnel（~20MB） |
| 注入方式 | 自动注入 / 手动 | 按命名空间标记 |
| 生命周期 | 与 Pod 绑定 | 与节点绑定 |
| L7 功能 | 默认启用 | 按需创建 waypoint |
| 升级影响 | 需要重启 Pod | 透明升级 |
| 兼容性 | 部分应用不兼容 | 更好的兼容性 |

### 20.7.2 Ambient Mesh 部署

```bash
# 安装 Ambient Mesh
istioctl install --set profile=ambient --skip-confirmation

# 标记命名空间加入 Ambient
kubectl label namespace default istio.io/dataplane-mode=ambient

# 验证 ztunnel 运行
kubectl get pods -n istio-system -l app=ztunnel

# 启用 L7 策略（创建 waypoint）
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1beta1
kind: Gateway
metadata:
  name: waypoint
  annotations:
    istio.io/for-service-account: reviews
spec:
  gatewayClassName: istio-waypoint
---
# 应用 L7 策略
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: reviews-policy
spec:
  targetRefs:
  - kind: Gateway
    group: gateway.networking.k8s.io
    name: waypoint
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/default/sa/productpage"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/reviews/*"]
EOF
```

### 20.7.3 多集群网络方案深度对比

| 方案 | 架构 | 延迟 | 复杂度 | 适用场景 |
|------|------|------|--------|----------|
| **Cilium ClusterMesh** | Pod IP 直接路由 | 低 | 中 | 同云/多云 K8s |
| **Submariner** | 基于 IPsec/VXLAN | 中 | 中 | 任意 K8s 集群 |
| **Istio 多集群** | 服务网格层互联 | 中 | 高 | 需要统一流量管理 |
| **Skupper** | 应用层隧道 | 中 | 低 | 跨防火墙/边缘场景 |
| **云厂商互联** | 云骨干网 | 最低 | 低 | 同厂商多区域 |

**Cilium ClusterMesh 部署**：

```bash
# 集群 1：启用 ClusterMesh
cilium clustermesh enable --context cluster1

# 集群 2：启用 ClusterMesh
 cilium clustermesh enable --context cluster2

# 连接两个集群
cilium clustermesh connect \
  --context cluster1 \
  --destination-context cluster2

# 验证
cilium clustermesh status --context cluster1
# 两个集群的 Pod 可以直接用 Pod IP 通信
```

---

## 20.8 eBPF 安全观测与可观测性

### 20.8.1 eBPF 观测工具链

```
┌─────────────────────────────────────────────────────────────┐
│                  eBPF 可观测性工具链                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  网络层        │  Cilium Hubble, kubectl hubble observe      │
│  安全层        │  Falco (eBPF probe), Tetragon               │
│  性能层        │  bpftool, eBPF Exporter, Pixie             │
│  追踪层        │  bpftrace, bcc-tools                        │
│  调试层        │  bpftool prog/map/link                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**bpftool 实用命令**：

```bash
# 查看加载的 eBPF 程序
sudo bpftool prog list

# 查看 eBPF Map
sudo bpftool map list

# 查看程序详情
sudo bpftool prog show id <id>

# 导出程序字节码
sudo bpftool prog dump xlated id <id>

# 查看附着点
sudo bpftool net list
```

**bpftrace 实时监控**：

```bash
# 监控 TCP 连接建立
sudo bpftrace -e '
kprobe:tcp_connect {
  printf("TCP connect: pid=%d comm=%s\n", pid, comm);
}
'

# 监控 DNS 查询
sudo bpftrace -e '
uprobe:/usr/bin/coredns:plugin.(*DNSSEC).Sign {
  printf("DNSSEC sign: %s\n", str(arg1));
}
'

# 监控容器创建（cgroup attach）
sudo bpftrace -e '
tracepoint:cgroup:cgroup_attach_task {
  printf("cgroup attach: pid=%d cgroup=%s\n", args->pid, args->cgroup);
}
'
```

### 20.8.2 Cilium 网络安全观测

```bash
# 实时观察网络流量
kubectl hubble observe --namespace production --follow

# 观察被丢弃的流量
kubectl hubble observe --namespace production --verdict DROPPED

# 观察 HTTP 请求详情
kubectl hubble observe --namespace production --protocol http

# 导出流量拓扑
hubble observe --namespace production --output json | \
  jq -r '{source: .source.identity, destination: .destination.identity, verdict: .verdict}'

# 使用 Hubble UI
kubectl port-forward -n kube-system svc/hubble-ui 8080:80
# 访问 http://localhost:8080 查看实时流量拓扑
```

---

## 20.9 本章练习题

### 选择题

1. **Istio 中负责 xDS 配置分发的组件是什么？**
   - A. Citadel
   - B. Pilot
   - C. Galley
   - D. Envoy

2. **eBPF XDP 挂载点在网络的哪个层次？**
   - A. 应用层
   - B. 传输层
   - C. 网卡驱动层
   - D. 物理层

3. **Cilium ClusterMesh 的核心优势是什么？**
   - A. 配置简单
   - B. Pod IP 跨集群直接路由
   - C. 不需要 etcd
   - D. 支持所有 CNI

4. **Ambient Mesh 相比 Sidecar 模式的主要改进是什么？**
   - A. 功能更丰富
   - B. 降低资源开销
   - C. 配置更简单
   - D. 性能更高

### 简答题

1. 解释 Service Mesh 的核心价值。Sidecar 模式和 Ambient Mesh 模式各有什么优缺点？

2. 描述 eBPF 在内核中的执行流程。为什么 eBPF 比 iptables 更适合大规模 K8s 集群？

3. 对比 Cilium ClusterMesh 和 Submariner 两种多集群方案。各自的适用场景是什么？

4. 设计一个完整的网络故障排查流程。当 Pod A 无法访问 Pod B 时，应该按什么顺序排查？

### 实践题

1. **Istio 流量管理**（30 分钟）：
   - 安装 Istio 并部署示例应用
   - 配置金丝雀发布（80/20 流量分割）
   - 配置熔断和超时
   - 使用 Kiali 观察流量拓扑

2. **Cilium 网络策略**（25 分钟）：
   - 部署测试应用
   - 创建 L7 网络策略（只允许特定 HTTP 方法）
   - 使用 Hubble 观察被阻止的流量
   - 验证策略效果

3. **网络性能基准测试**（20 分钟）：
   - 使用 iperf3 测试 Pod 间带宽
   - 对比同节点和跨节点性能差异
   - 分析 CNI 对性能的影响

---

## 20.9 Service Mesh 选型指南

### 20.9.1 Istio vs Linkerd vs Cilium Service Mesh

| 特性 | Istio | Linkerd | Cilium Mesh |
|------|-------|---------|-------------|
| 数据平面 | Envoy (Sidecar/Ambient) | Linkerd-proxy | eBPF + Envoy |
| 控制平面 | Istiod | Controller | Cilium Agent |
| 资源开销 | 高 (50-100MB/pod) | 低 (10-20MB/pod) | 极低 (内核态) |
| mTLS | ✅ | ✅ | ✅ |
| L7 路由 | ✅ 丰富 | ✅ 基本 | ✅ 丰富 |
| 可观测性 | Kiali + Grafana | Dashboard + Grafana | Hubble |
| 多集群 | ✅ 复杂 | ✅ 简单 | ✅ ClusterMesh |
| 学习曲线 | 陡峭 | 平缓 | 中等 |

**选型建议**：
- **Istio**：需要丰富的流量管理、多集群、企业级支持
- **Linkerd**：追求简单、低资源、快速上手
- **Cilium Mesh**：已使用 Cilium CNI，追求极致性能

### 20.9.2 eBPF 生态工具推荐

| 工具 | 用途 | 场景 |
|------|------|------|
| **bpftrace** | 动态追踪脚本 | 实时诊断、临时排查 |
| **bcc-tools** | 预置 eBPF 工具集 | 性能分析、系统监控 |
| **bpftool** | 程序管理 | 加载、查看、调试 eBPF |
| **pwru** | 网络包追踪 | 网络问题定位 |
| **kubectl-trace** | K8s 节点追踪 | 集群级网络/系统追踪 |
| **Tetragon** | 安全观测 | 运行时威胁检测 |

---

## 20.10 网络可观测性最佳实践

### 20.10.1 黄金信号监控

```yaml
# Service Mesh 黄金信号
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mesh-golden-signals
spec:
  selector:
    matchLabels:
      istio.io/rev: default
  endpoints:
  - port: http-envoy-prom
    path: /stats/prometheus
    metricRelabelings:
    # 延迟
    - sourceLabels: [__name__]
      regex: 'istio_request_duration_milliseconds_bucket'
      targetLabel: __name__
      replacement: 'request_latency_bucket'
    # 错误率
    - sourceLabels: [__name__]
      regex: 'istio_requests_total'
      targetLabel: __name__      
      replacement: 'request_rate'
    # 流量
    - sourceLabels: [__name__]
      regex: 'istio_tcp_sent_bytes_total'
      targetLabel: __name__
      replacement: 'traffic_bytes_sent'
    # 饱和度
    - sourceLabels: [__name__]
      regex: 'istio_proxy_concurrency'
      targetLabel: __name__
      replacement: 'proxy_saturation'
```

### 20.10.2 分布式追踪配置

```yaml
# Istio 分布式追踪
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
spec:
  meshConfig:
    enableTracing: true
    accessLogFile: /dev/stdout
    defaultConfig:
      tracing:
        sampling: 100.0  # 生产环境建议 1-10%
        custom_tags:
          cluster:
            literal:
              value: "production"
          namespace:
            environment:
              name: "NAMESPACE"
```

---

## 20.8 本章小结

| 主题 | 核心要点 |
|------|---------|
| **Service Mesh** | Sidecar/Ambient 架构，mTLS、流量管理、安全策略 |
| **Istio** | 功能最全面的 Service Mesh，xDS 配置分发 |
| **Linkerd** | 轻量级替代，低资源占用 |
| **eBPF** | 内核可编程，XDP/TC/Socket 挂载点 |
| **Cilium** | eBPF 网络，替代 kube-proxy，高性能 |
| **ClusterMesh** | 多集群 Pod 直接通信，身份感知策略 |
| **网络可观测性** | Hubble、Kiali、Grafana 流量可视化 |
| **网络排障** | DNS → Service → Pod → CNI → 跨节点分层排查 |
| **性能测试** | iperf3、netperf，关注带宽/延迟/抖动 |

**推荐阅读**：
- Istio 文档：https://istio.io/latest/docs/
- Cilium 文档：https://docs.cilium.io/
- eBPF 文档：https://ebpf.io/what-is-ebpf/
- K8s 多集群：https://github.com/kubernetes-sigs/kubefed
