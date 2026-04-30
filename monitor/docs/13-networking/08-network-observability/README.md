# 网络可观测性

> 网络层面的可观测性是云原生监控的关键组成部分。从传统工具到 eBPF 革命，从流量指标到安全审计，构建全面的网络可见性。

---

## 1. 网络可观测性维度

```
网络可观测性三大支柱：

┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   Metrics（指标）           Logs（日志）          Traces（链路）│
│   ─────────────────        ────────────         ────────────│
│                                                             │
│   - 带宽利用率               - 连接建立/断开        - 请求路径  │
│   - 包速率                   - 异常事件            - 延迟分解  │
│   - 错误率 (丢包/重传)       - 安全事件            - 服务依赖  │
│   - TCP 连接数               - DNS 查询            - 瓶颈定位  │
│   - 延迟 (RTT)               - NAT 转换            - 异常定位  │
│                                                             │
│   采集方式：                  采集方式：            采集方式：  │
│   - node_exporter            - tcpdump/tshark      - OpenTelemetry│
│   - cAdvisor                  - conntrack          - Envoy Access Log│
│   - Cilium/Hubble metrics    - eBPF 流日志         - eBPF-based tracing│
│   - NIC 计数器               - 系统日志            - Istio telemetry  │
│                                                             │
└─────────────────────────────────────────────────────────────┘

第四维度：Flows（流）
  - 五元组：源IP、目的IP、源端口、目的端口、协议
  - 字节数、包数、方向
  - Cilium Hubble、NetFlow、sFlow
```

---

## 2. 传统网络监控工具

### 2.1 基于 SNMP/网卡计数器

```bash
# ========== node_exporter 网络指标 ==========
# 网卡收发统计
node_network_receive_bytes_total{device="eth0"}
node_network_transmit_bytes_total{device="eth0"}
node_network_receive_packets_total{device="eth0"}
node_network_receive_errs_total{device="eth0"}
node_network_receive_drop_total{device="eth0"}

# PromQL: 网卡带宽
rate(node_network_receive_bytes_total{device="eth0"}[1m]) * 8

# PromQL: 丢包率
rate(node_network_receive_drop_total[1m]) / rate(node_network_receive_packets_total[1m])

# ========== ethtool ==========
# 查看网卡高级统计
ethtool -S eth0
ethtool -i eth0     # 驱动信息

# 查看 Ring Buffer
ethtool -g eth0
ethtool -G eth0 rx 4096 tx 4096  # 调整

# 查看/设置 offload
ethtool -k eth0     # 当前 offload 状态
ethtool -K eth0 tso on gso on gro on  # 启用

# ========== ss / netstat ==========
# 连接统计（可用于监控连接数）
ss -tan | awk '{print $1}' | sort | uniq -c

# TCP 内存使用
cat /proc/net/sockstat
```

### 2.2 基于 sFlow/NetFlow

```
sFlow/NetFlow 是传统网络流量采样技术：

┌─────────────────────────────────────────────────────────────┐
│                         Router/Switch                        │
│                           │                                  │
│                    采样 N 分之一流量                          │
│                           │                                  │
│                           ▼                                  │
│                    sFlow/NetFlow Collector                   │
│                           │                                  │
│                           ▼                                  │
│                    Prometheus/Grafana                        │
└─────────────────────────────────────────────────────────────┘

K8s 中的实现：
  - goflow/goflow2: NetFlow/sFlow/IPFIX 收集器
  - 结合 CNI 出口镜像（SPAN/RSPAN）
```

---

## 3. eBPF 网络可观测性

### 3.1 eBPF 在网络监控中的优势

```
传统方式 vs eBPF：

传统方式：                      eBPF：
- tcpdump 全量抓包             - 内核态过滤，只采集需要的
- 用户态处理，上下文切换开销     - 内核态处理，无上下文切换
- 无法关联 K8s 元数据           - 原生关联 Pod、Service、Namespace
- 难以聚合统计                  - 内核 map 高效聚合
- 侵入性（需进入容器）           - 无侵入，宿主机上即可观测所有 Pod

┌─────────────────────────────────────────────────────────────┐
│                    eBPF 网络观测架构                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  User Space                                                  │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              eBPF Agent (Cilium/Pixie)               │   │
│  │                                                      │   │
│  │  - 加载 eBPF 程序到内核                                │   │
│  │  - 读取 BPF map 中的聚合数据                            │   │
│  │  - 关联 K8s 元数据（Pod 名、标签、Namespace）           │   │
│  │  - 暴露 Prometheus 指标                                │   │
│  │  - 发送到 Hubble/Pixie UI                              │   │
│  └──────────────────────────────────────────────────────┘   │
│                          │                                   │
│              ┌───────────┴───────────┐                       │
│              │ BPF map / perf buffer │                       │
│              └───────────┬───────────┘                       │
│                          │                                   │
│  Kernel Space            ▼                                   │
│  ┌──────────────────────────────────────────────────────┐   │
│  │              eBPF Programs                           │   │
│  │                                                      │   │
│  │  kprobe/tracepoint:   系统调用入口/出口               │   │
│  │  kretprobe:           系统调用返回值                   │   │
│  │  tracepoint:          内核预定义跟踪点                 │   │
│  │  fentry/fexit:        函数入口/出口（BTF）            │   │
│  │  TC classifier:       网络包分类（ingress/egress）     │   │
│  │  XDP:                 网卡驱动层处理                   │   │
│  │  socket filter:       socket 层过滤                   │   │
│  │  cgroup/skb:          cgroup 网络控制                 │   │
│  │  sockops:             socket 操作                     │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 3.2 Hubble（Cilium 可观测性）

```
Hubble = Cilium 的可见性层

┌─────────────────────────────────────────────────────────────┐
│                      Hubble 架构                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  ┌─────────────────┐      ┌─────────────────────────────┐   │
│  │   Hubble UI     │      │     Hubble Relay            │   │
│  │   (Web UI)      │◄────►│     (gRPC 聚合)              │   │
│  │                 │      │                             │   │
│  │  - 服务拓扑      │      │  收集所有节点 Hubble Server  │   │
│  │  - 流日志        │      │  提供统一查询接口             │   │
│  │  - 策略可视化    │      └─────────────┬───────────────┘   │
│  └─────────────────┘                    │                   │
│                                         │ gRPC              │
│       ┌─────────────────────────────────┼─────────────────┐ │
│       │                                 │                 │ │
│  ┌────▼────┐  ┌────▼────┐  ┌────▼────┐  │  ┌────▼────┐   │ │
│  │ Cilium  │  │ Cilium  │  │ Cilium  │  │  │ Cilium  │   │ │
│  │ Agent   │  │ Agent   │  │ Agent   │  │  │ Agent   │   │ │
│  │+ Hubble │  │+ Hubble │  │+ Hubble │  │  │+ Hubble │   │ │
│  │ Server  │  │ Server  │  │ Server  │  │  │ Server  │   │ │
│  └────┬────┘  └────┬────┘  └────┬────┘  │  └────┬────┘   │ │
│       │            │            │       │       │        │ │
│  ┌────▼────────────▼────────────▼───────┼───────▼────┐   │ │
│  │           eBPF Data Plane            │            │   │ │
│  │  - Flow 采集                          │            │   │ │
│  │  - Drop 原因                          │            │   │ │
│  │  - L7 解析 (HTTP/DNS/Kafka)           │            │   │ │
│  └──────────────────────────────────────┘            │   │ │
│                                                      │   │ │
└──────────────────────────────────────────────────────┘   │ │
                                                           │ │
Prometheus ◄───────────────────────────────────────────────┘ │
  - hubble_flows_processed_total                            │
  - hubble_drop_total                                        │
  - hubble_tcp_flags_total                                   │
  - hubble_http_requests_total                               │
```

### 3.3 Hubble 实战

```bash
# 启用 Hubble
helm upgrade cilium cilium/cilium --namespace kube-system \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set hubble.metrics.enabled="{dns,drop,tcp,flow,icmp,http}"

# 查看流（实时）
hubble observe --server localhost:4245
hubble observe --namespace default --follow

# 查看特定 Pod 的流量
hubble observe --pod my-pod --namespace default

# 查看丢包
hubble observe --type drop

# 查看 HTTP 流量
hubble observe --protocol http

# 查看服务依赖拓扑
hubble observe --server localhost:4245 --print-node-ip | \
  awk '{print $3, $5}' | sort | uniq -c | sort -rn

# Hubble 指标
kubectl port-forward -n kube-system svc/hubble-metrics 9965:9965
curl localhost:9965/metrics | grep hubble_
```

### 3.4 eBPF 指标与 Prometheus

```yaml
# Cilium 的 Prometheus ServiceMonitor
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
      metricRelabelings:
        # 只保留关键指标
        - sourceLabels: [__name__]
          regex: 'cilium_(node_connectivity|drop|forward|policy|endpoint)_.*'
          action: keep
```

**关键 Cilium/Hubble 指标：**

| 指标 | 说明 |
|------|------|
| `hubble_flows_processed_total` | 处理的流总数 |
| `hubble_drop_total` | 丢包统计（按原因分类） |
| `hubble_tcp_flags_total` | TCP 标志统计 |
| `cilium_drop_total` | Cilium 丢包（策略拒绝等） |
| `cilium_forward_fib_lookup_total` | FIB 查找统计 |
| `cilium_policy_l7_total` | L7 策略处理 |

---

## 4. 服务网格网络可观测性

### 4.1 Istio 网络指标

```
Istio 通过 Envoy sidecar 生成丰富的网络指标：

┌─────────────────────────────────────────────────────────────┐
│                      Istio 指标体系                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  标准指标 (istio_*)：                                        │
│  ─────────────────                                          │
│  istio_requests_total              # 请求总数               │
│    标签: reporter, source_workload, destination_workload,   │
│          response_code, request_protocol, ...               │
│                                                             │
│  istio_request_duration_seconds    # 请求延迟               │
│    标签: reporter, source_workload, destination_workload    │
│                                                             │
│  istio_request_bytes_sum           # 请求字节数             │
│  istio_response_bytes_sum          # 响应字节数             │
│                                                             │
│  istio_tcp_sent_bytes_total        # TCP 发送字节           │
│  istio_tcp_received_bytes_total    # TCP 接收字节           │
│  istio_tcp_connections_opened_total # TCP 连接建立           │
│  istio_tcp_connections_closed_total # TCP 连接关闭           │
│                                                             │
│  推导出的黄金指标：                                           │
│  ─────────────────────                                       │
│  流量 = sum(rate(istio_requests_total[1m]))                 │
│  错误率 = rate(istio_requests_total{response_code=~"5.."}[1m]) / rate(istio_requests_total[1m]) │
│  延迟 = histogram_quantile(0.99, rate(istio_request_duration_seconds_bucket[1m])) │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 4.2 Envoy 访问日志

```yaml
# Envoy 访问日志格式
accessLogFormat: |
  [%START_TIME%] "%REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% %PROTOCOL%"
  %RESPONSE_CODE% %RESPONSE_FLAGS% %BYTES_RECEIVED% %BYTES_SENT%
  %DURATION% %RESP(X-ENVOY-UPSTREAM-SERVICE-TIME)%
  "%REQ(X-FORWARDED-FOR)%" "%REQ(USER-AGENT)%"
  "%REQ(X-REQUEST-ID)%" "%REQ(:AUTHORITY)%"
  "%UPSTREAM_HOST%" %UPSTREAM_CLUSTER%
  %UPSTREAM_LOCAL_ADDRESS% %DOWNSTREAM_LOCAL_ADDRESS%
  %DOWNSTREAM_REMOTE_ADDRESS% %REQUESTED_SERVER_NAME%

# RESPONSE_FLAGS 关键值：
# - UF: Upstream connection failure
# - UO: Upstream overflow (circuit breaker)
# - NR: No route configured
# - UH: No healthy upstream
# - LH: Local service healthy panic
# - RL: Rate limited
```

---

## 5. 网络告警规则

```yaml
# network-alerts.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: network-alerts
  namespace: monitoring
spec:
  groups:
    - name: network
      rules:
        # 高丢包率
        - alert: NetworkHighDropRate
          expr: |
            rate(node_network_receive_drop_total[5m]) 
            / rate(node_network_receive_packets_total[5m]) > 0.01
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High network drop rate on {{ $labels.device }}"
            description: "Drop rate is {{ $value | humanizePercentage }}"

        # TCP 重传率高
        - alert: TCPHighRetransmitRate
          expr: |
            rate(node_network_transmit_errs_total[5m])
            / rate(node_network_transmit_packets_total[5m]) > 0.05
          for: 5m
          labels:
            severity: warning

        # conntrack 表即将满
        - alert: ConntrackTableNearingCapacity
          expr: |
            node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
          for: 5m
          labels:
            severity: critical

        # Cilium 丢包
        - alert: CiliumHighDropRate
          expr: |
            rate(cilium_drop_total[5m]) > 10
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High packet drop in Cilium"
            description: "Reason: {{ $labels.reason }}"

        # Hubble 发现丢包
        - alert: HubblePacketDrops
          expr: |
            rate(hubble_drop_total[5m]) > 1
          for: 5m
          labels:
            severity: warning

        # DNS 查询失败
        - alert: DNSQueryFailures
          expr: |
            rate(coredns_dns_responses_total{rcode="SERVFAIL"}[5m]) > 1
          for: 5m
          labels:
            severity: warning
```

---

## 6. 网络可观测性实践

### 6.1 网络拓扑可视化

```
工具选择：

1. Hubble UI (Cilium)
   - 实时服务拓扑
   - 显示流量方向、协议、端口
   - 集成策略可视化

2. Kiali (Istio)
   - 服务网格拓扑
   - 显示 mTLS 状态
   - 流量动画、健康状态

3. Weave Scope
   - 通用容器网络拓扑
   - 交互式探索
   - 较少维护

4. 自定义 Grafana Dashboard
   - 基于 Prometheus 指标
   - 灵活定制
```

### 6.2 网络延迟监控

```bash
# 使用 smokeping 或类似工具持续监控延迟
# PromQL: 节点间网络延迟（通过 blackbox_exporter）

# blackbox_exporter probe
probe_duration_seconds{job="blackbox-tcp"}
probe_success{job="blackbox-tcp"}

# 或使用 eBPF 测量的 TCP RTT
cilium_tcp_connection_duration_seconds_bucket
```

### 6.3 网络 SLO 定义

```
网络层面 SLO 示例：

延迟：
  - Pod 到 Service 的 P99 延迟 < 5ms（同可用区）
  - 跨可用区延迟 < 20ms

可用性：
  - 网络连通性 > 99.99%
  - DNS 解析成功率 > 99.9%

带宽：
  - 节点间带宽利用率 < 70%
  - 无持续拥塞丢包

错误：
  - TCP 重传率 < 0.1%
  - 包丢弃率 < 0.01%
```

---

## 参考资源

- [Cilium Hubble Documentation](https://docs.cilium.io/en/stable/observability/hubble/)
- [eBPF for Monitoring](https://ebpf.io/what-is-ebpf/)
- [Istio Telemetry](https://istio.io/latest/docs/tasks/observability/)
- [Hubble Grafana Dashboards](https://github.com/cilium/hubble/tree/main/contrib/grafana)
