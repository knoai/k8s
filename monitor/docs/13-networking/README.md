# 网络知识体系（Network Knowledge Base）

> **从 TCP/IP 基础到 Cilium eBPF，从 Linux 内核到 RDMA 智能网卡。** 这是你补足网络知识缺口的完整路径。

---

## 为什么必须掌握网络？

云原生监控工程师的核心战场在网络：

- **Prometheus 抓取失败** → 是 DNS 问题？Service 规则错误？还是 CNI 丢包？
- **应用超时** → 是 TCP 重传？MTU 问题？还是 NetworkPolicy 拦截？
- **OTel 数据丢失** → 是 conntrack 表满？UDP 不可靠？还是 Sidecar 注入问题？
- **eBPF 监控数据异常** → 是内核版本不兼容？BPF map 溢出？还是程序加载失败？

**不懂网络，就无法真正理解云原生。**

---

## 学习路线

```
L1 初级（Week 1-2）                    L2 中级（Week 3-4）
┌─────────────────────────┐          ┌─────────────────────────┐
│ 01 TCP/IP 协议栈         │    →    │ 03 容器网络原理          │
│   - OSI 七层模型         │          │   - veth/bridge/CNI     │
│   - TCP 三次握手/四次挥手│          │   - Pod 网络生命周期    │
│   - IP 子网与路由       │          │   - 容器间通信场景      │
│   - DNS/HTTP/TLS       │          │                         │
│                         │          │ 04 K8s 网络深入        │
│ 02 Linux 网络栈          │          │   - Service 原理        │
│   - sk_buff 结构        │          │   - kube-proxy 三种模式 │
│   - netfilter/iptables  │          │   - CoreDNS 架构        │
│   - 网络命名空间         │          │   - Ingress 流量入口    │
│   - conntrack           │          │   - 网络排障流程        │
└─────────────────────────┘          └─────────────────────────┘
                                              │
                                              ▼
L3 高级（Week 5-6）                    L4 专家（Week 7+）
┌─────────────────────────┐          ┌─────────────────────────┐
│ 05 CNI 插件深入          │    →    │ 06 高级网络技术          │
│   - Flannel/Calico/Cilium│          │   - BGP 路由协议        │
│   - BGP 模式            │          │   - VXLAN/Overlay      │
│   - eBPF 数据平面       │          │   - DPDK 用户态网络    │
│   - 网络策略实现        │          │   - RDMA/SR-IOV        │
│                         │          │   - 智能网卡/DPU       │
│ 07 网络排障实战          │          │                         │
│   - 分层排查法          │          │ 08 网络可观测性          │
│   - 工具链实战          │          │   - eBPF 监控架构      │
│   - 常见故障根因        │          │   - Hubble 流量可视化  │
│   - 性能测试            │          │   - 网络拓扑/SLO       │
│                         │          │                         │
│ 09 网络安全与零信任      │          │                         │
│   - NetworkPolicy       │          │                         │
│   - Cilium L7 策略      │          │                         │
│   - Istio mTLS          │          │                         │
│   - 流量加密            │          │                         │
└─────────────────────────┘          └─────────────────────────┘
```

---

## 与监控体系的关联

```
网络知识 ←──── 直接影响 ────→ 监控场景

01 TCP/IP    → 理解 Prometheus scrape 超时、TCP 连接泄漏告警
02 Linux     → 理解 node_exporter 网络指标、iptables 规则对采集的影响
03 容器网络  → 理解 cAdvisor 网络统计、Pod 网络隔离对监控的影响
04 K8s 网络  → 理解 ServiceMonitor  Endpoint 发现、CoreDNS 延迟监控
05 CNI 深入  → 理解 Cilium/Calico 指标含义、CNI 选择对性能监控的影响
06 高级网络  → 理解 RDMA 监控、DPDK 场景下的特殊采集方式
07 网络排障  → 监控告警触发后的根因定位流程
08 网络可观测 → 将 Hubble/Cilium 指标接入 Prometheus/Grafana
09 网络安全  → 监控异常流量、审计策略违规
```

---

## 目录结构

| 目录 | 内容 | 难度 |
|------|------|------|
| `01-network-fundamentals/` | TCP/IP、OSI、协议详解 | ⭐⭐ |
| `02-linux-networking/` | Linux 网络栈、netfilter、namespace | ⭐⭐⭐ |
| `03-container-networking/` | veth、bridge、CNI、容器通信 | ⭐⭐⭐ |
| `04-k8s-networking/` | Service、kube-proxy、DNS、Ingress | ⭐⭐⭐ |
| `05-cni-deep-dive/` | Flannel/Calico/Cilium 深入 | ⭐⭐⭐⭐ |
| `06-advanced-networking/` | BGP、VXLAN、DPDK、RDMA、SmartNIC | ⭐⭐⭐⭐⭐ |
| `07-network-troubleshooting/` | 排障方法论、工具链、实战 | ⭐⭐⭐⭐ |
| `08-network-observability/` | eBPF 监控、Hubble、网络 SLO | ⭐⭐⭐⭐ |
| `09-network-security/` | NetworkPolicy、零信任、mTLS | ⭐⭐⭐⭐ |
| `10-harvester-networking/` | Harvester Access/Trunk 模式详解 | ⭐⭐⭐ |

---

## 实践建议

1. **动手实验**：使用 `kind` 或 `minikube` 创建集群，手动创建 veth pair、网桥，理解容器网络
2. **抓包分析**：每个网络问题都配合 `tcpdump` + Wireshark 分析
3. **对比学习**：对比 Flannel/Calico/Cilium 在相同场景下的行为差异
4. **指标关联**：将网络指标与业务指标关联，理解网络对应用的影响
5. **故障注入**：使用 `iptables -A DROP`、断开网桥等模拟网络故障

---

## 面试重点

- TCP 三次握手为什么不是两次？
- TIME_WAIT 和 CLOSE_WAIT 的区别与处理
- kube-proxy iptables vs ipvs 模式的区别
- CNI 插件选型（Flannel vs Calico vs Cilium）
- eBPF 相比 iptables 的优势
- NetworkPolicy 默认行为和实现原理
- VXLAN 封装开销和 MTU 问题
- 容器跨节点通信的几种实现方式
