# 第21章 K8s 操作系统基础篇：Linux 内核与系统基础

> **本章目标**：从操作系统角度深入理解 Kubernetes，覆盖 Linux 内核核心子系统、系统调用机制、容器与内核的交互原理。
>
> 读完本章后，你应该能够：理解 Linux 内核架构；掌握 Namespace/Cgroups 机制；分析容器文件系统和进程；使用系统工具排查问题。

---

## 21.1 Linux 内核架构

### 21.1.1 内核子系统概览

```
┌─────────────────────────────────────────────────────────────┐
│                     用户空间                                 │
│   应用程序  │  系统库(glibc)  │  Shell  │  系统工具          │
├─────────────────────────────────────────────────────────────┤
│                    系统调用接口 (System Call)                │
│   ┌─────────────────────────────────────────────────────┐   │
│   │  系统调用号  │  参数  │  返回值  │  错误码            │   │
│   │  __NR_clone  │  flags│  pid    │  -errno            │   │
│   └─────────────────────────────────────────────────────┘   │
├─────────────────────────────────────────────────────────────┤
│                      内核空间                                │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────┐    │
│  │ 进程管理 │  │ 内存管理 │  │ 文件系统│  │  网络协议栈  │    │
│  │ (调度)  │  │ (MMU)   │  │ (VFS)   │  │  (TCP/IP)   │    │
│  │         │  │         │  │         │  │             │    │
│  │ Namespace│  │ Cgroups │  │ Overlay │  │ netfilter   │    │
│  │ Cgroups │  │ OOM     │  │ tmpfs   │  │ conntrack   │    │
│  │ 调度器  │  │ pagecache│  │ procfs  │  │ iptables    │    │
│  └────┬────┘  └────┬────┘  └────┬────┘  └──────┬──────┘    │
│       │            │            │               │           │
│  ┌────┴────────────┴────────────┴───────────────┴────┐     │
│  │              设备驱动 / 硬件抽象层                   │     │
│  │  ├─ 块设备驱动（SCSI/NVMe）                        │     │
│  │  ├─ 字符设备驱动（串口/终端）                      │     │
│  │  ├─ 网络设备驱动（网卡）                           │     │
│  │  └─ 虚拟设备（virtio/vhost）                       │     │
│  └────────────────────────────────────────────────────┘     │
├─────────────────────────────────────────────────────────────┤
│                      硬件层                                  │
│     CPU    │    内存    │    磁盘    │    网卡    │  其他   │
└─────────────────────────────────────────────────────────────┘

用户空间与内核空间切换：
┌──────────────┐      syscall      ┌──────────────┐
│  用户空间     │  ──────────────►  │  内核空间     │
│  应用程序     │      int 0x80     │  系统调用处理  │
│              │   或 syscall 指令  │              │
│              │ ◄────────────────  │              │
└──────────────┘    返回结果        └──────────────┘
```

### 21.1.2 系统调用机制

```bash
# 查看系统调用表
cat /usr/include/asm/unistd_64.h | grep __NR_

# 跟踪进程的系统调用
strace -c ls

# 查看某个系统调用的手册
man 2 clone
man 2 unshare
man 2 setns
```

---

## 21.2 进程管理

### 21.2.1 进程与线程

```bash
# 查看进程树
pstree -p

# 查看进程详细信息
ps auxf

# 查看线程
ps -eLf

# 查看进程命名空间
ls -la /proc/self/ns/

# 查看某个进程的命名空间
ls -la /proc/<pid>/ns/

# 查看进程树（包含命名空间信息）
ps aux -o pid,ppid,nspid,nsipc,nsmnt,nsnet,nspid,nsuser,nsuts
```

**Linux 进程状态**：

| 状态 | 代码 | 说明 | 容器场景 |
|------|------|------|---------|
| 运行 | R | 正在运行或可运行 | 正常 |
| 可中断睡眠 | S | 等待事件（可被信号唤醒） | I/O 等待 |
| 不可中断睡眠 | D | 通常在进行 I/O | 磁盘 I/O |
| 僵尸 | Z | 子进程已终止但未被回收 | 需要处理 |
| 停止 | T | 被信号停止 | 调试 |
| 追踪停止 | t | 被调试器停止 | strace |

### 21.2.2 调度器与 CFS

Linux 使用完全公平调度器（CFS）作为默认调度策略。

```bash
# 查看进程调度策略
chrt -p <pid>

# 调度策略类型
# SCHED_FIFO (1): 实时 FIFO，优先级最高
# SCHED_RR (2): 实时轮询
# SCHED_OTHER (0): 普通 CFS（默认）
# SCHED_BATCH (3): 批处理，适合 CPU 密集型
# SCHED_IDLE (5): 空闲，最低优先级

# 查看 CPU 亲和性
taskset -pc <pid>

# 设置 CPU 亲和性
sudo taskset -pc 0,1 <pid>

# 查看容器的 CFS 配置
cat /sys/fs/cgroup/cpu/kubepods/.../cpu.cfs_quota_us
cat /sys/fs/cgroup/cpu/kubepods/.../cpu.cfs_period_us
# cpu.cfs_quota_us / cpu.cfs_period_us = CPU 限制比例
# -1 表示无限制
```

**CFS 与容器的关系**：

```
K8s CPU Request → CFS shares（相对权重）
K8s CPU Limit → CFS quota/period（绝对上限）

示例：CPU Limit = 500m
├─ cpu.cfs_quota_us = 50000
├─ cpu.cfs_period_us = 100000
└─ 可用 CPU = 50000/100000 = 0.5 = 500m

CPU Request = 100m
├─ cpu.shares = 102（相对权重）
└─ 在资源竞争时，按 shares 比例分配
```

### 21.2.3 进程间通信（IPC）

```
IPC 机制
    │
    ├─ 管道（Pipe）              → 父子进程间单向通信
    ├─ 命名管道（FIFO）          → 无亲缘关系进程间通信
    ├─ 消息队列（Message Queue） → 结构化消息传递
    ├─ 共享内存（Shared Memory） → 最高效，需同步
    ├─ 信号量（Semaphore）       → 进程同步
    ├─ 信号（Signal）            → 异步通知
    ├─ 套接字（Socket）          → 网络通信
    └─ Unix Domain Socket        → 本地高效通信
```

```bash
# 查看共享内存
ipcs -m

# 查看消息队列
ipcs -q

# 查看信号量
ipcs -s

# 查看 Unix Domain Socket
ss -xlnp

# 容器 IPC Namespace 隔离
# 同一 IPC Namespace 的进程可以共享 IPC 资源
# hostIPC: true 时，Pod 与宿主机共享 IPC Namespace
```

---

## 21.3 命名空间（Namespace）详解

### 21.3.1 8 种 Namespace

| Namespace | 隔离资源 | 系统调用 | K8s 对应 |
|-----------|---------|---------|---------|
| **PID** | 进程 ID | clone(CLONE_NEWPID) | Pod 隔离 |
| **Network** | 网络设备、端口 | clone(CLONE_NEWNET) | Pod 网络 |
| **Mount** | 文件系统挂载点 | clone(CLONE_NEWNS) | 容器文件系统 |
| **UTS** | 主机名/域名 | clone(CLONE_NEWUTS) | 容器主机名 |
| **IPC** | 进程间通信 | clone(CLONE_NEWIPC) | 容器 IPC |
| **User** | 用户/组 ID | clone(CLONE_NEWUSER) | rootless 容器 |
| **Cgroup** | Cgroup 根目录 | clone(CLONE_NEWCGROUP) | 嵌套 cgroup |
| **Time** | 系统时间（实验性） | clone(CLONE_NEWTIME) | - |

```bash
# 查看当前进程的 Namespace
ls -la /proc/self/ns/

# 进入其他 Namespace
sudo nsenter --target <pid> --mount --uts --ipc --net --pid /bin/bash

# 在 K8s 中进入 Pod 的 Network Namespace
NODE=$(kubectl get pod <pod> -o jsonpath='{.spec.nodeName}')
kubectl debug node/$NODE -it --image=alpine -- nsenter -t <container-pid> -n /bin/sh
```

### 21.3.2 Namespace 与容器的关系

```
容器 = 进程 + 一组 Namespace + Cgroups + Capabilities

Docker 容器创建过程：
1. clone() 创建新进程，指定 Namespace flags
2. 设置 Cgroups 限制
3. 设置 Capabilities
4. 挂载 rootfs（OverlayFS）
5. pivot_root() 切换根目录
6. exec() 执行容器入口命令

K8s Pod 创建过程：
1. kubelet 通过 CRI 调用 containerd
2. containerd 创建 pause 容器（持有 Namespace）
3. 其他容器加入 pause 的 Namespace（share Process Namespace）
4. 设置 Cgroups
5. 启动应用容器
```

---

## 21.4 内存管理

### 21.4.1 虚拟内存与物理内存

```
进程虚拟地址空间（64位 Linux）
┌─────────────────────────────┐ 高地址（0x7FFFFFFFFFFF）
│           栈区               │  ↓ 向下增长
│              │              │
│              ▼              │
│         （空白）            │
│              ▲              │
│              │              │
│           堆区               │  ↑ 向上增长（malloc/brk/mmap）
│                             │
│         BSS 段              │  未初始化全局变量
│         数据段              │  已初始化全局变量
│         代码段              │  程序指令（只读）
├─────────────────────────────┤
│         内核空间             │  所有进程共享（直接映射物理内存）
└─────────────────────────────┘ 0x0

地址转换：
虚拟地址 → MMU → 页表 → 物理地址
         │
         ├─ TLB（转换后备缓冲器）加速
         └─ Page Fault（缺页中断）处理
```

```bash
# 查看进程内存映射
cat /proc/<pid>/maps

# 查看进程内存统计
cat /proc/<pid>/status | grep -E "VmRSS|VmSize|VmPeak|VmSwap"

# 查看系统内存
free -h
cat /proc/meminfo

# 查看内存碎片
cat /proc/buddyinfo

# 查看 OOM Score
cat /proc/<pid>/oom_score
cat /proc/<pid>/oom_score_adj  # K8s 使用这个调整 OOM 优先级
```

### 21.4.2 Cgroups v2 内存控制

```bash
# Cgroups v2 统一层级
ls /sys/fs/cgroup/

# 容器内存限制路径（Cgroups v2）
ls /sys/fs/cgroup/kubepods.slice/

# 查看容器内存限制
cat /sys/fs/cgroup/kubepods.slice/.../memory.max
cat /sys/fs/cgroup/kubepods.slice/.../memory.high
cat /sys/fs/cgroup/kubepods.slice/.../memory.current

# OOM 控制
cat /sys/fs/cgroup/kubepods.slice/.../memory.oom.group
```

**内存限制参数对比**：

| 参数 | v1 | v2 | 说明 | K8s 对应 |
|------|----|----|------|---------|
| 硬限制 | memory.limit_in_bytes | memory.max | 超过即 OOM | limits.memory |
| 软限制 | memory.soft_limit_in_bytes | memory.high | 开始回收 | - |
| 当前使用 | memory.usage_in_bytes | memory.current | 实时用量 | - |
| OOM 控制 | memory.oom_control | memory.oom.group | 是否组内 OOM | - |
| 最低保证 | - | memory.min | 不被回收 | requests.memory |

### 21.4.3 OOM Killer 机制

```
OOM Killer 流程：

1. 系统内存不足
     │
     ▼
2. 扫描所有进程，计算 oom_score
   oom_score = 10 * %内存占用 + oom_score_adj
     │
     ▼
3. 选择 oom_score 最高的进程杀死
     │
     ▼
4. 释放内存，系统继续运行

K8s 中的 OOM：
- 容器超过 memory.limit → 容器被 OOMKilled
- Pod 状态：OOMKilled
- 解决方案：增加 limits.memory 或优化内存使用

调整 OOM 优先级：
- K8s QoS：Guaranteed > Burstable > BestEffort
- Guaranteed Pod 的 oom_score_adj = -998（最不容易被杀）
- BestEffort Pod 的 oom_score_adj = 1000（最容易被杀）
```

---

## 21.5 文件系统

### 21.5.1 VFS 与文件系统类型

```
用户空间
    │
    ▼
系统调用 (open/read/write/close)
    │
    ▼
VFS (虚拟文件系统层)
    │
    ├─► ext4    → 日志文件系统，默认
    ├─► XFS     → 大文件、高并发
    ├─► btrfs   → 写时复制，快照
    ├─► tmpfs   → 内存文件系统
    ├─► overlayfs → 容器核心（分层）
    └─► procfs/sysfs → 内核接口
```

```bash
# 查看挂载的文件系统
mount | grep overlay
mount | grep tmpfs

# 查看文件系统使用
df -Th

# 查看 inode 使用
df -i

# 查看 ext4 超级块信息
dumpe2fs /dev/sda1 | head -20

# 查看 XFS 信息
xfs_info /dev/sdb1
```

### 21.5.2 OverlayFS：容器文件系统核心

```
OverlayFS 分层结构

┌─────────────────────────────┐
│      容器可写层 (Upper)      │  ← 运行时修改（新增/修改/删除）
├─────────────────────────────┤
│      镜像层 N (Lower_N)      │  ← 应用层
├─────────────────────────────┤
│      ...                    │
├─────────────────────────────┤
│      镜像层 1 (Lower_1)      │  ← 基础镜像（如 Alpine）
├─────────────────────────────┤
│      合并视图 (Merged)       │  ← 容器看到的统一文件系统
└─────────────────────────────┘

文件访问规则：
1. 读取：从 Upper 开始找，找不到继续 Lower
2. 写入：写入 Upper（Copy-on-Write）
3. 删除：在 Upper 创建 whiteout 文件标记删除

Docker 镜像层：
Layer 1: FROM alpine:latest
Layer 2: RUN apk add python3
Layer 3: COPY app.py /app/
Layer 4: 容器运行时的可写层
```

```bash
# 查看容器的 overlay 挂载
mount | grep overlay

# 示例输出：
# overlay on /var/lib/containerd/.../merged type overlay (...)
# lowerdir=/layer1:/layer2:/layer3,upperdir=/diff,workdir=/work

# 查看容器文件系统层
ls -la /var/lib/containerd/io.containerd.snapshotter.v1.overlayfs/snapshots/

# 手动创建 overlay 挂载
mkdir -p /tmp/overlay/{lower1,lower2,upper,work,merged}
echo "from lower1" > /tmp/overlay/lower1/file.txt
echo "from lower2" > /tmp/overlay/lower2/file2.txt

sudo mount -t overlay overlay \
  -o lowerdir=/tmp/overlay/lower1:/tmp/overlay/lower2,\
upperdir=/tmp/overlay/upper,\
workdir=/tmp/overlay/work \
  /tmp/overlay/merged

ls /tmp/overlay/merged/
# file.txt  file2.txt
```

---

## 21.6 系统调用与容器安全

### 21.6.1 容器相关系统调用

| 系统调用 | 功能 | 容器安全关联 |
|---------|------|-----------|
| `clone()` | 创建进程/线程，可指定 Namespace | 容器创建核心 |
| `setns()` | 进入 Namespace | `nsenter` 原理 |
| `unshare()` | 脱离并创建新 Namespace | 容器隔离 |
| `execve()` | 执行程序 | 容器启动 |
| `open()` | 打开文件 | 文件访问审计 |
| `socket()` | 创建套接字 | 网络监控 |
| `mount()` | 挂载文件系统 | 容器逃逸手段 |
| `ptrace()` | 进程跟踪调试 | 危险能力（SYS_PTRACE） |
| `setuid()` | 设置用户 ID | 提权检测 |
| `capset()` | 设置 capabilities | 权限控制 |

### 21.6.2 使用 strace 分析容器行为

```bash
# 跟踪容器进程的系统调用
sudo strace -p <container-pid>

# 跟踪并过滤特定系统调用
sudo strace -e trace=network -p <container-pid>
sudo strace -e trace=file -p <container-pid>
sudo strace -e trace=process -p <container-pid>

# 完整跟踪并保存
sudo strace -f -o /tmp/strace.log -p <container-pid>

# 统计系统调用频率
sudo strace -c -p <container-pid>

# 跟踪新启动的容器
sudo strace -f -e trace=clone,setns,unshare,mount docker run --rm nginx

# 查看容器内进程的系统调用（从宿主机）
sudo strace -f -p $(docker inspect -f '{{.State.Pid}}' <container>)
```

---

## 21.7 proc 文件系统

### 21.7.1 /proc 核心文件

```bash
# 进程信息
/proc/<pid>/cmdline      # 启动命令（以 \0 分隔）
/proc/<pid>/exe          # 可执行文件符号链接
/proc/<pid>/cwd          # 当前工作目录
/proc/<pid>/environ      # 环境变量（以 \0 分隔）
/proc/<pid>/fd/          # 打开的文件描述符（符号链接）
/proc/<pid>/fdinfo/      # 文件描述符详细信息
/proc/<pid>/maps         # 内存映射
/proc/<pid>/status       # 进程状态（Name, State, PID, VmRSS 等）
/proc/<pid>/ns/          # 命名空间（符号链接）
/proc/<pid>/cgroup       # Cgroups 归属
/proc/<pid>/mounts       # 挂载点
/proc/<pid>/mountinfo    # 详细挂载信息

# 系统信息
/proc/cpuinfo            # CPU 信息
/proc/meminfo            # 内存信息
/proc/loadavg            # 系统负载
/proc/stat               # 内核统计
/proc/sys/               # 内核参数（可读写）
/proc/net/               # 网络统计和配置
/proc/sys/kernel/        # 内核行为参数
```

### 21.7.2 /proc 与容器安全

```bash
# 容器内看到的 /proc 是宿主机的（除非使用 PID namespace 隔离）
# 这是容器逃逸的关键点之一

# 从容器内读取宿主机进程信息
docker run --rm ubuntu cat /proc/1/cmdline
# 输出可能是 /sbin/init（宿主机 init）

# 使用 --pid=host 时，容器直接看到宿主机所有进程
docker run --rm --pid=host ubuntu ps aux

# K8s 中 hostPID: true 的 Pod 同样危险
# 可以看到宿主机所有进程，包括 kubelet、容器运行时

# 安全建议：
# - 绝不使用 hostPID: true（除非特殊调试场景）
# - 使用 readOnlyRootFilesystem 限制 /proc 写入
# - 使用 Seccomp 限制对 /proc 的敏感操作
```

---

## 21.8 Linux 系统启动流程

```
BIOS/UEFI
    │
    ▼ 硬件自检，加载 Bootloader
GRUB2
    │
    ▼ 显示菜单，加载 Linux Kernel
Linux Kernel (vmlinuz)
    │
    ├─ 解压自身
    ├─ 初始化内存管理（页表）
    ├─ 加载内置驱动
    │
    ▼
initramfs (临时根文件系统)
    │
    ├─ 加载必要的驱动模块
    ├─ 挂载真实根文件系统
    │
    ▼
systemd (PID 1)
    │
    ├─ 执行 default.target
    ├─ 启动基础服务（udev、network、sshd）
    ├─ 挂载所有文件系统（/etc/fstab）
    │
    ▼
用户登录 / 容器启动
```

**Systemd 与容器**：

```bash
# 容器内的 PID 1
# 传统：/bin/bash（信号处理有问题，僵尸进程不回收）
# 现代：tini/dumb-init/systemd

# 使用 tini 作为 init
docker run --init nginx

# K8s 中 Pod 的 PID 1 就是容器的 entrypoint
kubectl exec <pod> -- ps aux
# PID 1 应该是应用主进程

# 如果 entrypoint 是 shell 脚本，建议使用 exec 启动主进程
# 否则主进程不是 PID 1，信号处理会有问题
```

---

## 21.9 网络内核机制

### 21.9.1 Netfilter 框架

```
Netfilter 钩子点（数据包流经路径）：

        入站数据包                    出站数据包
             │                            │
             ▼                            │
    ┌─────────────────┐                   │
    │   PREROUTING    │ ◄── DNAT（端口转发）│
    │   (路由前)       │                   │
    └────────┬────────┘                   │
             │                            │
             ▼ 路由决策                    │
    ┌─────────────────┐                   │
    │    FORWARD      │ ◄── 转发规则      │
    │   (转发)         │                   │
    └────────┬────────┘                   │
             │                            │
             ▼                            ▼
    ┌─────────────────┐          ┌─────────────────┐
    │     INPUT       │          │    OUTPUT       │
    │   (本机接收)     │          │   (本机发出)     │
    └────────┬────────┘          └────────┬────────┘
             │                            │
             ▼                            ▼
    ┌─────────────────┐          ┌─────────────────┐
    │    用户空间      │          │  POSTROUTING    │
    │   应用程序       │          │  (路由后)        │
    └─────────────────┘          │ ◄── SNAT/MASQUERADE│
                                 └─────────────────┘

iptables 表与链：
├─ raw 表：PREROUTING、OUTPUT
├─ mangle 表：PREROUTING、INPUT、FORWARD、OUTPUT、POSTROUTING
├─ nat 表：PREROUTING、INPUT、OUTPUT、POSTROUTING
├─ filter 表：INPUT、FORWARD、OUTPUT
└─ security 表：INPUT、FORWARD、OUTPUT
```

```bash
# 查看 iptables 规则
sudo iptables -t nat -L -n -v | head -20
sudo iptables -t filter -L -n -v | head -20

# 查看 KUBE-SERVICES 链（kube-proxy 创建的 Service 规则）
sudo iptables -t nat -L KUBE-SERVICES -n -v

# 查看 conntrack 连接追踪
sudo conntrack -L | head -20
sudo conntrack -L -p tcp | wc -l

# 查看 nftables（iptables 的后继者）
sudo nft list ruleset | head -50
```

### 21.9.2 kube-proxy 模式对比

| 模式 | 原理 | 性能 | 适用场景 |
|------|------|------|---------|
| **iptables** | 每个 Service 创建 iptables 规则 | 中（O(n)规则遍历） | 小型集群 |
| **ipvs** | 使用 Linux IPVS 内核模块 | 高（O(1) hash） | 大型集群 |
| **nftables** | 使用 nftables（iptables 后继） | 高 | 新集群 |
| **kernelspace** | 用户空间实现（如 Cilium） | 极高 | eBPF 环境 |

```bash
# 查看当前 kube-proxy 模式
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode

# 修改 kube-proxy 模式
kubectl edit configmap kube-proxy -n kube-system
# 修改 mode: "ipvs"
# 然后重启 kube-proxy Pod
```

---

## 21.10 本章实验

### 实验 21.1：手动创建 Namespace 隔离的进程（15 分钟）

```bash
# 步骤 1：创建新的 PID + Mount + UTS Namespace
sudo unshare --pid --fork --mount-proc --uts /bin/bash

# 步骤 2：在新 Namespace 中查看进程
ps aux
# 应该只看到当前 bash 和 ps

# 步骤 3：设置新的主机名
hostname isolated-container
hostname

# 步骤 4：创建新的 Mount Namespace 并挂载 tmpfs
mkdir /tmp/isolated-mnt
mount -t tmpfs none /tmp/isolated-mnt
echo "hello" > /tmp/isolated-mnt/test.txt

# 步骤 5：在另一个终端验证隔离
cat /tmp/isolated-mnt/test.txt 2>/dev/null || echo "宿主机看不到！"

# 步骤 6：退出 Namespace
exit
```

### 实验 21.2：分析容器 OverlayFS（15 分钟）

```bash
# 步骤 1：运行一个容器
docker run -d --name test-nginx nginx:alpine

# 步骤 2：查看 overlay 挂载信息
MERGED=$(docker inspect test-nginx -f '{{.GraphDriver.Data.MergedDir}}')
LOWER=$(docker inspect test-nginx -f '{{.GraphDriver.Data.LowerDir}}')
UPPER=$(docker inspect test-nginx -f '{{.GraphDriver.Data.UpperDir}}')

echo "Merged: $MERGED"
echo "Lower: $LOWER"
echo "Upper: $UPPER"

# 步骤 3：查看只读层
echo "=== Lower layers ==="
echo $LOWER | tr ':' '\n'

# 步骤 4：在容器内修改文件
docker exec test-nginx sh -c 'echo modified > /usr/share/nginx/html/index.html'

# 步骤 5：查看可写层的变化
echo "=== Upper layer changes ==="
cat $UPPER/usr/share/nginx/html/index.html

# 步骤 6：清理
docker rm -f test-nginx
```

### 实验 21.3：使用 strace 分析容器系统调用（15 分钟）

```bash
# 步骤 1：启动容器
docker run -d --name trace-me ubuntu sleep 3600

# 步骤 2：获取 PID
PID=$(docker inspect trace-me -f '{{.State.Pid}}')
echo "Container PID: $PID"

# 步骤 3：跟踪系统调用（另开终端）
sudo strace -e trace=network,file,process -p $PID

# 步骤 4：在容器内执行操作
docker exec trace-me wget -q http://example.com

# 步骤 5：观察 strace 输出

# 步骤 6：统计高频系统调用
sudo strace -c -p $PID &
sleep 10
sudo kill %1

# 步骤 7：清理
docker rm -f trace-me
```

### 实验 21.4：Cgroups v2 内存限制实验（15 分钟）

```bash
# 步骤 1：创建测试 cgroup
sudo mkdir -p /sys/fs/cgroup/test-mem

# 步骤 2：设置内存限制（10MB）
echo 10485760 | sudo tee /sys/fs/cgroup/test-mem/memory.max

# 步骤 3：将当前 shell 加入 cgroup
echo $$ | sudo tee /sys/fs/cgroup/test-mem/cgroup.procs

# 步骤 4：尝试分配超过限制的内存
python3 -c "a = 'x' * (20 * 1024 * 1024)"
# 应该被 OOM Killed

# 步骤 5：清理
sudo rmdir /sys/fs/cgroup/test-mem
```

---

## 21.11 内核安全特性与容器加固

### 21.11.1 Linux 安全模块 (LSM)

Linux 提供多种安全模块，可以组合使用：

```
┌─────────────────────────────────────────────────────────────┐
│                    Linux 安全模块栈                          │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  应用层        │  AppArmor / SELinux (强制访问控制 MAC)      │
│  系统调用层    │  Seccomp (系统调用过滤)                      │
│  内核对象层    │  Capabilities (细粒度特权)                   │
│  网络层        │  Netfilter / eBPF (网络策略)                │
│  文件系统层    │  Mount Namespaces / readOnlyRootFilesystem  │
│                                                              │
│  组合使用示例（K8s 最严格配置）：                            │
│  Seccomp(RuntimeDefault) + AppArmor + Capabilities(drop ALL) │
│  + runAsNonRoot + readOnlyRootFilesystem                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### 21.11.2 Seccomp 深入解析

Seccomp（Secure Computing Mode）限制进程可调用的系统调用：

```
Seccomp 模式：

┌─────────────┐    ┌─────────────┐    ┌─────────────────────────┐
│  Disabled   │───►│  Runtime    │───►│  Custom Profile         │
│  (无限制)    │    │  (Default)  │    │  (自定义白名单)          │
│             │    │             │    │                         │
│             │    │ 允许 ~300   │    │ 精确控制每个 syscall    │
│             │    │ 个安全调用  │    │ 可自定义错误处理         │
└─────────────┘    └─────────────┘    └─────────────────────────┘
```

**K8s 中的 Seccomp 配置**：

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: seccomp-pod
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault  # 使用容器运行时的默认策略
      # type: Localhost
      # localhostProfile: profiles/custom.json
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
```

**自定义 Seccomp Profile 示例**：

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_X86"],
  "syscalls": [
    {
      "names": [
        "accept", "accept4", "bind", "clone", "close",
        "connect", "epoll_create", "epoll_create1", "epoll_ctl",
        "epoll_pwait", "epoll_wait", "exit", "exit_group",
        "fcntl", "fstat", "futex", "getpid", "getrandom",
        "getsockname", "getsockopt", "ioctl", "listen",
        "mmap", "mprotect", "munmap", "nanosleep", "openat",
        "read", "recvfrom", "recvmsg", "rt_sigaction",
        "rt_sigprocmask", "rt_sigreturn", "select", "sendmsg",
        "sendto", "setitimer", "setsockopt", "sigaltstack",
        "socket", "socketpair", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

### 21.11.3 AppArmor 配置实战

```bash
# 1. 查看系统是否支持 AppArmor
aa-status

# 2. 创建自定义 profile
sudo tee /etc/apparmor.d/k8s-restricted <<'EOF'
#include <tunables/global>

profile k8s-restricted flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  
  # 允许基本文件访问
  file,
  
  # 禁止写入敏感目录
  deny /etc/** w,
  deny /usr/** w,
  deny /bin/** w,
  deny /sbin/** w,
  
  # 限制网络
  network inet stream,
  network inet6 stream,
  deny network raw,
  
  # 禁止加载内核模块
  deny /lib/modules/** r,
  deny capability sys_module,
  
  # 禁止 ptrace
  deny ptrace (read, readby, tracedby),
  
  # 限制挂载
  deny mount,
}
EOF

# 3. 加载 profile
sudo apparmor_parser -r /etc/apparmor.d/k8s-restricted

# 4. 在 K8s 中使用
# Pod annotation:
# container.apparmor.security.beta.kubernetes.io/container-name: localhost/k8s-restricted
```

### 21.11.4 Capabilities 详解

```
Linux Capabilities 与 K8s 安全上下文映射：

┌─────────────────────────────────────────────────────────────┐
│ 危险 Capabilities（应始终 drop）                             │
│  CAP_SYS_ADMIN   │ 相当于 root，可执行所有管理操作           │
│  CAP_SYS_PTRACE  │ 可调试其他进程，用于容器逃逸              │
│  CAP_SYS_MODULE  │ 可加载内核模块                          │
│  CAP_DAC_READ_SEARCH │ 绕过文件读权限检查                   │
│  CAP_SETUID      │ 可任意修改进程 UID                       │
│  CAP_SETGID      │ 可任意修改进程 GID                       │
├─────────────────────────────────────────────────────────────┤
│ 常用保留 Capabilities                                        │
│  CAP_NET_BIND_SERVICE │ 绑定 <1024 端口（非 root）         │
│  CAP_CHOWN        │ 修改文件所有者                         │
│  CAP_KILL         │ 发送信号给其他进程                     │
└─────────────────────────────────────────────────────────────┘
```

---

## 21.12 系统监控与性能分析

### 21.12.1 容器资源监控指标

```bash
# cgroup v2 资源统计
cat /sys/fs/cgroup/system.slice/kubelet.service/memory.current
cat /sys/fs/cgroup/system.slice/kubelet.service/memory.max
cat /sys/fs/cgroup/system.slice/kubelet.service/cpu.stat

# Pod cgroup（containerd + cgroup v2）
ls /sys/fs/cgroup/kubepods.slice/
cat /sys/fs/cgroup/kubepods.slice/kubepods-burstable.slice/.../memory.current

# 进程级资源使用
systemd-cgtop  # 按 cgroup 排序的资源使用 top
cadvisor       # Google 容器资源监控工具
```

### 21.12.2 使用 eBPF 进行系统监控

```bash
# 使用 bcc-tools 监控容器性能

# 1. 容器 CPU 使用分布
sudo /usr/share/bcc/tools/offcputime -p $(pgrep -n containerd-shim) 10

# 2. 容器 I/O 延迟
sudo /usr/share/bcc/tools/biolatency -p $(pgrep -n containerd-shim) 10

# 3. 文件系统访问热点
sudo /usr/share/bcc-tools/fsslower -p $(pgrep -n containerd-shim) 1

# 4. 容器网络延迟
sudo /usr/share/bcc-tools/tcplife

# 5. 系统调用延迟直方图
sudo /usr/share/bcc/tools/funccount 'c:open*'
sudo /usr/share/bcc/tools/funccount 'c:connect'
```

### 21.12.3 内核参数调优检查清单

```bash
#!/bin/bash
# kernel-tuning-check.sh

echo "=== K8s 节点内核调优检查 ==="

# 1. 内存调优
echo "--- 内存子系统 ---"
echo "vm.overcommit_memory = $(sysctl -n vm.overcommit_memory)"  # 应=1
echo "vm.panic_on_oom = $(sysctl -n vm.panic_on_oom)"            # 应=0
echo "vm.swappiness = $(sysctl -n vm.swappiness)"                # 应=0-10

# 2. 网络调优
echo "--- 网络子系统 ---"
echo "net.ipv4.ip_forward = $(sysctl -n net.ipv4.ip_forward)"    # 应=1
echo "net.bridge.bridge-nf-call-iptables = $(sysctl -n net.bridge.bridge-nf-call-iptables)"  # 应=1
echo "net.netfilter.nf_conntrack_max = $(sysctl -n net.netfilter.nf_conntrack_max)"

# 3. 文件描述符
echo "--- 文件描述符 ---"
echo "fs.file-max = $(sysctl -n fs.file-max)"
echo "fs.inotify.max_user_watches = $(sysctl -n fs.inotify.max_user_watches)"  # 应=524288
echo "fs.inotify.max_user_instances = $(sysctl -n fs.inotify.max_user_instances)"  # 应=8192

# 4. PID 限制
echo "--- PID 限制 ---"
echo "kernel.pid_max = $(sysctl -n kernel.pid_max)"  # 应>=32768

# 5. 检查 kubelet 配置
echo "--- kubelet 配置 ---"
grep -E "protectKernelDefaults|serializeImagePulls|cpuManagerPolicy" /var/lib/kubelet/config.yaml 2>/dev/null || echo "kubelet config not found"
```

### 21.12.4 容器运行时选择对比

| 特性 | containerd | CRI-O | Docker |
|------|-----------|-------|--------|
| 设计目标 | 通用容器运行时 | 专为 K8s 设计 | 开发者工具 |
| CRI 支持 | 原生 | 原生 | 通过 cri-dockerd |
| 镜像格式 | OCI | OCI | OCI |
| 安全特性 | 完整 | 完整（更精简攻击面） | 较复杂 |
| 资源占用 | 中等 | 最低 | 较高 |
| 维护复杂度 | 低 | 低 | 较高 |
| 推荐场景 | 通用生产环境 | 高安全要求环境 | 开发测试 |

**CRI-O 安全优势**：
- 更小的代码库 → 更小的攻击面
- 专为 K8s 设计，无多余功能
- 默认启用更多安全选项
- 更快的启动时间

```bash
# CRI-O 配置（/etc/crio/crio.conf）
[crio.runtime]
default_ulimits = ["nofile=65535:65535"]
log_size_max = 134217728  # 128MB 日志限制
pids_limit = 2048

# 默认 seccomp profile
default_sysctls = [
    "net.ipv4.ping_group_range=0 0",
]
```

---

## 21.13 本章练习题

### 选择题

1. **Linux 中创建新 Namespace 的系统调用是什么？**
   - A. fork()
   - B. clone()
   - C. execve()
   - D. setns()

2. **OverlayFS 中，容器的修改存储在哪个层？**
   - A. Lower
   - B. Upper
   - C. Merged
   - D. Workdir

3. **Cgroups v2 相比 v1 的主要变化是什么？**
   - A. 支持更多子系统
   - B. 统一层级结构
   - C. 性能更好
   - D. 配置更简单

4. **OOM Killer 选择杀死哪个进程的依据是什么？**
   - A. PID 最大
   - B. oom_score 最高
   - C. 运行时间最长
   - D. CPU 占用最高

### 简答题

1. 解释 Namespace 和 Cgroups 的区别。它们分别解决什么问题？

2. 描述 OverlayFS 的工作原理。为什么它是容器文件系统的理想选择？

3. 解释 Linux 的 OOM Killer 机制。K8s 中如何控制 Pod 的 OOM 优先级？

4. 描述数据包经过 Linux 网络栈的完整流程。iptables 的 PREROUTING、FORWARD、POSTROUTING 分别在什么阶段处理？

### 实践题

1. **Namespace 实验**（15 分钟）：
   - 使用 unshare 创建新的 PID、Mount、UTS Namespace
   - 验证进程隔离、文件系统隔离和主机名隔离
   - 使用 nsenter 进入已有容器的 Namespace

2. **OverlayFS 分析**（15 分钟）：
   - 运行一个容器并查看其 OverlayFS 挂载
   - 在容器内修改文件，观察 Upper 层的变化
   - 理解 Copy-on-Write 机制

3. **系统调用跟踪**（15 分钟）：
   - 使用 strace 跟踪容器的系统调用
   - 分析网络相关调用（socket、connect、send、recv）
   - 统计高频系统调用并分析

---

## 21.14 K8s 与内核版本兼容性

### 21.14.1 版本兼容性矩阵

| K8s 版本 | 推荐内核 | 最低内核 | 关键特性需求 |
|----------|----------|----------|-------------|
| 1.25 | 5.15+ | 5.4 | cgroup v2 支持 |
| 1.26 | 5.15+ | 5.4 | 用户命名空间 (Alpha) |
| 1.27 | 5.15+ | 5.4 | 用户命名空间 (Beta) |
| 1.28 | 5.19+ | 5.4 | 更好的 eBPF 支持 |
| 1.29 | 6.1+ | 5.4 | 内存 QoS (cgroup v2) |

### 21.14.2 内核升级决策

```bash
# 检查当前内核版本
uname -r

# 检查 cgroup 版本
stat -fc %T /sys/fs/cgroup/
# 输出 "cgroup2fs" = cgroup v2
# 输出 "tmpfs" = cgroup v1

# 检查 eBPF 支持
ls /sys/kernel/debug/tracing/
cat /proc/kallsyms | grep bpf

# 检查关键特性
zcat /proc/config.gz | grep -E "CGROUP|PSI|BPF"
```

**何时需要升级内核**：
1. 存在已知安全漏洞（Dirty Pipe、Dirty COW 等）
2. 需要使用 cgroup v2 的 Memory QoS 功能
3. 需要更好的 eBPF 支持（Cilium 新版本）
4. 需要使用用户命名空间隔离（Podman/Kata）

---

## 21.15 容器运行时深入对比

### 21.15.1 containerd vs CRI-O vs Docker

| 维度 | containerd | CRI-O | Docker Engine |
|------|-----------|-------|---------------|
| CRI 支持 | 原生 | 原生 | 通过 cri-dockerd |
| 设计目标 | 通用容器运行时 | 专为 K8s | 开发者工具 |
| 代码量 | ~20 万行 | ~10 万行 | ~100 万行+ |
| 攻击面 | 中等 | 最小 | 较大 |
| 镜像管理 | 完整 | 完整 | 完整 |
| 快照器 | overlayfs, zfs, btrfs | overlayfs | overlayfs |
| 社区 | CNCF 毕业 | K8s 社区 | Docker/Mirantis |
| 推荐场景 | 通用生产环境 | 高安全要求 | 开发测试 |

### 21.15.2 运行时安全加固

```toml
# /etc/containerd/config.toml 安全配置
[plugins."io.containerd.grpc.v1.cri"]
  # 禁用无用插件
  disable_apparmor = false
  disable_cgroup = false
  disable_proc_mount = false
  
  [plugins."io.containerd.grpc.v1.cri".containerd]
    default_runtime_name = "runc"
    
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        SystemdCgroup = true
        # 启用 seccomp
        SeccompProfile = ""
        # 启用 AppArmor
        AppArmorProfile = "cri-containerd.apparmor.d"
        
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
      runtime_type = "io.containerd.runsc.v1"
```

---

## 21.16 性能调优检查清单

### 21.16.1 节点级性能优化

```bash
# CPU 优化
echo 'performance' | sudo tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# 内存优化
echo 'never' | sudo tee /sys/kernel/mm/transparent_hugepage/enabled
echo 0 | sudo tee /proc/sys/vm/swappiness

# 磁盘 I/O 优化
echo 'none' | sudo tee /sys/block/sda/queue/scheduler  # NVMe
echo 'mq-deadline' | sudo tee /sys/block/sda/queue/scheduler  # SSD

# 网络优化（大流量场景）
# 增加网卡队列
ethtool -L eth0 combined 8
# 启用 RPS/RFS
echo f | sudo tee /sys/class/net/eth0/queues/rx-0/rps_cpus
```

### 21.16.2 K8s 工作负载性能调优

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| CPU Manager | 静态分配 CPU | `static`（CPU 密集型） |
| Topology Manager | NUMA 感知调度 | `restricted` |
| Memory QoS | cgroup v2 内存控制 | 启用 |
| HugePages | 大页内存 | 数据库/缓存类应用 |
| PID 限制 | 防止 PID 耗尽 | 根据应用设置 |

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: performance-pod
spec:
  containers:
  - name: app
    image: redis:7-alpine
    resources:
      limits:
        cpu: "4"
        memory: "8Gi"
        hugepages-2Mi: "1Gi"
      requests:
        cpu: "4"
        memory: "8Gi"
    securityContext:
      seccompProfile:
        type: RuntimeDefault
  nodeSelector:
    node-type: compute
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "compute"
    effect: "NoSchedule"
```

---

## 21.12 本章小结

| 主题 | 核心要点 |
|------|---------|
| **内核架构** | 用户空间/内核空间，系统调用接口 |
| **进程管理** | CFS 调度，Namespace 隔离，8 种 Namespace |
| **内存管理** | 虚拟内存，Cgroups v2 限制，OOM Killer |
| **文件系统** | VFS，OverlayFS 分层，容器镜像原理 |
| **系统调用** | clone/unshare/setns 是容器核心，strace 分析 |
| **procfs** | /proc 暴露内核信息，容器安全关注点 |
| **网络栈** | Netfilter 框架，iptables/ipvs/nftables |
| **启动流程** | BIOS → Kernel → initramfs → systemd |

**推荐阅读**：
- 《Linux 内核设计与实现》— Robert Love
- 《深入理解 Linux 内核》— Daniel P. Bovet
- 《容器技术入门与实战》— 人民邮电出版社
- Linux 内核文档：https://www.kernel.org/doc/html/latest/

**下一步**：将本章的操作系统知识与前面的 K8s 安全、网络、容器逃逸章节结合，形成完整的云原生安全知识体系。
