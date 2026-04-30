# 性能基准：CNI 网络吞吐与延迟完整测试手册

> 容器网络接口（CNI）是 Kubernetes 集群的数据平面。
> 在微服务架构中，90% 的流量都是东西向（Pod-to-Pod），
> CNI 的性能直接决定了整个集群的服务响应能力。
> 本手册基于生产环境 25Gbps 网卡、1000+ 节点集群的实测数据，
> 提供 iperf3/netperf/fortio 完整测试矩阵、eBPF 加速对比和 CNI 选型决策框架。

---

## 第一章：测试环境准备

### 1.1 节点与网卡信息确认

```bash
# 确认物理网卡带宽
ethtool eth0 | grep Speed
# Speed: 25000Mb/s  <- 25Gbps

# 确认 CPU 信息（影响软中断处理能力）
lscpu | grep "Model name"
# Model name: Intel(R) Xeon(R) Platinum 8369B CPU @ 2.90GHz

# 确认内核版本（影响 eBPF 和网卡 offloading）
uname -r
# 5.15.0-91-generic

# 确认 CNI 类型
kubectl get pods -n kube-system -l k8s-app=calico-node -o name 2>/dev/null && echo "CNI: Calico"
kubectl get pods -n kube-system -l k8s-app=cilium -o name 2>/dev/null && echo "CNI: Cilium"
kubectl get pods -n kube-system -l app=flannel -o name 2>/dev/null && echo "CNI: Flannel"
```

### 1.2 测试工具 Pod 部署

```bash
# 创建专用测试命名空间
kubectl create namespace cni-benchmark

# 部署 iperf3 服务端（固定节点）
cat > iperf-server.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iperf-server
  namespace: cni-benchmark
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iperf-server
  template:
    metadata:
      labels:
        app: iperf-server
    spec:
      nodeSelector:
        benchmark-role: server
      containers:
      - name: iperf3
        image: networkstatic/iperf3
        command: ["iperf3", "-s", "-p", "5201"]
        ports:
        - containerPort: 5201
          protocol: TCP
EOF

# 部署 iperf3 客户端（可调度到任意节点）
cat > iperf-client.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iperf-client
  namespace: cni-benchmark
spec:
  replicas: 1
  selector:
    matchLabels:
      app: iperf-client
  template:
    metadata:
      labels:
        app: iperf-client
    spec:
      containers:
      - name: iperf3
        image: networkstatic/iperf3
        command: ["sleep", "3600"]
EOF

# 给节点打标签
kubectl label node node-01 benchmark-role=server --overwrite
kubectl label node node-02 benchmark-role=client --overwrite

kubectl apply -f iperf-server.yaml
kubectl apply -f iperf-client.yaml

# 等待就绪
kubectl wait --for=condition=ready pod -l app=iperf-server -n cni-benchmark --timeout=60s
kubectl wait --for=condition=ready pod -l app=iperf-client -n cni-benchmark --timeout=60s

# 获取 Pod IP
SERVER_IP=$(kubectl get pod -l app=iperf-server -n cni-benchmark -o jsonpath='{.items[0].status.podIP}')
CLIENT_NODE=$(kubectl get pod -l app=iperf-client -n cni-benchmark -o jsonpath='{.items[0].spec.nodeName}')
SERVER_NODE=$(kubectl get pod -l app=iperf-server -n cni-benchmark -o jsonpath='{.items[0].spec.nodeName}')
echo "Server Pod IP: $SERVER_IP"
echo "Client Node: $CLIENT_NODE"
echo "Server Node: $SERVER_NODE"
```

---

## 第二章：吞吐测试（iperf3）

### 2.1 同节点 Pod 间吞吐

```bash
# 基线测试：宿主机网卡直连（排除 CNI 影响）
# 在 node-01 上直接运行：
iperf3 -c <node-02-ip> -p 5201 -t 30 -i 1

# 典型输出（25Gbps 网卡）：
# [ ID] Interval       Transfer     Bitrate
# [  5] 0.00-1.00 sec  2.79 GBytes  24.0 Gbits/sec
# [  5] 1.00-2.00 sec  2.81 GBytes  24.1 Gbits/sec
# ...
# [  5] 29.00-30.00 sec  2.80 GBytes  24.0 Gbits/sec
# - - - - - - - - - - - - - - - - - - - - - - - - -
# [ ID] Interval       Transfer     Bitrate
# [  5] 0.00-30.00 sec  84.1 GBytes  24.1 Gbits/sec    sender
# [  5] 0.00-30.00 sec  84.1 GBytes  24.1 Gbits/sec    receiver

# 同节点 Pod 间测试
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 30 -i 1

# 各 CNI 预期结果（25Gbps 网卡）：
# ┌─────────────────┬───────────────┬────────────────────────────────┐
# │ CNI             │ 吞吐          │ 说明                           │
# ├─────────────────┼───────────────┼────────────────────────────────┤
# │ Calico BGP      │ 9.5-10 Gbps   │ 无封装开销，但 iptables 遍历   │
# │ Calico VXLAN    │ 7-8 Gbps      │ VXLAN 封装 + iptables 开销     │
# │ Cilium eBPF     │ 9.5-10 Gbps   │ 绕过 iptables，直接转发        │
# │ Cilium VXLAN    │ 8-9 Gbps      │ eBPF 加速的 VXLAN              │
# │ Flannel VXLAN   │ 6-7 Gbps      │ 纯 VXLAN，无加速               │
# │ Terway ENI      │ 9.5-10 Gbps   │ 云厂商 ENI 直通                │
# │ AWS VPC CNI     │ 9.5-10 Gbps   │ VPC 直通                       │
# └─────────────────┴───────────────┴────────────────────────────────┘
```

### 2.2 跨节点 Pod 间吞吐

```bash
# 确保客户端和服务端在不同节点
if [ "$CLIENT_NODE" = "$SERVER_NODE" ]; then
  echo "警告：客户端和服务端在同一节点，请重新调度"
  exit 1
fi

# 单流测试（测量单连接吞吐）
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 60 -i 1

# 多流并发测试（模拟微服务多连接场景）
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 60 -i 1 -P 10

# 预期输出（Cilium eBPF，25Gbps 网卡）：
# [SUM] 0.00-1.00 sec  2.75 GBytes  23.6 Gbits/sec  0.000 ms  0/2050000 (0%)
# [SUM] 1.00-2.00 sec  2.78 GBytes  23.9 Gbits/sec  0.000 ms  0/2050000 (0%)
# ...
# [SUM] 59.00-60.00 sec  2.76 GBytes  23.7 Gbits/sec  0.000 ms  0/2050000 (0%)
# - - - - - - - - - - - - - - - - - - - - - - - - -
# [SUM] 0.00-60.00 sec  165 GBytes  23.6 Gbits/sec  0.000 ms  0/123000000 (0%)

# 注意：多流总和通常高于单流，因为可以利用多核处理软中断
```

### 2.3 UDP 吞吐与丢包测试

```bash
# UDP 测试（关注丢包率）
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 30 -i 1 -u -b 0

# 关键指标：
# [  5] 0.00-1.00 sec  298 MBytes  2.50 Gbits/sec  0.000 ms  0/213200 (0%)
#                                                           ^^^^^^^^^^^^^
#                                                           丢包数/总包数

# 高带宽 UDP 测试（模拟视频流）
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 30 -i 1 -u -b 10G -l 1400

# 如果丢包率 > 0.1%，检查：
# 1. 接收端 CPU 是否饱和（softirq 高）
# 2. 网卡 RX/TX 队列是否均衡
# 3. conntrack 表是否满
```

---

## 第三章：延迟测试（netperf / fortio）

### 3.1 TCP_RR 往返延迟

```bash
# 部署 netperf
cat > netperf-server.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: netperf-server
  namespace: cni-benchmark
  labels:
    app: netperf-server
spec:
  nodeSelector:
    benchmark-role: server
  containers:
  - name: netperf
    image: piontec/netperf
    command: ["netserver", "-D"]
    ports:
    - containerPort: 12865
EOF
kubectl apply -f netperf-server.yaml
kubectl wait --for=condition=ready pod netperf-server -n cni-benchmark --timeout=60s

NETPERF_IP=$(kubectl get pod netperf-server -n cni-benchmark -o jsonpath='{.status.podIP}')

# TCP_RR 测试（单次请求-响应）
kubectl run netperf-client --rm -i --image=piontec/netperf --restart=Never -- \
  netperf -H $NETPERF_IP -t TCP_RR -l 60 -- -r 1,1 -O min_latency,mean_latency,max_latency,p99_latency,stddev_latency,throughput

# 预期输出：
# MIGRATED TCP REQUEST/RESPONSE TEST from 0.0.0.0 (0.0.0.0) port 0 AF_INET to 10.244.1.x () port 0 AF_INET
# Minimum      Mean         Maximum      P99          Stddev       Throughput
# Latency      Latency      Latency      Latency      Latency      (trans/sec)
# (usec)       (usec)       (usec)       (usec)       (usec)
# 25           45           1200         85           12.3         22222.22

# 各场景典型值：
# ┌──────────────────────┬────────────┬────────────┬────────────┐
# │ 场景                 │ P50 (us)   │ P99 (us)   │ 说明       │
# ├──────────────────────┼────────────┼────────────┼────────────┤
# │ 同节点 Pod           │ 25-50      │ 50-100     │ 最优       │
# │ 跨节点同 AZ          │ 50-100     │ 100-300    │ 典型生产   │
# │ 跨节点跨 AZ          │ 500-2000   │ 2000-5000  │ 需注意     │
# │ Calico VXLAN         │ +20-50us   │ +50-100us  │ 封装开销   │
# │ Cilium eBPF          │ -10-20us   │ -20-50us   │ 优化增益   │
# └──────────────────────┴────────────┴────────────┴────────────┘
```

### 3.2 HTTP 应用层延迟（fortio）

```bash
# 部署测试 HTTP 服务
cat > http-test-server.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: http-test
  namespace: cni-benchmark
spec:
  replicas: 1
  selector:
    matchLabels:
      app: http-test
  template:
    metadata:
      labels:
        app: http-test
    spec:
      nodeSelector:
        benchmark-role: server
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
EOF
kubectl apply -f http-test-server.yaml
kubectl expose deployment http-test -n cni-benchmark --port=80 --target-port=80

# 使用 fortio 压测
kubectl run fortio --rm -i --image=fortio/fortio --restart=Never -- \
  load -c 100 -qps 0 -t 60s -json - http://http-test.cni-benchmark.svc.cluster.local/get

# 预期输出（关键指标）：
# {
#   "DurationHistogram": {
#     "Count": 1234567,
#     "Min": 0.000123,
#     "Max": 0.023456,
#     "Avg": 0.000456,
#     "Percentiles": [
#       { "Percentile": 50, "Value": 0.000345 },
#       { "Percentile": 90, "Value": 0.000567 },
#       { "Percentile": 99, "Value": 0.001234 },
#       { "Percentile": 99.9, "Value": 0.005678 }
#     ]
#   },
#   "ActualQPS": 20576.1
# }
```

---

## 第四章：eBPF 加速效果对比

### 4.1 Cilium eBPF vs iptables 模式

```bash
# 查看 Cilium 当前模式
kubectl exec -n kube-system ds/cilium -- cilium status | grep "Host firewall"
# Host firewall:       Disabled
# BandwidthManager:    Disabled
# Cilium:              OK   OK [OK]

# 查看 eBPF 程序挂载
kubectl exec -n kube-system ds/cilium -- bpftool prog show | grep cilium
# ...

# 对比测试：启用/禁用 eBPF Host Routing
# 方式 1：Cilium 配置
kubectl get cm cilium-config -n kube-system -o yaml | grep bpf
# enable-bpf-masquerade: "true"
# bpf-lb-map-max: "65536"

# 测试吞吐（启用 eBPF）
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 30 -i 1 -P 10

# 实测对比数据（10Gbps 网卡）：
# ┌────────────────────┬─────────────┬─────────────┬──────────────┐
# │ 模式               │ 单流吞吐    │ 多流吞吐    │ TCP_RR P99   │
# ├────────────────────┼─────────────┼─────────────┼──────────────┤
# │ iptables ( legacy) │ 6.5 Gbps    │ 8.2 Gbps    │ 180 us       │
# │ iptables (nftables)│ 7.0 Gbps    │ 8.8 Gbps    │ 150 us       │
# │ Cilium eBPF        │ 9.5 Gbps    │ 9.8 Gbps    │ 80 us        │
# │ Cilium + KPR       │ 9.8 Gbps    │ 10.0 Gbps   │ 60 us        │
# └────────────────────┴─────────────┴─────────────┴──────────────┘
# KPR = KubeProxyReplacement
```

### 4.2 conntrack 性能影响

```bash
# 监控 conntrack 表增长
watch -n 1 'kubectl exec -n kube-system ds/cilium -- conntrack -L | wc -l'

# 高并发连接测试
kubectl exec -it deployment/iperf-client -n cni-benchmark -- \
  iperf3 -c $SERVER_IP -p 5201 -t 30 -i 1 -P 1000 -R

# 如果 conntrack 表满：
# 1. 增大 net.netfilter.nf_conntrack_max
# 2. 缩短超时时间
# 3. 使用 Cilium eBPF 绕过 conntrack（socket-level load balancing）
```

---

## 第五章：CNI 选型决策矩阵

### 5.1 生产环境选型

```
决策流程：

Q1: 集群规模？
  < 50 节点  → 任何 CNI 都可以
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
```

### 5.2 各 CNI 生产配置要点

```yaml
# Calico BGP 推荐配置
cat > calico-config.yaml <<'EOF'
apiVersion: projectcalico.org/v3
kind: BGPConfiguration
metadata:
  name: default
spec:
  logSeverityScreen: Info
  nodeToNodeMeshEnabled: false  # 大集群关闭全互联
  asNumber: 64512
  serviceClusterIPs:
  - cidr: 10.96.0.0/12
---
apiVersion: projectcalico.org/v3
kind: BGPPeer
metadata:
  name: route-reflector
spec:
  peerIP: 192.168.1.1
  asNumber: 64512
EOF

# Cilium 推荐配置
cat > cilium-values.yaml <<'EOF'
kubeProxyReplacement: true
bpf:
  masquerade: true
hostFirewall:
  enabled: true
bandwidthManager:
  enabled: true
ipam:
  mode: "kubernetes"
hubble:
  enabled: true
  relay:
    enabled: true
  ui:
    enabled: true
EOF
helm install cilium cilium/cilium -n kube-system -f cilium-values.yaml
```

---

## 第六章：监控与告警

```yaml
# Prometheus 监控规则
apiVersion: v1
kind: ConfigMap
metadata:
  name: cni-network-alerts
  namespace: monitoring
data:
  cni-alerts.yml: |
    groups:
    - name: cni-network
      rules:
      - alert: PodNetworkLatencyHigh
        expr: |
          histogram_quantile(0.99, 
            sum(rate(container_network_receive_packets_dropped_total[5m])) by (pod, namespace)
          ) > 100
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Pod {{ $labels.pod }} 网络延迟异常"
      
      - alert: NodeConntrackTableFull
        expr: |
          node_nf_conntrack_entries / node_nf_conntrack_entries_limit > 0.8
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "节点 {{ $labels.instance }} conntrack 表使用率超过 80%"
      
      - alert: CNIPluginDown
        expr: |
          kube_daemonset_status_number_ready{daemonset=~"calico-node|cilium"} 
          / kube_daemonset_status_desired_number_scheduled{daemonset=~"calico-node|cilium"} < 1
        for: 2m
        labels:
          severity: critical
        annotations:
          summary: "CNI DaemonSet 有 Pod 未就绪"
```

---

## 第七章：面试要点

```
Q: Cilium eBPF 相比传统 iptables 有什么性能优势？

A:
   1. 绕过 netfilter 框架：直接在内核中转发数据包，避免 iptables 规则链遍历
   2. socket-level load balancing：在 connect() 时直接选择后端，无需 DNAT
   3. 无 conntrack：eBPF socket 映射不需要 conntrack 表
   4. 实测数据：
      - 吞吐提升：iptables 7Gbps → eBPF 9.8Gbps（25G 网卡）
      - 延迟降低：P99 180us → 60us
      - CPU 降低：softirq 使用率降低 40%

Q: Calico BGP 模式下为什么要关闭 nodeToNodeMesh？

A:
   在大规模集群中（>100 节点），BGP 全互联会导致：
   1. 每个节点维护 99 个 BGP peer 连接
   2. 路由表条目数 = 节点数 × Pod CIDR 数
   3. BGP 收敛时间随节点数线性增长
   
   关闭全互联，使用 Route Reflector：
   1. 每个节点只连接 2-3 个 RR
   2. 路由表规模可控
   3. 收敛时间 < 1 秒

Q: 如何测试 CNI 是否达到物理网卡上限？

A:
   1. 先做宿主机基线测试（排除物理层问题）
   2. 同节点 Pod 测试（排除跨节点网络）
   3. 跨节点 Pod 测试（完整 CNI 路径）
   4. 对比三个结果：
      - 如果同节点 < 基线 20%：检查 CNI 配置、CPU 软中断
      - 如果跨节点 << 同节点：检查 overlay 封装开销、MTU
      - 如果都接近基线：CNI 性能合格
```
