# 网络排障实战

> 系统化网络排障方法论 + 工具链实战。从现象到根因，从物理层到应用层，建立完整的排障思维。

---

## 1. 网络排障方法论

### 1.1 分层排查法

```
发现问题：服务 A 无法访问服务 B

┌─────────────────────────────────────────────────────────────┐
│                    自上而下 or 自下而上                        │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  应用层 (L7)                                                 │
│  ├─ 应用日志是否有错误？                                      │
│  ├─ HTTP 状态码？超时？连接拒绝？                            │
│  ├─ DNS 解析是否正确？                                       │
│  └─ curl -v / wget 测试                                      │
│                                                             │
│  传输层 (L4)                                                 │
│  ├─ TCP 连接能否建立？                                       │
│  ├─ 端口是否监听？                                           │
│  ├─ 连接状态？SYN_SENT？TIME_WAIT？                          │
│  └─ nc / telnet / ss 测试                                    │
│                                                             │
│  网络层 (L3)                                                 │
│  ├─ IP 是否可达？                                            │
│  ├─ 路由是否正确？                                           │
│  ├─ 是否有防火墙拦截？                                       │
│  └─ ping / traceroute / ip route                             │
│                                                             │
│  数据链路层 (L2)                                             │
│  ├─ ARP 是否正确？                                           │
│  ├─ MAC 地址学习是否正常？                                   │
│  ├─ 网桥/VLAN 配置正确？                                     │
│  └─ arp -a / bridge link                                     │
│                                                             │
│  物理层 (L1)                                                 │
│  ├─ 网线是否插好？                                           │
│  ├─ 网卡灯是否亮？                                           │
│  ├─ 网卡是否 UP？                                            │
│  └─ ethtool / ip link                                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 1.2 分段排查法

```
将网络路径分段，逐段确认：

Pod A → veth → cni0 → 宿主机路由 → 物理网卡 → 交换机 → 物理网卡 → 宿主机路由 → cni0 → veth → Pod B
  │       │      │          │           │          │           │          │      │       │
  ▼       ▼      ▼          ▼           ▼          ▼           ▼          ▼      ▼       ▼
 Pod内  Pod出口  网桥    节点路由    节点出口   物理网络    节点入口   节点路由   网桥   Pod入口   Pod内

每段测试方法：
  Pod内:      在 Pod 中 ping localhost / 自己 IP
  Pod出口:    在 Pod 中 ping 网关 (cni0 IP)
  网桥:       在宿主机 ping Pod IP
  节点路由:   ip route get <dest>
  节点出口:   ping 对端节点 IP
  物理网络:   在节点间 traceroute / mtr
```

---

## 2. 核心排障工具

### 2.1 连通性测试

```bash
# ========== ping ==========
# 测试 IP 层连通性
ping <target>
ping -c 5 -i 0.2 <target>    # 5次，间隔0.2秒

# 指定源 IP（多网卡场景）
ping -I 10.244.1.5 <target>

# ========== traceroute / tracepath ==========
# 查看路由路径
traceroute <target>
traceroute -T -p 80 <target>  # TCP SYN 探测（绕过 ICMP 拦截）
mtr <target>                  # 持续 traceroute + 丢包统计

# ========== nc (netcat) ==========
# 测试 TCP/UDP 端口连通
nc -zv <target> 80            # 测试 80 端口
nc -zv <target> 1-1000        # 扫描端口范围

# 启动监听端
nc -l -p 8080

# UDP 测试
nc -u -zv <target> 53

# ========== curl ==========
# HTTP 层测试
curl -v http://<target>       # 详细输出
curl -I http://<target>       # 只看响应头
curl -w "@curl-format.txt" http://<target>
# curl-format.txt:
# time_namelookup: %{time_namelookup}\n
# time_connect: %{time_connect}\n
# time_total: %{time_total}\n
# ========== telnet ==========
telnet <target> 80            # 测试端口是否开放
```

### 2.2 连接与路由

```bash
# ========== ss ========== (替代 netstat，更快)
# 查看所有 socket
ss -tan                       # TCP, all, numeric
ss -tan | grep ESTAB          # 只看 established
ss -tan state time-wait       # 只看 TIME_WAIT
ss -tan '( dport = :80 or sport = :80 )'  # 过滤端口

# 查看进程关联
ss -tanp                      # 显示进程名和 PID

# 查看内存使用
ss -tanm                      # 显示 socket 内存

# 查看连接统计
ss -s                         # socket 统计摘要

# ========== ip route ==========
# 查看路由表
ip route show
ip route show table all       # 所有表
ip route get 10.244.2.5       # 查看到目标的路由
ip route get 10.244.2.5 from 10.244.1.5  # 指定源 IP

# 策略路由
ip rule show                  # 策略规则

# ========== ip neigh ==========
# ARP 表
ip neigh show                 # 等价于 arp -a
ip neigh show dev eth0        # 特定接口

# ========== iptables ==========
# 查看规则
iptables -L -n -v --line-numbers
iptables -t nat -L -n -v      # nat 表
iptables -t mangle -L -n -v   # mangle 表

# 统计命中次数
iptables -L -n -v | grep -E "Chain|pkts"

# 清空计数器
iptables -Z

# ========== conntrack ==========
# 连接跟踪
conntrack -L | head -20
conntrack -L -p tcp --state ESTABLISHED | wc -l
conntrack -L -s <src-ip> -d <dst-ip>
conntrack -D -p tcp --dport 8080  # 删除连接
```

### 2.3 抓包分析

```bash
# ========== tcpdump ==========
# 基础用法
tcpdump -i eth0                          # 抓 eth0
tcpdump -i any                           # 抓所有接口
tcpdump -i eth0 -w capture.pcap          # 写入文件
tcpdump -r capture.pcap                  # 读取文件

# 过滤表达式
# 主机过滤
tcpdump host 10.244.1.5
tcpdump src host 10.244.1.5
tcpdump dst host 10.96.0.1

# 端口过滤
tcpdump port 80
tcpdump portrange 1-1024
tcpdump tcp port 80 and host 10.244.1.5

# 协议过滤
tcpdump icmp                             # ping
tcpdump tcp
tcpdump udp port 53                      # DNS

# 高级过滤
tcpdump 'tcp[tcpflags] & tcp-syn != 0'   # 只看 SYN
tcpdump 'tcp[tcpflags] & tcp-rst != 0'   # 只看 RST（连接被重置）
tcpdump 'tcp[13] & 8 != 0'               # 只看 PSH（有数据传输）

# K8s 特定场景
tcpdump -i any -nn host 10.96.0.1        # 抓 Service IP
tcpdump -i any -nn port 53               # 抓 DNS
tcpdump -i any -nn port 8472             # 抓 Flannel VXLAN

# 抓特定 Pod 的流量（在宿主机上）
tcpdump -i vethxxx -w pod.pcap

# ========== tshark (Wireshark CLI) ==========
tshark -r capture.pcap                   # 读取 pcap
tshark -r capture.pcap -Y "http"         # 过滤 HTTP
tshark -r capture.pcap -T fields -e ip.src -e ip.dst -e http.host

# 实时统计
tshark -i eth0 -q -z io,phs              # 协议层级统计
```

### 2.4 K8s 网络排障专用

```bash
# ========== 进入 Pod 网络命名空间 ==========
# 获取 Pod 所在节点的容器 PID
NODE=$(kubectl get pod <pod> -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -it --image=nicolaka/netshoot

# 在节点上获取 PID
PID=$(crictl ps -q --pod $(crictl pods --name <pod> -q) | head -1)
PID=$(crictl inspect $PID | jq .info.pid)

# 进入网络命名空间
nsenter -t $PID -n

# 在 Pod netns 中执行命令
nsenter -t $PID -n ip addr
nsenter -t $PID -n ip route
nsenter -t $PID -n ss -tan
nsenter -t $PID -n tcpdump -i any -w /tmp/pod.pcap

# ========== 网络调试 Pod ==========
kubectl run netshoot --rm -it --image=nicolaka/netshoot -- /bin/bash

# netshoot 包含的工具：
# curl, wget, httpie, nmap, tcpdump, tshark, ss, netstat
# ip, ifconfig, bridge, arp, route, traceroute, mtr
# dig, nslookup, drill, iperf3, ab, wrk
# calicoctl, cilium, etcdctl

# ========== 检查 CNI 配置 ==========
# 查看节点 CNI 配置
cat /etc/cni/net.d/*.conflist

# 查看 CNI 分配记录
ls /var/lib/cni/networks/
cat /var/lib/cni/networks/<network>/<ip>

# 查看 kube-proxy
kubectl logs -n kube-system -l k8s-app=kube-proxy --tail=50

# 查看 kube-proxy 模式
kubectl get cm kube-proxy -n kube-system -o yaml | grep mode

# ========== DNS 排障 ==========
# 查看 CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=100

# 测试 DNS
kubectl run -it --rm debug --image=busybox:1.28 --restart=Never -- nslookup kubernetes.default

# 直接查询 CoreDNS
kubectl exec -it <coredns-pod> -n kube-system -- wget -qO- http://localhost:9153/metrics

# ========== Service 排障 ==========
# 检查 Endpoints
kubectl get endpoints <service>
kubectl get endpointslices <service>

# 测试 Service
curl -v http://<cluster-ip>:<port>

# 直接访问 Pod IP（绕过 Service）
curl -v http://<pod-ip>:<container-port>
```

---

## 3. 常见网络故障与根因

### 3.1 故障速查表

| 现象 | 可能原因 | 排查命令 |
|------|---------|---------|
| `Connection refused` | 服务未启动/未监听端口 | `ss -tanp` |
| `Connection timed out` | 防火墙/安全组/NetworkPolicy | `iptables -L`, `tcpdump` |
| `No route to host` | 路由缺失/网卡 DOWN | `ip route`, `ip link` |
| `DNS resolution failed` | CoreDNS 故障/配置错误 | `nslookup`, CoreDNS 日志 |
| 间歇性超时 | conntrack 表满/MTU 问题 | `conntrack -C`, `ping -M do -s` |
| 高延迟 | 跨可用区/Overlay 开销/拥塞 | `mtr`, `iperf3` |
| 大量 TIME_WAIT | 短连接/未启用 reuse | `ss -tan`, `sysctl` |
| 大量 CLOSE_WAIT | 应用未关闭连接 | `ss -tan`, 应用日志 |
| Pod 无法出网 | SNAT/路由/NetworkPolicy | `iptables -t nat -L` |
| Service 访问不通 | Endpoints 为空/kube-proxy 故障 | `get endpoints`, kube-proxy 日志 |

### 3.2 MTU 问题诊断

```bash
# 检测 MTU 问题
ping -M do -s 1472 <target>    # 测试 1500 MTU（+8 ICMP +20 IP = 1500）
ping -M do -s 1422 <target>    # 测试 VXLAN 1450 MTU

# 如果大包 ping 不通，小包可以 → MTU 问题
# 解决：调整容器网卡 MTU
# Flannel: 修改 kube-flannel-cfg ConfigMap
# Calico: 修改 IPPool 的 mtu 字段
# Cilium: cilium config mtu=1450
```

### 3.3 conntrack 表满

```bash
# 症状：连接随机失败，日志出现 "nf_conntrack: table full"

# 查看当前连接数
cat /proc/sys/net/netfilter/nf_conntrack_count
cat /proc/sys/net/netfilter/nf_conntrack_max

# 临时增大
sysctl -w net.netfilter.nf_conntrack_max=1048576

# 查看连接类型分布
conntrack -L -o extended | awk '{print $3}' | sort | uniq -c | sort -rn

# 根本原因：
# 1. 大量短连接（如 HTTP 1.0）
# 2. TIME_WAIT 过多
# 3. 连接泄漏

# 解决：
# - 使用长连接/连接池
# - 启用 tcp_tw_reuse
# - 缩短 tcp_fin_timeout
```

### 3.4 DNS 延迟/超时

```bash
# 症状：应用间歇性 DNS 超时

# 检查 ndots 问题
cat /etc/resolv.conf
# search default.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5

# 问题：查询 "my-service" 会尝试：
# 1. my-service.default.svc.cluster.local
# 2. my-service.svc.cluster.local
# 3. my-service.cluster.local
# 4. my-service

# 解决：使用 FQDN
curl http://my-service.default.svc.cluster.local.
# 注意末尾的 . 表示绝对域名

# 或调整 ndots
# 在 Pod spec 中：
dnsConfig:
  options:
    - name: ndots
      value: "2"
```

---

## 4. 网络性能测试

```bash
# ========== iperf3 ==========
# 服务端
iperf3 -s -p 5201

# 客户端
iperf3 -c <server-ip> -p 5201          # TCP
iperf3 -c <server-ip> -p 5201 -u -b 1G # UDP 1Gbps
iperf3 -c <server-ip> -p 5201 -P 10    # 10 个并发连接
iperf3 -c <server-ip> -p 5201 -t 60    # 测试 60 秒

# ========== netperf ==========
# 延迟测试
netperf -t TCP_RR -H <server-ip>

# 吞吐量测试
netperf -t TCP_STREAM -H <server-ip>

# ========== qperf ==========
# 综合测试
qperf <server-ip> tcp_bw tcp_lat

# ========== HTTP 压测 ==========
# wrk
wrk -t12 -c400 -d30s http://<target>

# hey
go install github.com/rakyll/hey@latest
hey -n 10000 -c 100 http://<target>

# ab (Apache Bench)
ab -n 10000 -c 100 http://<target>/
```

---

## 5. 实战排障脚本

```bash
#!/bin/bash
# k8s-network-debug.sh - K8s 网络快速排障脚本

NAMESPACE=${1:-default}
POD=${2}

echo "=== K8s 网络排障 ==="
echo "Namespace: $NAMESPACE"
echo "Pod: ${POD:-<all>}"
echo ""

# 1. Pod 状态
echo "--- Pod 状态 ---"
kubectl get pods -n $NAMESPACE -o wide

# 2. Service 状态
echo "--- Service 状态 ---"
kubectl get svc -n $NAMESPACE
kubectl get endpoints -n $NAMESPACE

# 3. NetworkPolicy
echo "--- NetworkPolicy ---"
kubectl get networkpolicy -n $NAMESPACE

# 4. 如果指定了 Pod
if [ -n "$POD" ]; then
    echo "--- Pod $POD 详情 ---"
    kubectl describe pod $POD -n $NAMESPACE
    
    echo "--- Pod 网络配置 ---"
    kubectl exec $POD -n $NAMESPACE -- ip addr 2>/dev/null || echo "无法执行 ip addr"
    kubectl exec $POD -n $NAMESPACE -- ip route 2>/dev/null || echo "无法执行 ip route"
    
    echo "--- Pod 连接状态 ---"
    kubectl exec $POD -n $NAMESPACE -- ss -tan 2>/dev/null | head -20 || echo "无法执行 ss"
    
    echo "--- Pod DNS 测试 ---"
    kubectl exec $POD -n $NAMESPACE -- nslookup kubernetes.default 2>/dev/null || echo "DNS 测试失败"
fi

# 5. 节点网络
echo "--- 节点路由 ---"
ip route show | grep -E "10\.244|10\.96"

echo "--- iptables NAT 规则数 ---"
iptables -t nat -L -n | wc -l

echo "--- conntrack 状态 ---"
echo "当前连接: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)"
echo "最大连接: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)"

echo "=== 排障完成 ==="
```

---

## 参考资源

- [Linux Network Troubleshooting](https://www.linuxfoundation.org/blog/blog/classic-sysadmin-linux-networking-troubleshooting)
- [Wireshark Display Filters](https://wiki.wireshark.org/DisplayFilters)
- [tcpdump Advanced Filters](https://danielmiessler.com/study/tcpdump/)
- [Kubernetes Debugging Services](https://kubernetes.io/docs/tasks/debug/debug-application/debug-service/)
