# 生产排障：CNI 网络丢包与延迟

> 容器网络问题是 K8s 排障中最棘手的领域之一。本节提供系统化的诊断方法和常见根因的完整修复流程。

---

## 真实故障场景

### 场景 A：跨节点 Pod 通信间歇性超时

```
开发者: "我们的服务 A 调用服务 B，大概 5% 的请求会超时"
运维: "服务 A 和 B 在同一个集群吗？"
开发者: "是的，但似乎不在同一个节点上时会出问题"

排查发现：
- 同节点 Pod 通信：100% 成功
- 跨节点 Pod 通信：95% 成功，5% 超时
```

### 场景 B：DNS 解析慢导致应用启动失败

```
应用日志：
[ERROR] 2024-01-15 08:23:45 - Failed to connect to database: 
  java.net.UnknownHostException: mysql.production.svc.cluster.local

实际上 DNS 能解析，但耗时 10-15 秒，超过连接超时时间
```

---

## 症状分类与快速定位

| 症状 | 可能根因 | 优先排查命令 |
|------|---------|-----------|
| Pod 间通信间歇性超时 | CNI 插件故障 / conntrack 满 | `conntrack -L \| wc -l` |
| 跨节点通信延迟高 | VXLAN 封装开销 / 网络策略误配 | `ip route` + `tcpdump` |
| DNS 解析慢或失败 | CoreDNS 性能 / NodeLocal DNSCache | `dig +stats` |
| Service 访问不通 | kube-proxy 模式 / Endpoint 未更新 | `iptables -t nat -L` |
| 新建连接大量失败 | SNAT 端口耗尽 | `ss -s` |
| 特定节点网络异常 | 网卡故障 / CNI 二进制损坏 | `ethtool` + `ip link` |

---

## 诊断工具链：完整操作手册

### netshoot 排障 Pod

```bash
# 启动排障 Pod
kubectl run netshoot --rm -i --tty --image nicolaka/netshoot -- /bin/bash

# ==================== 基础连通性测试 ====================

# Ping 测试（ICMP）
ping -c 10 <target-pod-ip>

# 预期输出（健康）：
# PING 10.244.1.5 (10.244.1.5) 56(84) bytes of data.
# 64 bytes from 10.244.1.5: icmp_seq=1 ttl=63 time=0.234 ms
# 64 bytes from 10.244.1.5: icmp_seq=2 ttl=63 time=0.189 ms
# --- 10.244.1.5 ping statistics ---
# 10 packets transmitted, 10 received, 0% packet loss, time 9012ms
# rtt min/avg/max/mdev = 0.189/0.234/0.456/0.078 ms

# 危险信号：
# 64 bytes from 10.244.1.5: icmp_seq=1 ttl=63 time=2345.678 ms  ← 延迟 2秒+
# 10 packets transmitted, 7 received, 30% packet loss             ← 丢包 30%

# ==================== TCP 连接测试 ====================

# 测试 TCP 端口连通性
time nc -zv <target-pod-ip> 8080

# 预期输出（健康）：
# Connection to 10.244.1.5 8080 port [tcp/http-alt] succeeded!
# real    0m0.005s

# 危险信号：
# nc: connect to 10.244.1.5 port 8080 (tcp) failed: Connection timed out
# real    0m2.101s

# ==================== DNS 诊断 ====================

# 详细 DNS 查询（带时间）
dig @10.96.0.10 kubernetes.default.svc.cluster.local +stats

# 预期输出（健康）：
# ;; Query time: 1 msec
# ;; SERVER: 10.96.0.10#53(10.96.0.10)
# ;; WHEN: Mon Jan 15 08:30:00 UTC 2024
# ;; MSG SIZE  rcvd: 137

# 危险信号：
# ;; Query time: 5234 msec   ← 5秒+
# ;; connection timed out; no servers could be reached

# 使用 dog 工具（更友好的 DNS 查询）
dog kubernetes.default.svc.cluster.local @10.96.0.10

# ==================== 抓包 ====================

# 抓取目标 IP 的所有流量
tcpdump -i any -n host <target-pod-ip> -w /tmp/capture.pcap

# 抓取特定端口
tcpdump -i any -n port 8080

# 预期输出（健康 TCP 三次握手）：
# 08:30:01.123456 IP 10.244.0.5.54321 > 10.244.1.5.8080: Flags [S], seq 1234567890
# 08:30:01.123567 IP 10.244.1.5.8080 > 10.244.0.5.54321: Flags [S.], seq 987654321, ack 1234567891
# 08:30:01.123678 IP 10.244.0.5.54321 > 10.244.1.5.8080: Flags [.], ack 1
# ← 三次握手在 0.2ms 内完成

# 危险信号（SYN 重传）：
# 08:30:01.123456 IP 10.244.0.5.54321 > 10.244.1.5.8080: Flags [S], seq 1234567890
# 08:30:03.123456 IP 10.244.0.5.54321 > 10.244.1.5.8080: Flags [S], seq 1234567890
# 08:30:07.123456 IP 10.244.0.5.54321 > 10.244.1.5.8080: Flags [S], seq 1234567890
# ← SYN 包发出后没有收到 SYN+ACK，重传 3 次后超时

# ==================== 路由表 ====================
ip route

# Calico BGP 模式预期输出：
# default via 10.0.1.1 dev eth0
# 10.244.1.0/24 via 10.0.1.11 dev eth0 proto bird
# 10.244.2.0/24 via 10.0.1.12 dev eth0 proto bird
# 10.244.0.0/24 dev cni0 proto kernel scope link src 10.244.0.1
# ← 跨节点路由通过 bird (BGP) 宣告

# Flannel VXLAN 模式预期输出：
# default via 10.0.1.1 dev eth0
# 10.244.1.0/24 via 10.244.1.0 dev flannel.1 onlink
# 10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink
# 10.244.0.0/24 dev cni0 proto kernel scope link src 10.244.0.1
# ← 跨节点路由通过 flannel.1 VXLAN 接口

# ==================== ARP 表 ====================
ip neigh

# 预期输出：
# 10.244.1.0 dev flannel.1 lladdr aa:bb:cc:dd:ee:ff REACHABLE
# 10.0.1.11 dev eth0 lladdr 02:42:0a:00:01:0b REACHABLE

# 危险信号：
# 10.244.1.0 dev flannel.1 lladdr aa:bb:cc:dd:ee:ff FAILED
# ← ARP 解析失败，MAC 地址无法获取

# ==================== iptables / nftables ====================

# 查看 NAT 表（kube-proxy iptables 模式）
iptables -t nat -L -n -v | grep -E "KUBE-SVC|KUBE-SEP"

# 预期输出（健康，单个 Service）：
# Chain KUBE-SVC-ABC123DEF456 (1 references)
#  pkts bytes target     prot opt in     out     source               destination
#  1234 56789 KUBE-SEP-ABC111DEF111  all  --  *      *       0.0.0.0/0            10.96.0.10           /* default/mysql:tcp cluster IP */ tcp dpt:3306
#  1234 56789 KUBE-SEP-ABC222DEF222  all  --  *      *       0.0.0.0/0            10.96.0.10           /* default/mysql:tcp cluster IP */ tcp dpt:3306

# 危险信号（规则数量爆炸）：
iptables -t nat -L -n | wc -l
# 输出：15000+
# ← 大量 Service/Endpoint 导致 iptables 规则数过万，影响性能

# ==================== conntrack ====================

# 查看 conntrack 表使用
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 预期（健康）：
# count: 50000
# max: 262144
# 使用率：19%

# 危险信号：
# count: 250000
# max: 262144
# 使用率：95% ← 即将溢出

# 按状态统计 conntrack
cat /proc/net/nf_conntrack | awk '{print $4}' | sort | uniq -c | sort -rn

# 预期输出：
#  30000 tcp      ESTABLISHED
#  15000 tcp      TIME_WAIT
#   5000 tcp      CLOSE_WAIT

# 危险信号：
# 180000 tcp      TIME_WAIT  ← TIME_WAIT 过多，说明短连接未复用

# ==================== 网络策略 ====================

# Calico
calicoctl get networkpolicy --all-namespaces
calicoctl get networkpolicy <policy-name> -o yaml

# Cilium
cilium status
cilium endpoint list
cilium monitor --type drop

# 预期输出（Cilium monitor 无丢包）：
# <- endpoint 1234 flow 0x0 , identity 56789->0 state new ifindex 0 orig-ip 0.0.0.0: 10.244.0.5:8080 -> 10.244.1.5:54321 tcp SYN

# 危险信号（Policy denied）：
# xx drop (Policy denied) flow 0x0 to endpoint 1234, identity 56789->0: 10.244.0.5:8080 -> 10.244.1.5:54321 tcp SYN
# ← 策略拒绝了这个连接

# ==================== 网卡状态 ====================

ethtool -S eth0 | grep -E "err|drop|fifo|buf"

# 预期输出（健康）：
# rx_errors: 0
# rx_dropped: 0
# tx_errors: 0
# tx_dropped: 0

# 危险信号：
# rx_errors: 12345   ← 物理层错误
# rx_dropped: 67890  ← 网卡缓冲区满，丢包
# tx_dropped: 3456   ← 发送队列满，丢包
```

---

## 根因 1：conntrack 表满

### 现象

```bash
# dmesg 输出
dmesg | grep -i conntrack
# [12345.678901] nf_conntrack: table full, dropping packet
# [12345.678902] nf_conntrack: table full, dropping packet
# [12345.678903] nf_conntrack: table full, dropping packet

# 应用表现：
# - 高并发场景下，新建连接大量失败
# - 已有连接不受影响
# - 间歇性出现，重启后恢复（因为 conntrack 表清空）
```

### 诊断

```bash
# 1. 确认 conntrack 表状态
echo "Current: $(cat /proc/sys/net/netfilter/nf_conntrack_count)"
echo "Max: $(cat /proc/sys/net/netfilter/nf_conntrack_max)"
echo "Usage: $(awk 'BEGIN{printf "%.1f%%", ('$(cat /proc/sys/net/netfilter/nf_conntrack_count)'/'$(cat /proc/sys/net/netfilter/nf_conntrack_max)')*100}')"

# 2. 查看哪个进程/连接占用了大量 conntrack
cat /proc/net/nf_conntrack | awk '{
  if ($4 == "tcp") {
    split($5, src, "=")
    split($6, dst, "=")
    print src[2] " -> " dst[2]
  }
}' | sort | uniq -c | sort -rn | head -20

# 典型输出：
# 15000 10.244.0.5:8080 -> 10.96.0.10:53
# ← 大量连接访问 CoreDNS，可能是 DNS 查询未复用连接

# 3. 查看 TIME_WAIT 状态连接数
ss -tan state time-wait | wc -l
# 如果 > 50000，说明短连接过多
```

### 根因分析

| 根因 | 场景 | 确认方法 |
|------|------|---------|
| 短连接未复用 | Node.js 应用每次请求新建 HTTP 连接 | `ss -tan` 大量 TIME_WAIT |
| DNS 查询风暴 | ndots:5 导致每次 DNS 查询产生多个 A/AAAA 查询 | `conntrack` 中大量 UDP 53 端口连接 |
| 健康检查过于频繁 | 探针间隔 1s，每个探针新建 TCP 连接 | `conntrack` 中大量探针目标地址 |
| 节点上 Pod 过多 | 100+ Pod 节点，每个 Pod 对外连接数多 | `conntrack_count` 与 Pod 数正相关 |

### 修复

```bash
# === 临时修复 ===

# 增加 conntrack 表大小
sysctl -w net.netfilter.nf_conntrack_max=524288

# 减少 TIME_WAIT 超时时间（谨慎使用）
sysctl -w net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
sysctl -w net.ipv4.tcp_tw_reuse=1

# === 长期修复 ===

# 写入 sysctl.conf
cat >> /etc/sysctl.conf <<'EOF'
# conntrack 优化
net.netfilter.nf_conntrack_max=524288
net.netfilter.nf_conntrack_tcp_timeout_established=86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait=30
net.netfilter.nf_conntrack_tcp_timeout_close_wait=60
net.netfilter.nf_conntrack_udp_timeout=30
net.netfilter.nf_conntrack_udp_timeout_stream=60

# TCP 优化，减少 TIME_WAIT
net.ipv4.tcp_tw_reuse=1
net.ipv4.tcp_fin_timeout=15
EOF

sysctl -p

# === 应用层修复 ===

# 1. 应用使用连接池（HTTP Keep-Alive）
# Node.js:
# const agent = new http.Agent({ keepAlive: true, maxSockets: 50 });

# 2. 调整 ndots
dnsConfig:
  options:
  - name: ndots
    value: "2"

# 3. 部署 NodeLocal DNSCache
# 缓存 DNS 查询，减少到 CoreDNS 的连接数
kubectl apply -f https://raw.githubusercontent.com/kubernetes/kubernetes/master/cluster/addons/dns/nodelocaldns/nodelocaldns.yaml

# 4. 调整探针使用长连接
livenessProbe:
  httpGet:
    path: /health
    port: 8080
  periodSeconds: 10
  # 使用 exec 探针时，探针本身不会建立大量连接
```

---

## 根因 2：Calico BGP 路由黑洞

### 现象

```bash
# 跨节点 Pod 通信失败
kubectl exec -it pod-a -- ping 10.244.1.5
# PING 10.244.1.5 (10.244.1.5) 56(84) bytes of data.
# --- 10.244.1.5 ping statistics ---
# 10 packets transmitted, 0 received, 100% packet loss

# 但同节点 Pod 通信正常
kubectl exec -it pod-a -- ping 10.244.0.6
# 64 bytes from 10.244.0.6: icmp_seq=1 ttl=64 time=0.123 ms
```

### 诊断

```bash
# 1. 查看 BGP 对等体状态
calicoctl node status

# 预期输出（健康）：
# Calico process is running.
# IPv4 BGP status
# +--------------+-------------------+-------+----------+-------------+
# | PEER ADDRESS |     PEER TYPE     | STATE |  SINCE   |    INFO     |
# +--------------+-------------------+-------+----------+-------------+
# | 10.0.1.11    | node-to-node mesh | up    | 08:30:00 | Established |
# | 10.0.1.12    | node-to-node mesh | up    | 08:30:00 | Established |
# +--------------+-------------------+-------+----------+-------------+

# 危险信号：
# | 10.0.1.11    | node-to-node mesh | start | 08:30:00 | Connect     |
# ← BGP 会话未建立

# 2. 检查 BGP 会话建立情况（bird 日志）
cat /var/log/calico/bird/current | tail -20

# 危险日志：
# 2024-01-15_08:30:00.123 bird: ... BGP: Connecting to 10.0.1.11 from 10.0.1.10
# 2024-01-15_08:30:00.234 bird: ... BGP: Error: Connection refused
# ← 10.0.1.11 的 BGP 端口 179 被防火墙拦截

# 3. 查看路由表
ip route | grep -E '10\.244\.'

# 预期输出（健康，BGP 模式）：
# 10.244.1.0/24 via 10.0.1.11 dev eth0 proto bird
# 10.244.2.0/24 via 10.0.1.12 dev eth0 proto bird
# 10.244.0.0/24 dev cni0 proto kernel scope link src 10.244.0.1

# 危险信号（路由缺失）：
# 没有 10.244.1.0/24 的路由
# ← BGP 未宣告或宣告失败

# 4. 检查 bird 进程
ps aux | grep bird
# root      1234  0.0  0.1  12345  6789 ?        S    08:00   0:01 bird -R -s /var/run/calico/bird.ctl -d -c /etc/calico/confd/config/bird.cfg

# 5. 检查防火墙
iptables -L -n | grep 179
# 危险：DROP 规则拦截了 TCP 179

# 6. 检查 IP Pool CIDR 是否与 VPC 重叠
calicoctl get ippool -o wide

# 如果 Pod CIDR 与 VPC CIDR 重叠：
# NAME           CIDR            NAT    IPIPMODE   VXLANMODE   DISABLED
# default-pool   10.0.0.0/16     true   Always     Never       false
# ← 10.0.0.0/16 与 VPC CIDR 重叠，导致路由冲突！
```

### 修复

```bash
# === 修复 1：防火墙放行 BGP ===

# 节点间放行 TCP 179
iptables -I INPUT -p tcp --dport 179 -s 10.0.1.0/24 -j ACCEPT
iptables -I OUTPUT -p tcp --sport 179 -d 10.0.1.0/24 -j ACCEPT

# 永久写入（使用 firewalld 或保存 iptables 规则）
service iptables save

# === 修复 2：重启 bird ===

# 重启 Calico Node Pod（会自动重启 bird）
kubectl delete pod -n kube-system -l k8s-app=calico-node --field-selector spec.nodeName=<problem-node>

# 等待重建
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=calico-node --timeout=120s

# === 修复 3：IP Pool CIDR 冲突 ===

# 如果 Pod CIDR 与 VPC 重叠，必须修改 IP Pool
# ⚠️ 这会中断现有 Pod 网络！需要在维护窗口执行

# 1. 备份现有配置
calicoctl get ippool default-pool -o yaml > ippool-backup.yaml

# 2. 创建新的不冲突的 IP Pool
cat > new-ippool.yaml <<EOF
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: new-pool
spec:
  cidr: 192.168.0.0/16
  natOutgoing: true
  disabled: false
  nodeSelector: all()
EOF
calicoctl apply -f new-ippool.yaml

# 3. 禁用旧 Pool（不要删除，以免 IP 被重复分配）
calicoctl patch ippool default-pool --type='merge' -p '{"spec":{"disabled":true}}'

# 4. 重启所有 Pod（获取新 IP）
kubectl delete pods --all --all-namespaces

# 5. 验证
calicoctl get ippool -o wide
ip route | grep 192.168
```

---

## 根因 3：Cilium eBPF 程序丢失

### 现象

```bash
# 升级 Cilium 后部分 Pod 网络不通
cilium status
#    /¯¯\
# /¯¯\__/¯¯\    Cilium:             3 errors, 1 warnings
# \__/¯¯\__/    Operator:           OK
#    \__/       EnvoyDaemonSet:     disabled
#               HubbleRelay:        disabled
#               ClusterMesh:        disabled
# 
# Deployment        cilium-operator    Desired: 2, Ready: 2/2, Available: 2/2
# DaemonSet         cilium             Desired: 3, Ready: 2/3, Available: 2/3
#                                   ↓ 1 个节点未就绪
# Containers:       cilium             Running: 2, Pending: 1
```

### 诊断

```bash
# 1. 查看 Cilium 状态详情
cilium status --all-controllers

# 危险输出：
# Controller          Status   Failure Count   Last Error   Last Success
# endpoint-1234       Failure  15              1m ago       16m ago
#   Error:            unable to regenerate program for endpoint: ...

# 2. 查看 Endpoint 状态
cilium endpoint list

# 预期输出：
# ENDPOINT   POLICY (ingress)   POLICY (egress)   IDENTITY   LABELS (source:key[=value])   IPv6   IPv4         STATUS
# 1234       Disabled            Disabled          56789      k8s:app=web                  fd00:: 10.244.0.5   ready
# 1235       Disabled            Disabled          56790      k8s:app=db                   fd00:: 10.244.0.6   ready

# 危险输出：
# 1234       Disabled            Disabled          56789      k8s:app=web                  fd00:: 10.244.0.5   not-ready
# ← Endpoint 状态不是 ready

# 3. 查看具体 Endpoint 详情
cilium endpoint get 1234

# 查看日志中的错误信息
# "Error while configuring proxy redirects: ..."
# "Failed to load BPF program: ..."

# 4. 查看 eBPF 映射
cilium bpf ipcache list | head

# 5. 查看丢包原因
cilium monitor --type drop

# 预期输出（无丢包）：
# Listening for events on 2 CPUs with 64x4096 of shared memory
# Press Ctrl-C to quit

# 危险输出：
# xx drop (Policy denied) ...
# xx drop (Invalid packet source IP) ...
# xx drop (Fragmented packet) ...
# xx drop (CT: Unknown L4 protocol) ...

# 6. 检查 Cilium Agent 日志
kubectl logs -n kube-system -l k8s-app=cilium --tail=100 | grep -i error

# 典型错误：
# level=error msg="Failed to load bpf_lxc.o: ..."
# level=error msg="BPF template compilation failed: ..."
# level=error msg="JoinEP: Failed to load program: ..."
```

### 修复

```bash
# 修复 1：重新生成 Endpoint

# 对特定 Endpoint 重新生成
cilium endpoint regenerate 1234

# 查看是否恢复
cilium endpoint list | grep 1234

# 修复 2：重启 Cilium Agent

# 在问题节点上重启
kubectl delete pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=<node>

# 等待恢复
kubectl wait --for=condition=ready pod -n kube-system -l k8s-app=cilium --timeout=120s

# 修复 3：如果 eBPF 映射损坏，可能需要重启节点
# 因为 eBPF 程序绑定到内核，有时重启 Pod 不够

# 修复 4：检查内核版本兼容性
cilium status | grep "Kernel Version"
# Cilium 要求内核 >= 4.19，推荐 >= 5.10

uname -r
# 如果内核 < 4.19，需要升级节点 OS
```

---

## 根因 4：kube-proxy IPVS 连接不一致

### 现象

```bash
# Service 后端 Pod 已删除，但仍有流量发送到旧 IP

# 查看 Service 的 Endpoint
kubectl get endpoints my-service
# NAME         ENDPOINTS                           AGE
# my-service   10.244.1.5:8080,10.244.1.6:8080     10m

# 但 IPVS 规则中仍包含旧 Endpoint
ipvsadm -Ln -t 10.96.0.10:8080

# TCP  10.96.0.10:8080 rr
#   -> 10.244.1.5:8080           Masq    1      0          0
#   -> 10.244.1.6:8080           Masq    1      0          0
#   -> 10.244.1.7:8080           Masq    1      0          0   ← 这个 Pod 已经删除了！
```

### 修复

```bash
# 清空 IPVS 规则（kube-proxy 会自动重建）
ipvsadm --clear

# 重启 kube-proxy
kubectl delete pod -n kube-system -l k8s-app=kube-proxy --field-selector spec.nodeName=<node>

# 调整 IPVS 超时
sysctl -w net.ipv4.vs.tcp_timeout_established=900
sysctl -w net.ipv4.vs.tcp_timeout_close_wait=60
sysctl -w net.ipv4.vs.tcp_timeout_fin_wait=60
```

---

## 根因 5：NetworkPolicy 误配

### 现象

```bash
# 某些 Pod 可以通信，某些不行，无规律

# 测试：删除所有 NetworkPolicy 后恢复
# （仅测试环境！）
kubectl delete networkpolicy --all --all-namespaces
# 删除后通信恢复 → 确认是 NetworkPolicy 问题
```

### 诊断

```bash
# 1. 查看所有 NetworkPolicy
kubectl get networkpolicy --all-namespaces

# 2. Calico：查看具体策略
calicoctl get networkpolicy -o yaml | grep -A 10 <target-namespace>

# 3. Cilium：使用策略追踪
cilium policy trace --src k8s:app=frontend --dst k8s:app=backend --dport 80/TCP

# 预期输出（允许）：
# Final verdict: ALLOWED
# 
# List of matching policies:
#   - allow-frontend-to-backend
#     Rule matched:
#       Action: Allow

# 危险输出（拒绝）：
# Final verdict: DENIED
# 
# List of matching policies:
#   - default-deny-all
#     Rule matched:
#       Action: Deny
```

### 常见误配

```yaml
# 错误 1：同时设置了 ingress 和 egress，但忘记允许 DNS
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: broken-policy
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress: []  # 空规则 = 拒绝所有入站
  egress: []   # 空规则 = 拒绝所有出站（包括 DNS！）

# 修复：至少允许 DNS 和必要流量
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: fixed-policy
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: ingress-nginx
    ports:
    - protocol: TCP
      port: 8080
  egress:
  # DNS
  - to:
    - namespaceSelector:
        matchLabels:
          name: kube-system
    ports:
    - protocol: UDP
      port: 53
  # 同命名空间通信
  - to:
    - podSelector: {}
  # 外部 HTTPS
  - to: []
    ports:
    - protocol: TCP
      port: 443
```

---

## 一键网络诊断脚本（生产级）

```bash
#!/bin/bash
# k8s-network-diagnose.sh
# 在问题节点上执行

NAMESPACE=${1:-default}
POD=${2:-}

echo "=========================================="
echo "  K8s 网络诊断脚本"
echo "=========================================="
echo ""

echo "=== 1. 节点网络状态 ==="
ip addr show | grep -E "inet |mtu"
echo ""

echo "=== 2. 路由表 ==="
ip route | head -20
echo ""

echo "=== 3. CNI 信息 ==="
echo "CNI 配置文件:"
cat /etc/cni/net.d/*.conflist 2>/dev/null | head -50 || echo "  无 CNI 配置"
echo ""
echo "CNI 插件:"
ls -la /opt/cni/bin/ 2>/dev/null | head -20 || echo "  无 CNI 插件"
echo ""

echo "=== 4. conntrack 使用率 ==="
echo "Current: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)"
echo "Max: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)"
echo ""

echo "=== 5. iptables NAT 表 ==="
echo "规则数量: $(iptables -t nat -L -n 2>/dev/null | wc -l)"
iptables -t nat -L -n -v | grep -E "KUBE|Chain" | head -20
echo ""

echo "=== 6. Bridge 状态 ==="
ip link show type bridge 2>/dev/null || echo "  无 bridge"
echo ""

echo "=== 7. Veth 接口 ==="
ip link show type veth 2>/dev/null | head -20 || echo "  无 veth"
echo ""

echo "=== 8. 节点到 API Server 连通性 ==="
curl -sk -o /dev/null -w "%{http_code}" \
  https://$KUBERNETES_SERVICE_HOST:$KUBERNETES_SERVICE_PORT/healthz \
  -H "Authorization: Bearer $(cat /var/run/secrets/kubernetes.io/serviceaccount/token 2>/dev/null || echo '')" \
  2>/dev/null || echo "N/A"
echo ""

echo "=== 9. CoreDNS 解析测试 ==="
nslookup kubernetes.default.svc.cluster.local 10.96.0.10 2>&1 | head -5
echo ""

echo "=== 10. Pod CIDR 重叠检查 ==="
HOST_CIDR=$(ip route | grep 'src ' | awk '{print $1}' | head -1)
POD_CIDR=$(cat /etc/cni/net.d/*.conflist 2>/dev/null | grep -o '10\.[0-9]*\.[0-9]*\.[0-9]*/[0-9]*' | head -1)
echo "Host CIDR: $HOST_CIDR"
echo "Pod CIDR: $POD_CIDR"
echo ""

echo "=== 11. 网卡错误统计 ==="
ethtool -S eth0 2>/dev/null | grep -E "err|drop" | head -10 || echo "  ethtool 不可用"
echo ""

echo "=== 12. 内核路由缓存 ==="
ip route show cache 2>/dev/null | wc -l || echo "  路由缓存统计不可用"
echo ""

echo "=========================================="
echo "  诊断完成"
echo "=========================================="
```
