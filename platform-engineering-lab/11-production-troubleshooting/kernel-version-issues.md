# 生产排障：内核版本问题导致的集群故障

> K8s 集群中节点内核版本不一致会导致 eBPF 程序加载失败、Cgroup 行为差异、网络功能缺失、
> 驱动不兼容、调度异常等严重问题。在大型集群中，内核升级和版本统一是平台工程的核心职责。

---

## 一、真实故障场景汇总

### 场景 1：内核 4.15 节点 eBPF 程序加载失败（Cilium）

```
故障时间线：
  2024-02-10 09:00 - 新扩容节点加入集群
  09:05 - Cilium CNI Pod 进入 CrashLoopBackOff
  09:10 - 报错 "Failed to load bpf_prog"
  09:15 - 排查发现新节点内核 4.15.0，而其他节点 5.4.0
  09:30 - 将节点内核升级到 5.4+ 后恢复

根因分析：
  Cilium 使用 eBPF 进行网络策略和负载均衡
  eBPF 某些 map 类型和 helper 函数需要内核 5.0+
  
  具体差异：
    内核 4.15：
      - 支持基本 eBPF
      - 不支持 BPF_MAP_TYPE_LRU_HASH（LRU 类型的 eBPF map）
      - 不支持 bpf_fib_lookup helper（用于直接路由）
      - cgroup bpf 挂载点有限
    
    内核 5.4：
      - 完整支持 Cilium 所需的所有 eBPF 特性
      - 支持 BPF_MAP_TYPE_LRU_HASH
      - 支持 bpf_fib_lookup
      - 支持 cgroup v2 bpf 挂载
  
  错误日志：
    level=error msg="Unable to create endpoint" 
      error="Unable to create eBPF map: Operation not supported"
    level=error msg="Failed to load bpf_prog" 
      error="create map: invalid argument"
  
  实际数据：
    受影响 Pod 数: 47
    受影响节点: 3 台（内核 4.15）
    正常节点: 12 台（内核 5.4）
    恢复时间: 25 分钟
```

### 场景 2：内核 3.10 节点 Cgroup v2 不支持导致 Pod 调度失败

```
故障时间线：
  2024-03-18 14:00 - 升级 K8s 到 1.25+
  14:30 - 部分节点 Pod 无法启动，报错 "Failed to create shim"
  14:45 - 发现 containerd 配置了 SystemdCgroup=true
  15:00 - 排查发现内核 3.10 不支持 Cgroup v2

根因分析：
  K8s 1.25+ 推荐 Cgroup v2
  containerd 配置使用 systemd cgroup driver
  但 CentOS 7 默认内核 3.10 不支持 unified cgroup hierarchy
  
  具体差异：
    内核 3.10：
      - 不支持 cgroup v2（unified hierarchy）
      - 不支持 cgroup namespaces
      - memory cgroup 的 kmem 支持不完善
    
    内核 5.x+：
      - 完整支持 cgroup v2
      - 支持 cgroup namespaces
      - 完整的 kmem accounting
  
  错误日志（containerd）：
    level=error msg="failed to create containerd task" 
      error="OCI runtime create failed: container_linux.go:380: 
      starting container process caused: 
      apply caps: operation not permitted: unknown"
  
  错误日志（kubelet）：
    Warning FailedCreatePodSandBox 
      "Failed to create pod sandbox: rpc error: 
      code = Unknown desc = failed to create containerd task"
  
  实际数据：
    受影响节点: CentOS 7 节点 8 台
    正常节点: Ubuntu 22.04 节点 20 台
    无法启动 Pod: 156 个
```

### 场景 3：内核 4.19 与 5.4 iptables 性能差异导致超时

```
故障时间线：
  2024-04-22 20:00 - 业务高峰期间，部分节点服务响应慢
  20:05 - P99 延迟从 50ms 飙升到 500ms+
  20:10 - 发现慢节点内核 4.19，正常节点内核 5.4
  20:20 - 定位到 iptables 规则遍历性能差异

根因分析：
  kube-proxy iptables 模式下，每条 Service 创建多条 iptables 规则
  集群有 500+ Service，每个节点 iptables 规则数约 5000+
  
  内核 4.19：
    - iptables 规则遍历为线性 O(n)
    - 5000 条规则，每次包处理需要遍历全部
    - 在 10K QPS 下，CPU 大量消耗在 iptables
    - netfilter hook 成为瓶颈
  
  内核 5.4：
    - iptables 优化了规则查找
    - 支持 nf_tables 后端（nftables）
    - 规则匹配性能提升 30%+
  
  实际数据：
    内核 4.19 节点：
      iptables 规则数: 5234
      softirq CPU 使用率: 35%
      P99 延迟: 520ms
    
    内核 5.4 节点：
      iptables 规则数: 5234
      softirq CPU 使用率: 12%
      P99 延迟: 55ms
  
  诊断命令输出：
    $ iptables -t nat -L -n | wc -l
    5234
    
    $ perf top -g
    35.20%  [kernel]      [k] ipt_do_table
    12.30%  [kernel]      [k] skb_copy_bits
    8.50%   [kernel]      [k] nf_hook_slow
    
    # 对比 5.4 节点：
    $ perf top -g
    12.10%  [kernel]      [k] ipt_do_table
    6.30%   [kernel]      [k] skb_copy_bits
    3.20%   [kernel]      [k] nf_hook_slow
```

### 场景 4：内核 5.4 vs 5.15 overlayfs 差异导致文件读写异常

```
故障时间线：
  2024-05-08 11:00 - 应用报告文件读写偶发失败
  11:10 - 报错 "Input/output error" 或 "Stale file handle"
  11:20 - 发现仅发生在内核 5.15 节点
  11:30 - 定位到 overlayfs metacopy 特性变化

根因分析：
  容器使用 overlayfs 作为存储驱动
  内核 5.15 引入了 overlayfs metacopy=on 默认启用
  某些场景下与旧版 Docker/containerd 不兼容
  
  具体差异：
    内核 5.4：
      - overlayfs 默认 metacopy=off
      - 文件元数据修改会复制整个文件
    
    内核 5.10+：
      - overlayfs 支持 metacopy=on
      - 只复制元数据，不复制数据部分
      - 节省空间和提高性能
      - 但某些 corner case 下可能出错
  
  错误日志：
    [11:23:45] app ERROR: Failed to write file: Input/output error
    [11:23:46] kernel: overlayfs: failed to verify origin
    [11:23:46] kernel: overlayfs: upperdir/inode is stale
  
  实际数据：
    受影响节点: 5 台（内核 5.15）
    受影响应用: 使用 hostPath + overlayfs 的 DaemonSet
    故障频率: 约 0.1% 的文件操作
```

### 场景 5：内核 5.10 memory cgroup 变化导致 OOM 误判

```
故障时间线：
  2024-06-12 16:00 - 升级节点内核从 5.4 到 5.10
  16:30 - 多个 Pod 被意外 OOMKill
  16:45 - 内存使用量并未达到 Limit
  17:00 - 发现 5.10 内核 memory cgroup 统计方式变化

根因分析：
  内核 5.10 修改了 memory cgroup 的统计逻辑
  将更多类型的内存计入 cgroup 限制
  
  具体变化：
    内核 5.4：
      memory.usage_in_bytes 主要统计：
        - rss
        - cache（部分）
        - 不包含 kernel 栈、pagetable 等
    
    内核 5.10：
      memory.usage_in_bytes 包含：
        - rss
        - cache
        - kernel_stack
        - pagetables
        - percpu
        - sock
        - shmem
  
  实际数据：
    Pod Memory Limit: 1Gi
    
    内核 5.4：
      rss: 700Mi
      cache: 200Mi
      usage_in_bytes: 900Mi
      是否 OOM: 否
    
    内核 5.10：
      rss: 700Mi
      cache: 200Mi
      kernel_stack: 50Mi
      pagetables: 30Mi
      sock: 30Mi
      usage_in_bytes: 1010Mi
      是否 OOM: 是（超过 1Gi）
  
  诊断输出：
    $ cat /sys/fs/cgroup/memory/memory.stat
    # 内核 5.4:
    cache 209715200
    rss 734003200
    rss_huge 0
    mapped_file 104857600
    
    # 内核 5.10:
    anon 734003200
    file 209715200
    kernel_stack 52428800
    pagetables 31457280
    percpu 10485760
    sock 31457280
    shmem 0
    file_mapped 104857600
    file_dirty 0
    file_writeback 0
```

---

## 二、内核版本一致性诊断

### 2.1 集群内核版本检查

```bash
#!/bin/bash
# diagnose-kernel-versions.sh

echo "=========================================="
echo "  集群内核版本诊断"
echo "  时间: $(date)"
echo "=========================================="

# 1. 所有节点内核版本
echo ""
echo "=== 1. 节点内核版本分布 ==="
kubectl get nodes -o json | jq -r '
  .items[] | 
  [.metadata.name, .status.nodeInfo.kernelVersion, .status.nodeInfo.osImage] | 
  @tsv
' | sort -k2 | column -t

# 预期输出（健康 - 版本一致）：
# node-01  5.4.0-150-generic  Ubuntu 20.04.6 LTS
# node-02  5.4.0-150-generic  Ubuntu 20.04.6 LTS
# node-03  5.4.0-150-generic  Ubuntu 20.04.6 LTS

# 危险输出（版本不一致）：
# node-01  5.4.0-150-generic   Ubuntu 20.04.6 LTS
# node-02  5.4.0-150-generic   Ubuntu 20.04.6 LTS
# node-03  4.15.0-213-generic  Ubuntu 18.04.6 LTS   <- 危险！
# node-04  5.15.0-91-generic   Ubuntu 22.04.3 LTS   <- 危险！
# node-05  3.10.0-1160.el7.x86_64  CentOS Linux 7   <- 危险！

# 2. 内核版本统计
echo ""
echo "=== 2. 版本统计 ==="
kubectl get nodes -o json | jq -r '.items[].status.nodeInfo.kernelVersion' | sort | uniq -c | sort -rn

# 预期（健康）：
#   15 5.4.0-150-generic

# 危险：
#    8 5.4.0-150-generic
#    5 5.15.0-91-generic
#    3 4.15.0-213-generic
#    2 3.10.0-1160.el7.x86_64

# 3. 检查内核模块
echo ""
echo "=== 3. 关键内核模块检查 ==="
for node in $(kubectl get nodes -o name); do
    echo "--- $node ---"
    kubectl debug $node -it --image=busybox -- sh -c '
        echo "br_netfilter: $(lsmod 2>/dev/null | grep br_netfilter | wc -l)"
        echo "overlay: $(lsmod 2>/dev/null | grep overlay | wc -l)"
        echo "ip_vs: $(lsmod 2>/dev/null | grep ip_vs | wc -l)"
        echo "eBPF: $(ls /sys/kernel/debug/tracing/ 2>/dev/null | head -1 | wc -l)"
    '
done

# 4. Cgroup 版本检查
echo ""
echo "=== 4. Cgroup 版本分布 ==="
for node in $(kubectl get nodes -o name); do
    NODE_NAME=${node#node/}
    CGROUP_VER=$(kubectl debug $node -it --image=busybox -- sh -c 'stat -fc %T /sys/fs/cgroup 2>/dev/null' 2>/dev/null | tr -d '\n')
    echo "$NODE_NAME: $CGROUP_VER"
done

# 预期（统一）：
# node-01: cgroup2fs
# node-02: cgroup2fs

# 危险（混合）：
# node-01: cgroup2fs
# node-02: tmpfs        <- v1 节点！
```

### 2.2 内核特性能力检查

```bash
#!/bin/bash
# check-kernel-features.sh

echo "=========================================="
echo "  内核特性能力检查"
echo "=========================================="

# 1. eBPF 支持
echo ""
echo "=== 1. eBPF 支持 ==="
cat /proc/sys/kernel/bpf_stats_enabled 2>/dev/null && echo "bpf_stats: enabled" || echo "bpf_stats: unknown"
ls /sys/fs/bpf/ 2>/dev/null | head -5

# eBPF 程序类型支持（内核 5.4+ 关键类型）
cat /sys/kernel/debug/tracing/available_filter_functions 2>/dev/null | wc -l
# > 0 表示 eBPF 基本支持

# 2. Cgroup v2 支持
echo ""
echo "=== 2. Cgroup v2 支持 ==="
if [ -d /sys/fs/cgroup/unified ]; then
    echo "hybrid mode (v1 + v2)"
elif [ -f /sys/fs/cgroup/cgroup.controllers ]; then
    echo "unified v2 mode"
    cat /sys/fs/cgroup/cgroup.controllers
else
    echo "v1 only"
fi

# 3. IPVS 支持
echo ""
echo "=== 3. IPVS 支持 ==="
if command -v ipvsadm &>/dev/null; then
    ipvsadm -Ln 2>/dev/null | head -5
else
    echo "ipvsadm not installed"
fi

# 内核模块
cat /proc/net/ip_vs 2>/dev/null | head -3

# 4. nftables 支持
echo ""
echo "=== 4. nftables 支持 ==="
nft list tables 2>/dev/null | head -5 || echo "nftables not available"

# 5. overlayfs 特性
echo ""
echo "=== 5. overlayfs 特性 ==="
cat /proc/filesystems | grep overlay
# nodev   overlay

# metacopy 支持（内核 5.10+）
modinfo overlay 2>/dev/null | grep -i metacopy || echo "metacopy info not available"

# 6. 内存 cgroup v2 统计
echo ""
echo "=== 6. Memory Cgroup 统计能力 ==="
if [ -f /sys/fs/cgroup/memory.stat ]; then
    echo "v2 memory.stat available"
    head -10 /sys/fs/cgroup/memory.stat
elif [ -f /sys/fs/cgroup/memory/memory.stat ]; then
    echo "v1 memory.stat available"
    head -10 /sys/fs/cgroup/memory/memory.stat
fi
```

---

## 三、修复方案

### 3.1 内核版本统一升级流程

```bash
# === 生产环境内核升级标准流程 ===

# 步骤 1：选择目标内核版本
# K8s 1.28+ 推荐内核 5.4+，建议 5.10+ 或 5.15+
TARGET_KERNEL="5.4.0-150-generic"

# 步骤 2：逐节点升级（避免同时升级多台）

#!/bin/bash
# upgrade-node-kernel.sh

NODE_NAME="$1"
if [ -z "$NODE_NAME" ]; then
    echo "Usage: $0 <node-name>"
    exit 1
fi

echo "=== 开始升级节点 $NODE_NAME 内核 ==="

# 1. 驱逐节点上的 Pod
kubectl cordon "$NODE_NAME"
kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --timeout=300s

# 等待驱逐完成
sleep 30

# 2. SSH 到节点执行升级
ssh "$NODE_NAME" '
    # Ubuntu/Debian
    apt-get update
    apt-get install -y linux-image-5.4.0-150-generic linux-headers-5.4.0-150-generic
    
    # 更新 GRUB 默认启动项
    update-grub
    
    # 验证新内核已安装
    dpkg -l | grep linux-image
    
    # 重启
    reboot
'

# 3. 等待节点恢复
sleep 60

# 4. 验证节点状态
kubectl wait --for=condition=Ready node/"$NODE_NAME" --timeout=300s

# 5. 验证内核版本
kubectl get node "$NODE_NAME" -o jsonpath='{.status.nodeInfo.kernelVersion}'

# 6. 恢复调度
kubectl uncordon "$NODE_NAME"

echo "=== 节点 $NODE_NAME 内核升级完成 ==="
```

### 3.2 内核模块加载修复

```bash
# === 自动加载必需内核模块 ===

# /etc/modules-load.d/k8s.conf
cat > /etc/modules-load.d/k8s.conf <<'EOF'
# K8s 必需模块
br_netfilter
overlay
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
EOF

# 立即加载
modprobe br_netfilter
modprobe overlay
modprobe ip_vs
modprobe ip_vs_rr
modprobe ip_vs_wrr
modprobe ip_vs_sh
modprobe nf_conntrack

# 验证
lsmod | grep -E "br_netfilter|overlay|ip_vs"

# 设置 sysctl
cat > /etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl -p /etc/sysctl.d/99-k8s.conf
```

### 3.3 Cgroup 版本统一

```bash
# === 统一启用 Cgroup v2 ===

# 检查当前状态
stat -fc %T /sys/fs/cgroup
# tmpfs -> v1
# cgroup2fs -> v2

# 启用 v2（需要内核 5.x+）
# 方法 1：GRUB 参数
cat > /etc/default/grub.d/cgroup.cfg <<'EOF'
GRUB_CMDLINE_LINUX="systemd.unified_cgroup_hierarchy=1"
EOF

# 方法 2：对于已安装的系统，可能需要额外的 systemd 配置
cat > /etc/systemd/system.conf.d/cgroup.conf <<'EOF'
[Manager]
DefaultCPUAccounting=yes
DefaultMemoryAccounting=yes
DefaultIOAccounting=yes
EOF

update-grub
reboot

# 验证
stat -fc %T /sys/fs/cgroup
# cgroup2fs

# Kubelet 配置确保使用 systemd cgroup driver
cat > /var/lib/kubelet/config.yaml <<'EOF'
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
```

### 3.4 kube-proxy 模式选择（基于内核版本）

```bash
# === 根据内核版本选择最优 proxy 模式 ===

# 检查内核版本
KERNEL_MAJOR=$(uname -r | cut -d. -f1)
KERNEL_MINOR=$(uname -r | cut -d. -f2)

if [ "$KERNEL_MAJOR" -gt 5 ] || ([ "$KERNEL_MAJOR" -eq 5 ] && [ "$KERNEL_MINOR" -ge 4 ]); then
    # 内核 5.4+，推荐 ipvs 模式
    echo "Kernel $KERNEL_MAJOR.$KERNEL_MINOR: 推荐使用 ipvs 模式"
    
    # 检查 IPVS 模块
    if lsmod | grep -q ip_vs; then
        echo "IPVS 模块已加载"
        
        # 配置 kube-proxy
        kubectl get configmap kube-proxy -n kube-system -o yaml | \
            sed 's/mode: ""/mode: "ipvs"/' | \
            kubectl apply -f -
        
        # 重启 kube-proxy
        kubectl rollout restart daemonset kube-proxy -n kube-system
    else
        echo "IPVS 模块未加载，请先加载"
    fi
else
    # 内核 < 5.4，使用 iptables 模式
    echo "Kernel $KERNEL_MAJOR.$KERNEL_MINOR: 使用 iptables 模式"
    
    # 配置 kube-proxy
    kubectl get configmap kube-proxy -n kube-system -o yaml | \
        sed 's/mode: "ipvs"/mode: "iptables"/' | \
        kubectl apply -f -
    
    kubectl rollout restart daemonset kube-proxy -n kube-system
fi
```

### 3.5 overlayfs metacopy 禁用（解决兼容性问题）

```bash
# === 禁用 overlayfs metacopy ===

# 检查当前 overlay 模块参数
systool -m overlay -A 2>/dev/null || modinfo overlay | grep parm

# 方法 1：模块参数
echo "options overlay metacopy=off" > /etc/modprobe.d/overlay.conf

# 重新加载模块
modprobe -r overlay 2>/dev/null || true
modprobe overlay

# 验证
cat /sys/module/overlay/parameters/metacopy
# N 或 off

# 方法 2：Docker/containerd 配置（使用 fuse-overlayfs 或不同 snapshotter）
# /etc/containerd/config.toml
# [plugins."io.containerd.grpc.v1.cri".containerd]
#   snapshotter = "native"  # 避免 overlayfs 问题（性能较差）
#   snapshotter = "overlayfs"

# 对于 Docker
# /etc/docker/daemon.json
# {
#   "storage-driver": "overlay2",
#   "storage-opts": ["overlay2.override_kernel_check=true"]
# }
```

---

## 四、内核版本兼容性矩阵

```
K8s 版本与推荐内核版本：

K8s 版本     最小内核    推荐内核    Cgroup     关键特性
-----------------------------------------------------------------
1.20-1.24    3.10+      4.19+      v1/v2      基本功能
1.25-1.27    4.15+      5.4+       v2         Cgroup v2 支持
1.28-1.30    5.4+       5.10+      v2         内存 cgroup 改进
1.31+        5.10+      5.15+      v2         nftables, eBPF 增强
-----------------------------------------------------------------

CNI 与内核要求：

CNI           最小内核    推荐内核    关键依赖
---------------------------------------------------------
Flannel       3.10+      4.19+       vxlan module
Calico        3.10+      4.19+       ipset, iptables
Cilium        4.19+      5.4+        eBPF, BPF_CGROUP_SOCK
Weave         3.10+      4.19+       vxlan
Antrea        4.6+       5.4+        eBPF (可选)
---------------------------------------------------------

运行时与内核要求：

运行时          最小内核    推荐内核    关键依赖
---------------------------------------------------------
docker          3.10+      4.19+       overlayfs
containerd      3.10+      4.19+       overlayfs
cri-o           3.10+      4.19+       overlayfs
gVisor          4.15+      5.4+        seccomp, KVM
Kata            4.14+      5.4+        KVM, vhost
---------------------------------------------------------
```

---

## 五、监控告警

```yaml
# === Prometheus 内核版本监控 ===

# Node Exporter 规则
apiVersion: v1
kind: ConfigMap
metadata:
  name: kernel-version-alerts
  namespace: monitoring
data:
  kernel-alerts.yml: |
    groups:
    - name: kernel-version
      rules:
      # 告警：节点内核版本不一致
      - alert: NodeKernelVersionMismatch
        expr: |
          count by (cluster) (
            count by (kernel_version, cluster) (node_uname_info)
          ) > 1
        for: 1h
        labels:
          severity: warning
        annotations:
          summary: "集群内核版本不一致"
          description: "集群存在 {{ $value }} 种不同内核版本"
      
      # 告警：节点内核过旧
      - alert: NodeKernelTooOld
        expr: |
          node_uname_info{
            kernel_version=~"^[0-3]\\..*"
          } or
          node_uname_info{
            kernel_version=~"^4\\.[0-9]\\..*"
          } or
          node_uname_info{
            kernel_version=~"^4\\.1[0-4]\\..*"
          }
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "节点 {{ $labels.instance }} 内核版本过旧"
          description: "当前内核 {{ $labels.kernel_version }}，建议升级到 5.4+"
      
      # 告警：IPVS 连接数过高（内核 < 5.4 性能问题）
      - alert: IPVSConnectionsHigh
        expr: |
          node_ipvs_connections > 100000
        for: 10m
        labels:
          severity: warning
        annotations:
          summary: "IPVS 连接数过高"
          description: "当前 {{ $value }} 连接，考虑升级到内核 5.4+ 或优化连接复用"
      
      # 告警：缺少必需内核模块
      - alert: KernelModuleMissing
        expr: |
          node_kernel_module_loaded{module="br_netfilter"} == 0 or
          node_kernel_module_loaded{module="overlay"} == 0
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "节点缺少必需内核模块"
          description: "模块 {{ $labels.module }} 未加载"
```

---

## 六、面试要点

```
Q: K8s 集群中内核版本不一致会带来哪些问题？

A:
   1. eBPF 程序兼容性问题：
      - Cilium 等基于 eBPF 的 CNI 需要特定内核版本
      - 旧内核缺少必要的 eBPF helper 函数和 map 类型
   
   2. Cgroup 行为差异：
      - v1/v2 统计方式不同导致 OOM 阈值不一致
      - CPU throttle 计算方式不同
   
   3. 网络性能差异：
      - iptables 规则遍历性能在不同内核差异大
      - IPVS 在大规模 Service 下性能差异
   
   4. 存储兼容性：
      - overlayfs 特性在不同版本行为不同
      - metacopy 等特性可能导致文件操作异常
   
   5. 安全风险：
      - 旧内核存在已知 CVE
      - 新内核安全特性无法在旧内核使用

Q: 如何安全地升级 K8s 节点的内核？

A:
   1. 逐节点升级，避免批量操作
   2. 升级前 cordon + drain 节点
   3. 确保新内核已通过测试环境验证
   4. 升级后验证：
      - kubectl get node 状态 Ready
      - 内核版本正确
      - 关键模块已加载（br_netfilter, overlay, ip_vs）
      - 测试 Pod 能正常调度运行
   5. 升级后 uncordon 恢复调度
   6. 观察 24 小时无异常后再升级下一台
   
   回滚准备：
   - GRUB 保留旧内核启动项
   - 准备紧急回滚脚本

Q: 内核 5.10 相比 5.4 在容器场景有哪些关键改进？

A:
   1. Cgroup v2 更完善：
      - 完整的 memory.pressure 支持
      - 更好的 IO 控制（io.stat）
   
   2. eBPF 增强：
      - 支持 cgroup_sock_addr 类型的 eBPF 程序
      - 更好的性能监控能力
   
   3. overlayfs 改进：
      - metacopy 支持（需注意兼容性）
      - 更好的文件系统性能
   
   4. 内存管理：
      - 更准确的 cgroup 内存统计
      - 包含 kernel_stack, pagetables 等
   
   5. 安全性：
      - 更完善的 seccomp 过滤
      - Landlock LSM 支持

Q: 内核 3.10 (CentOS 7) 为什么不能运行 K8s 1.25+？

A:
   1. Cgroup v2 不支持：
      - K8s 1.25+ 推荐使用 Cgroup v2
      - 内核 3.10 只有 Cgroup v1
   
   2. containerd/cri-o 兼容性问题：
      - 现代容器运行时需要 cgroup namespaces
      - 3.10 不支持 cgroup namespaces
   
   3. eBPF 能力缺失：
      - 现代 CNI（Cilium）需要 eBPF
      - 3.10 的 eBPF 能力非常有限
   
   4. systemd 集成问题：
      - systemd cgroup driver 需要较新的内核
      - 3.10 下 systemd 集成不完善
   
   建议：
   - CentOS 7 升级到 CentOS Stream 8/9 或 Rocky Linux 8/9
   - 内核升级到 5.4+

Q: 如何检查节点是否支持 Cilium 所需的 eBPF 特性？

A:
   1. 内核版本 >= 4.19（推荐 5.4+）
   2. 检查 /sys/kernel/debug/tracing/ 是否存在
   3. 检查 BPF 系统调用支持：
      - grep CONFIG_BPF_SYSCALL /boot/config-$(uname -r)
   4. 检查特定 map 类型支持：
      - bpftool feature probe | grep BPF_MAP_TYPE_LRU_HASH
   5. 检查 helper 函数支持：
      - bpftool feature probe | grep bpf_fib_lookup
   6. 检查 cgroup BPF 挂载点：
      - mount | grep cgroup
   7. 运行 Cilium 的 connectivity test 验证
```
