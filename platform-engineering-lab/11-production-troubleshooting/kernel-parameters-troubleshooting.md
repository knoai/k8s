# 生产排障：内核参数导致的延迟与故障

> Linux 内核参数直接影响容器网络、文件系统、进程调度等核心行为。
> 一个参数配置不当，可能导致全集群级别的延迟飙升或连接异常。

---

## 一、真实故障场景汇总

### 场景 1：net.ipv4.ip_local_port_range 导致新建连接失败

```
故障时间线：
  2024-03-15 14:00 - 业务高峰期间，订单服务报错 "Cannot assign requested address"
  14:05 - 连接池大量溢出，HikariCP pending=200+
  14:10 - 全链路延迟 P99 从 50ms 飙升到 5000ms
  14:30 - SRE 介入排查

根因发现：
  应用作为客户端，每请求调用 3-5 个下游服务（MySQL/Redis/ES）
  每个调用新建短连接（HTTP 1.1 未开启 Keep-Alive）
  内核端口范围默认 32768-61000 = 28232 个端口
  TIME_WAIT 状态连接未快速回收
  端口耗尽后，新连接返回 EADDRNOTAVAIL

诊断命令输出：
  $ ss -tan state time-wait | wc -l
  28150
  
  $ sysctl net.ipv4.ip_local_port_range
  net.ipv4.ip_local_port_range = 32768 60999
  
  $ cat /proc/sys/net/ipv4/tcp_tw_reuse
  0
  
  $ cat /proc/sys/net/ipv4/tcp_tw_recycle
  0
  
  计算：可用端口 28232，TIME_WAIT 占用 28150
  实际可用新建连接端口 = 28232 - 28150 = 82 个！
```

### 场景 2：fs.file-max 导致 "Too many open files"

```
故障时间线：
  2024-04-20 09:15 - 日志服务报错 "java.io.IOException: Too many open files"
  09:20 - 日志采集 Agent 停止写入，日志丢失
  09:30 - 应用日志文件句柄泄露，业务接口超时

诊断命令输出：
  $ ulimit -n
  65535
  
  $ lsof -p <pid> | wc -l
  65534
  
  $ cat /proc/sys/fs/file-max
  65536
  
  $ cat /proc/sys/fs/nr_open
  1048576
  
  问题：容器内 ulimit 继承自宿主机，但 file-max 只有 65536
  每个容器内多个进程共享 file-max
  100 个 Pod 节点，每个节点 file-max=65536
  每个 Pod 平均可用文件句柄 = 65536 / 100 = 655
  但单个 Java 应用可能就打开 2000+ 句柄！
```

### 场景 3：vm.max_map_count 导致 ES 启动失败

```
故障时间线：
  2024-05-10 20:00 - 新部署 Elasticsearch 集群，Pod 反复 CrashLoopBackOff
  20:10 - 日志显示 "max virtual memory areas vm.max_map_count [65530] is too low"
  20:15 - 修改节点 vm.max_map_count 后恢复

诊断命令输出：
  $ sysctl vm.max_map_count
  vm.max_map_count = 65530
  
  $ kubectl logs es-pod
  [ERROR] max virtual memory areas vm.max_map_count [65530] is too low, 
          increase to at least [262144]
  
  ES 需要大量内存映射区域（mmap）用于索引文件
  默认 65530 对于大索引不够
  
  修复：
  sysctl -w vm.max_map_count=262144
```

---

## 二、网络层内核参数

### 2.1 端口范围与 TIME_WAIT

```bash
# === 诊断 ===

# 查看当前端口使用状态
cat > diagnose-ports.sh <<'SCRIPT'
#!/bin/bash
echo "=== 1. 本地端口范围 ==="
cat /proc/sys/net/ipv4/ip_local_port_range

echo ""
echo "=== 2. 各状态连接统计 ==="
ss -tan | awk 'NR>1 {print $1}' | sort | uniq -c | sort -rn

echo ""
echo "=== 3. TIME_WAIT 连接数 ==="
ss -tan state time-wait | wc -l

echo ""
echo "=== 4. 端口使用率 ==="
PORT_RANGE=$(cat /proc/sys/net/ipv4/ip_local_port_range)
PORT_START=$(echo $PORT_RANGE | awk '{print $1}')
PORT_END=$(echo $PORT_RANGE | awk '{print $2}')
TOTAL_PORTS=$((PORT_END - PORT_START))
TIME_WAIT=$(ss -tan state time-wait | wc -l)
ESTABLISHED=$(ss -tan state established | wc -l)
USED=$((TIME_WAIT + ESTABLISHED))
AVAILABLE=$((TOTAL_PORTS - USED))
echo "总端口数: $TOTAL_PORTS"
echo "TIME_WAIT: $TIME_WAIT"
echo "ESTABLISHED: $ESTABLISHED"
echo "已使用: $USED"
echo "可用: $AVAILABLE"
echo "使用率: $(echo "scale=2; $USED * 100 / $TOTAL_PORTS" | bc)%"

echo ""
echo "=== 5. TIME_WAIT 回收参数 ==="
echo "tcp_tw_reuse: $(cat /proc/sys/net/ipv4/tcp_tw_reuse)"
echo "tcp_tw_recycle: $(cat /proc/sys/net/ipv4/tcp_tw_recycle)"
echo "tcp_fin_timeout: $(cat /proc/sys/net/ipv4/tcp_fin_timeout)"
echo "tcp_max_tw_buckets: $(cat /proc/sys/net/ipv4/tcp_max_tw_buckets)"
SCRIPT
bash diagnose-ports.sh

# 预期输出（健康）：
# === 1. 本地端口范围 ===
# 15000 65000
# 
# === 2. 各状态连接统计 ===
#    5000 ESTAB
#    1200 TIME-WAIT
#     300 SYN-RECV
#      50 CLOSE-WAIT
# 
# === 3. TIME_WAIT 连接数 ===
# 1200
# 
# === 4. 端口使用率 ===
# 总端口数: 50000
# TIME_WAIT: 1200
# ESTABLISHED: 5000
# 已使用: 6200
# 可用: 43800
# 使用率: 12.40%

# 危险输出（端口耗尽）：
# === 4. 端口使用率 ===
# 总端口数: 28231
# TIME_WAIT: 27500
# ESTABLISHED: 300
# 已使用: 27800
# 可用: 431
# 使用率: 98.47%
```

### 2.2 修复：网络层参数优化

```bash
# === 生产级网络参数优化 ===

# 写入 sysctl.conf
cat > /etc/sysctl.d/99-network-tuning.conf <<'EOF'
# === 端口范围扩大 ===
# 默认 32768-61000（28232个端口）
# 扩大到 15000-65000（50000个端口）
net.ipv4.ip_local_port_range = 15000 65000

# === TIME_WAIT 快速回收 ===
# 允许复用 TIME_WAIT 状态的端口（仅客户端出方向）
# 安全：仅复用本机作为客户端时的 TIME_WAIT
net.ipv4.tcp_tw_reuse = 1

# 禁用 tcp_tw_recycle（已在 Linux 4.12+ 移除，NAT 环境下危险）
# net.ipv4.tcp_tw_recycle = 0

# 缩短 FIN_WAIT_2 超时（默认 60s）
net.ipv4.tcp_fin_timeout = 15

# 限制 TIME_WAIT 桶数量（防止 DOS）
net.ipv4.tcp_max_tw_buckets = 50000

# === TCP 连接优化 ===
# 开启 SYN Cookie（防止 SYN Flood）
net.ipv4.tcp_syncookies = 1

# 缩短 Keepalive 探测间隔
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15

# TCP 窗口缩放（高带宽延迟网络）
net.ipv4.tcp_window_scaling = 1

# === conntrack 优化 ===
# 增大连接跟踪表
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60

# === 路由缓存 ===
net.ipv4.route.gc_timeout = 100

# === ARP 缓存 ===
net.ipv4.neigh.default.gc_thresh1 = 1024
net.ipv4.neigh.default.gc_thresh2 = 4096
net.ipv4.neigh.default.gc_thresh3 = 8192
EOF

sysctl -p /etc/sysctl.d/99-network-tuning.conf

# 验证
sysctl net.ipv4.ip_local_port_range
# net.ipv4.ip_local_port_range = 15000 65000
```

---

## 三、文件系统层内核参数

### 3.1 文件句柄限制

```bash
# === 诊断 ===

# 系统级别限制
cat /proc/sys/fs/file-max
cat /proc/sys/fs/nr_open
cat /proc/sys/fs/file-nr

# file-nr 输出解读：
# 已分配句柄数  已使用句柄数  最大句柄数
# 123456        112345        0

echo ""
# 进程级别限制
ulimit -n
ulimit -Hn

# Docker / containerd 容器的限制
# 在 Pod 内检查
cat /proc/1/limits | grep "Max open files"
# Max open files            1048576              1048576              files

# 如果看到较低的值，说明容器运行时有限制
# 检查 containerd 配置
cat /etc/containerd/config.toml | grep -A 5 max_open_files

# === 修复 ===

# 1. 系统级别增大
echo "2097152" > /proc/sys/fs/file-max
echo "fs.file-max = 2097152" >> /etc/sysctl.conf

# 2. containerd 配置
cat >> /etc/containerd/config.toml <<'EOF'
[plugins."io.containerd.grpc.v1.cri"]
  [plugins."io.containerd.grpc.v1.cri".containerd]
    [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime]
      [plugins."io.containerd.grpc.v1.cri".containerd.default_runtime.options]
        SystemdCgroup = true
EOF

# 3. Pod 级别设置
cat > pod-file-limits.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: high-file-limit-pod
spec:
  containers:
  - name: app
    image: myapp:v1.0
    securityContext:
      # 容器内文件句柄限制
      # 需要 privileged 或 CAP_SYS_RESOURCE
      # 或者通过 initContainer 修改 limits
  initContainers:
  - name: set-limits
    image: busybox
    command:
    - sh
    - -c
    - |
      ulimit -n 1048576
    securityContext:
      privileged: true
EOF

# 更标准的做法：在节点上设置全局限制
# /etc/security/limits.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
```

### 3.2 inotify 限制（文件监听）

```bash
# 诊断
sysctl fs.inotify.max_user_watches
sysctl fs.inotify.max_user_instances

# 预期（开发环境可能不足）：
# fs.inotify.max_user_watches = 8192
# fs.inotify.max_user_instances = 128

# 问题场景：
# - VS Code 远程开发打开大项目
# - Webpack/Vite 文件监听
# - ConfigMap/Secret 热重载

# 修复
cat > /etc/sysctl.d/99-inotify.conf <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192
fs.inotify.max_queued_events = 524288
EOF
sysctl -p /etc/sysctl.d/99-inotify.conf
```

---

## 四、内存与进程调度参数

### 4.1 vm.max_map_count（内存映射区域）

```bash
# 诊断
sysctl vm.max_map_count
# 默认：65530

# ES 启动检查
kubectl logs es-pod | grep max_map_count
# [ERROR] max virtual memory areas vm.max_map_count [65530] is too low

# 修复（节点级别）
sysctl -w vm.max_map_count=262144
echo "vm.max_map_count = 262144" >> /etc/sysctl.conf

# K8s DaemonSet 自动设置
cat > max-map-count-ds.yaml <<'EOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: sysctl-conf
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: sysctl-conf
  template:
    metadata:
      labels:
        name: sysctl-conf
    spec:
      hostNetwork: true
      hostPID: true
      initContainers:
      - name: sysctl
        image: busybox
        command:
        - nsenter
        - --target
        - "1"
        - --mount
        - --uts
        - --ipc
        - --net
        - --pid
        - --
        - sh
        - -exc
        - |
          sysctl -w vm.max_map_count=262144
          sysctl -w fs.inotify.max_user_watches=524288
          sysctl -w fs.inotify.max_user_instances=8192
        securityContext:
          privileged: true
      containers:
      - name: sleep
        image: k8s.gcr.io/pause:3.9
EOF
kubectl apply -f max-map-count-ds.yaml
```

### 4.2 内存回收与 OOM

```bash
# 诊断
sysctl vm.swappiness
sysctl vm.overcommit_memory
sysctl vm.overcommit_ratio

# 预期：
# vm.swappiness = 60（CentOS）或 1（Ubuntu）
# vm.overcommit_memory = 0（启发式）
# vm.overcommit_ratio = 50

# 问题场景 1：swappiness 过高
# K8s 节点 swap 未关闭，swappiness=60
# 内存不足时使用 swap，性能急剧下降
# 修复：
swapoff -a
sed -i '/swap/d' /etc/fstab
echo "vm.swappiness = 1" >> /etc/sysctl.conf

# 问题场景 2：overcommit_memory=2（严格模式）
# 某些安全合规要求设置 overcommit_memory=2
# 结果：malloc 可能失败，即使物理内存充足
# 容器内 JVM 启动时分配大堆可能失败
# 修复：
# 不建议在容器环境使用严格模式
# 如果必须，增大 overcommit_ratio
echo "vm.overcommit_memory = 0" >> /etc/sysctl.conf

# 问题场景 3：dirty_ratio 过高导致 IO 抖动
# 脏页比例过高时，同步刷盘导致 IO 阻塞
cat > /etc/sysctl.d/99-memory-tuning.conf <<'EOF'
# 降低脏页比例，避免 IO 突发
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.dirty_expire_centisecs = 500
vm.dirty_writeback_centisecs = 100

# 内存回收水位
vm.min_free_kbytes = 1048576
vm.vfs_cache_pressure = 50
EOF
sysctl -p /etc/sysctl.d/99-memory-tuning.conf
```

---

## 五、K8s 相关内核参数

### 5.1 网桥与 iptables

```bash
# 诊断
sysctl net.bridge.bridge-nf-call-iptables
sysctl net.bridge.bridge-nf-call-ip6tables
sysctl net.bridge.bridge-nf-call-arptables

# K8s 要求：
# net.bridge.bridge-nf-call-iptables = 1
# net.bridge.bridge-nf-call-ip6tables = 1

# 如果为 0，Pod 跨节点通信可能不通
# 修复：
modprobe br_netfilter
echo "br_netfilter" >> /etc/modules-load.d/k8s.conf
echo "net.bridge.bridge-nf-call-iptables = 1" >> /etc/sysctl.d/99-k8s.conf
echo "net.bridge.bridge-nf-call-ip6tables = 1" >> /etc/sysctl.d/99-k8s.conf
sysctl -p /etc/sysctl.d/99-k8s.conf

# 查看当前 bridge 配置
sysctl -a | grep bridge

# IP 转发
sysctl net.ipv4.ip_forward
# 必须为 1
```

### 5.2 完整的 K8s 节点 sysctl 配置

```bash
# /etc/sysctl.d/99-k8s-node.conf
# 生产环境 K8s Worker 节点推荐配置

cat > /etc/sysctl.d/99-k8s-node.conf <<'EOF'
# === K8s 必需 ===
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
net.ipv4.conf.all.forwarding = 1

# === 网络优化 ===
net.ipv4.ip_local_port_range = 15000 65000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 50000

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 65536
net.ipv4.tcp_synack_retries = 2

net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_keepalive_intvl = 15

net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65536
net.ipv4.tcp_slow_start_after_idle = 0

# === conntrack ===
net.netfilter.nf_conntrack_max = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30

# === 文件系统 ===
fs.file-max = 2097152
fs.nr_open = 2097152
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 8192

# === 内存 ===
vm.swappiness = 1
vm.overcommit_memory = 1
vm.max_map_count = 262144
vm.dirty_ratio = 10
vm.dirty_background_ratio = 5
vm.min_free_kbytes = 1048576

# === 进程 ===
kernel.pid_max = 4194304
kernel.threads-max = 4194304
EOF

sysctl -p /etc/sysctl.d/99-k8s-node.conf

# 持久化（确保重启后生效）
# systemd 会自动加载 /etc/sysctl.d/*.conf
```

---

## 六、一键诊断脚本

```bash
#!/bin/bash
# kernel-health-check.sh

echo "=========================================="
echo "  内核参数健康检查"
echo "  时间: $(date)"
echo "=========================================="

echo ""
echo "=== 1. 网络参数 ==="
echo "ip_local_port_range: $(cat /proc/sys/net/ipv4/ip_local_port_range)"
echo "tcp_tw_reuse: $(cat /proc/sys/net/ipv4/tcp_tw_reuse)"
echo "tcp_fin_timeout: $(cat /proc/sys/net/ipv4/tcp_fin_timeout)"
echo "tcp_max_tw_buckets: $(cat /proc/sys/net/ipv4/tcp_max_tw_buckets)"
echo "ip_forward: $(cat /proc/sys/net/ipv4/ip_forward)"
echo "bridge-nf-call-iptables: $(cat /proc/sys/net/bridge/bridge-nf-call-iptables 2>/dev/null || echo 'N/A (br_netfilter not loaded)')"

# 端口使用率
PORT_RANGE=$(cat /proc/sys/net/ipv4/ip_local_port_range)
PORT_START=$(echo $PORT_RANGE | awk '{print $1}')
PORT_END=$(echo $PORT_RANGE | awk '{print $2}')
TOTAL_PORTS=$((PORT_END - PORT_START))
TIME_WAIT=$(ss -tan state time-wait 2>/dev/null | wc -l)
ESTABLISHED=$(ss -tan state established 2>/dev/null | wc -l)
USED=$((TIME_WAIT + ESTABLISHED))
echo "端口使用率: $USED / $TOTAL_PORTS ($(echo "scale=1; $USED * 100 / $TOTAL_PORTS" | bc)%)"
if [ "$USED" -gt "$((TOTAL_PORTS * 80 / 100))" ]; then
  echo "  ⚠️  警告：端口使用率超过 80%"
fi

echo ""
echo "=== 2. conntrack ==="
echo "nf_conntrack_count: $(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo N/A)"
echo "nf_conntrack_max: $(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo N/A)"

echo ""
echo "=== 3. 文件系统 ==="
echo "file-max: $(cat /proc/sys/fs/file-max)"
echo "file-nr: $(cat /proc/sys/fs/file-nr)"
echo "inotify.max_user_watches: $(cat /proc/sys/fs/inotify/max_user_watches)"
echo "inotify.max_user_instances: $(cat /proc/sys/fs/inotify/max_user_instances)"

echo ""
echo "=== 4. 内存 ==="
echo "vm.max_map_count: $(cat /proc/sys/vm/max_map_count)"
echo "vm.swappiness: $(cat /proc/sys/vm/swappiness)"
echo "vm.overcommit_memory: $(cat /proc/sys/vm/overcommit_memory)"

echo ""
echo "=== 5. 进程 ==="
echo "pid_max: $(cat /proc/sys/kernel/pid_max)"
echo "threads-max: $(cat /proc/sys/kernel/threads-max)"

echo ""
echo "=========================================="
echo "  检查完成"
echo "=========================================="
```

---

## 七、面试要点

```
Q: 为什么容器内看到的 sysctl 参数和宿主机不同？

A: 命名空间隔离：
   - 网络参数（net.*）：在 net namespace 内可独立设置
   - 但大部分网络参数是全局的，容器内修改不影响宿主机
   - 某些参数容器内没有权限修改（需要 SYS_ADMIN）
   
   解决方案：
   1. 在宿主机设置参数（影响所有容器）
   2. 使用 privileged 容器（不推荐）
   3. 使用 initContainer 修改（需要 privileged）
   4. 使用 DaemonSet 统一管理节点参数

Q: TIME_WAIT 连接过多如何排查和解决？

A: 排查：
   1. ss -tan state time-wait | wc -l
   2. 查看端口使用率
   3. 检查应用是否使用长连接
   
   解决：
   1. 扩大端口范围（ip_local_port_range）
   2. 开启 tcp_tw_reuse=1
   3. 应用层开启 HTTP Keep-Alive
   4. 使用连接池（HikariCP、HTTP client pool）
   5. 调整 tcp_fin_timeout
   
   注意：
   - tcp_tw_recycle 已废弃（NAT 环境下危险）
   - tcp_tw_reuse 只对客户端出方向有效

Q: vm.overcommit_memory 的三种模式区别？

A: 
   0 - 启发式（默认）：
   - 内核根据启发式算法判断是否允许 overcommit
   - 大多数场景下可以分配比物理内存更多的虚拟内存
   - 适合通用场景
   
   1 - 总是允许：
   - 所有 malloc 都成功，直到真正使用内存时可能 OOM
   - 适合需要大量虚拟内存的场景（如 JVM 大堆）
   - K8s 推荐设置
   
   2 - 严格模式：
   - 不允许 overcommit
   - 可分配内存 = swap + RAM * overcommit_ratio%
   - 可能导致 malloc 失败
   - 某些安全合规要求，但不适合容器环境
```
