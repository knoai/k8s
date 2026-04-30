# eBPF 可观测性进阶

## 1. eBPF 概述

eBPF（Extended Berkeley Packet Filter）是一项允许在 Linux 内核中安全运行沙箱程序的技术。它使非内核开发人员也能对内核行为进行观测和控制，无需修改内核源码或加载内核模块。

### 1.1 为什么 eBPF 适合云原生监控

| 传统方式 | eBPF 方式 |
|----------|-----------|
| 需要修改应用代码埋点 | 零代码修改，内核级采集 |
| Sidecar 代理增加延迟 | 直接在内核执行，性能开销极低 |
| 无法观测加密流量 | 在加密前/后捕获，支持 mTLS 流量分析 |
| 只能看到应用层 | 覆盖系统调用、网络、文件系统等全栈 |

### 1.2 eBPF 工作原理

```
User Space                    Kernel Space
┌─────────────┐              ┌─────────────────────────┐
│  eBPF Tool  │─────────────▶│   eBPF Verifier         │
│  (bpftool)  │  加载程序     │   (安全检查)            │
└─────────────┘              └─────────────────────────┘
                                       │
                              ┌────────▼────────┐
                              │  JIT Compiler   │
                              │  (编译为机器码)  │
                              └────────┬────────┘
                                       │
                              ┌────────▼────────┐
                              │  Hook Points    │
                              │  kprobe/tracepoint│
                              │  socket/xdp     │
                              └────────┬────────┘
                                       │
                              ┌────────▼────────┐
                              │  Maps (KV Store)│
                              │  (用户空间通信)  │
                              └─────────────────┘
```

---

## 2. eBPF 在 K8s 监控中的应用

### 2.1 网络可观测性

| 能力 | 说明 |
|------|------|
| **流量捕获** | L3-L7 协议解析（HTTP、gRPC、DNS、MySQL、Redis） |
| **服务拓扑** | 自动绘制服务间调用关系 |
| **网络质量** | TCP 重传、丢包、延迟、连接状态 |
| **策略审计** | 验证 NetworkPolicy 是否生效 |

### 2.2 安全与审计

| 能力 | 说明 |
|------|------|
| **系统调用追踪** | execve、connect、open 等敏感调用 |
| **进程行为** | 检测异常进程启动、权限提升 |
| **文件监控** | 追踪敏感文件访问 |

### 2.3 性能剖析

| 能力 | 说明 |
|------|------|
| **CPU 火焰图** | On-CPU / Off-CPU 性能分析 |
| **内存分析** | 内存分配追踪、泄漏检测 |
| **阻塞分析** | 锁竞争、I/O 阻塞定位 |

---

## 3. eBPF 工具生态

### 3.1 Cilium + Hubble

Cilium 是基于 eBPF 的 Kubernetes CNI，Hubble 是其可观测组件。

```bash
# 安装 Cilium + Hubble
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}"

# 访问 Hubble UI
cilium hubble ui
```

**Hubble 核心能力**：
- 实时流量监控（L3-L7）
- 服务依赖拓扑图
- 网络策略审计（放行/拒绝）
- DNS 查询监控
- HTTP/gRPC 指标采集

### 3.2 Pixie

Pixie 是由 New Relic 开源的 Kubernetes 可观测平台，完全基于 eBPF。

| 特性 | 说明 |
|------|------|
| 协议支持 | HTTP/1, HTTP/2, gRPC, DNS, Kafka, MySQL, PostgreSQL, Redis, Cassandra |
| 性能剖析 | CPU 火焰图、内存分析 |
| 数据保留 | 内存中短期存储（默认 24h） |
| 部署 | Pixie CLI 或 Operator |

```bash
# 安装 Pixie
px deploy

# 查看服务性能
px scripts list
px run px/http_data
px run px/service_stats
```

### 3.3 DeepFlow

DeepFlow 是云杉网络开源的 eBPF 可观测平台，专为云原生设计。

| 特性 | 说明 |
|------|------|
| Universal Map | 自动绘制全栈拓扑 |
| Continuous Profiling | 持续性能剖析 |
| Distributed Tracing | 非侵入全链路追踪 |
| 集成 | 与 Prometheus、SkyWalking 等生态对接 |

### 3.4 Tetragon

Tetragon 是 Cilium 团队开源的 eBPF 安全观测工具。

```bash
# 安装 Tetragon
helm repo add cilium https://helm.cilium.io/
helm install tetragon cilium/tetragon -n kube-system

# 查看安全事件
kubectl exec -it -n kube-system ds/tetragon \
  -c tetragon -- tetra getevents
```

**Tetragon 能力**：
- 进程执行监控
- 文件访问监控
- 网络连接监控
- Kubernetes 感知（Pod/Namespace 关联）

### 3.5 bpftrace

bpftrace 是高级 eBPF 追踪语言，类似 awk，适合临时排查。

```bash
# 统计系统调用次数
bpftrace -e 'tracepoint:raw_syscalls:sys_enter { @[comm] = count(); }'

# 追踪 TCP 连接建立
bpftrace -e 'kprobe:tcp_v4_connect { printf("%s -> %s\n", comm, ntop(AF_INET, arg1)); }'

# 查看文件打开
bpftrace -e 'tracepoint:syscalls:sys_enter_openat { printf("%s: %s\n", comm, str(args->filename)); }'
```

---

## 4. eBPF 网络可观测实战

### 4.1 Hubble 流量查询

```bash
# 查看实时流量
hubble observe -f

# 过滤特定命名空间
hubble observe --namespace production -f

# 查看被策略拒绝的流量
hubble observe --verdict DROPPED -f

# 查看 HTTP 流量详情
hubble observe --protocol http -f

# 查看两个服务间流量
hubble observe --from-pod frontend --to-pod backend
```

### 4.2 PromQL 查询 Hubble 指标

```promql
# HTTP 请求率
sum(rate(hubble_http_requests_total[5m])) by (source, destination)

# TCP 连接数
hubble_tcp_opening_total

# DNS 查询量
sum(rate(hubble_dns_queries_total[5m])) by (query)

# 被丢弃的流量
sum(rate(hubble_flows_processed_total{verdict="DROPPED"}[5m]))

# 流量方向统计
sum(rate(hubble_flows_processed_total[5m])) by (traffic_direction)
```

### 4.3 网络延迟归因

一个典型的微服务调用延迟分解：

```
总延迟 150ms
├── frontend → gateway: 20ms
│   ├── DNS 解析: 2ms
│   ├── TCP 握手: 5ms
│   ├── TLS 协商: 8ms
│   └── 请求处理: 5ms
├── gateway → order-svc: 80ms
│   ├── 路由+鉴权: 15ms
│   └── DB 查询: 60ms
│       └── SQL 执行: 60ms
└── order-svc → inventory: 40ms
    └── 库存检查: 30ms
```

eBPF 可以在内核层面测量每一段网络延迟，无需应用埋点。

---

## 5. eBPF 部署条件与限制

### 5.1 系统要求

| 要求 | 最低版本 | 推荐版本 |
|------|----------|----------|
| Linux 内核 | 4.10 | 5.4+ |
| 内核配置 | CONFIG_BPF=y | CONFIG_BPF=y, CONFIG_BPF_SYSCALL=y |
| 容器运行时 | Docker/containerd/CRI-O | containerd |

### 5.2 检查系统支持

```bash
# 检查内核版本
uname -r

# 检查 BPF 配置
zcat /proc/config.gz | grep -i bpf
# 或
grep -i bpf /boot/config-$(uname -r)

# 检查 bpftool
bpftool feature probe
```

### 5.3 已知限制

| 限制 | 说明 |
|------|------|
| 内核版本依赖 | 不同内核版本 eBPF 能力不同 |
| 指令限制 | eBPF 程序最多 100 万条指令 |
| 栈空间限制 | 512 字节栈空间 |
| 循环限制 | 需验证器确认有界循环 |
| 加密流量 | 应用层加密（如应用内 TLS）难以解析 |

---

## 6. 选型建议

| 场景 | 推荐工具 |
|------|----------|
| Kubernetes 网络监控 + 策略 | Cilium + Hubble |
| 全栈可观测（网络+应用+性能） | Pixie |
| 生产级全链路追踪 + 深度分析 | DeepFlow |
| 安全事件监控 | Tetragon / Falco |
| 临时故障排查 | bpftrace |
| 持续性能剖析 | Parca / Pyroscope |

---

## 参考资源

- [Cilium 官方文档](https://docs.cilium.io/)
- [Hubble 文档](https://docs.cilium.io/en/stable/observability/hubble/)
- [Pixie 文档](https://docs.px.dev/)
- [DeepFlow 文档](https://deepflow.io/docs/zh/)
- [Tetragon 文档](https://tetragon.io/)
- [bpftrace 参考指南](https://github.com/iovisor/bpftrace/blob/master/docs/reference_guide.md)
- [Liz Rice - Learning eBPF (O'Reilly, 2023)](https://www.oreilly.com/library/view/learning-ebpf/9781098135119/)
- [Brendan Gregg - BPF Performance Tools](https://www.brendangregg.com/bpf-performance-tools-book.html)
