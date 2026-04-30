# 第1章 Linux 与容器基础

> **本章目标**：建立对容器技术底层原理的深刻理解。我们将从 Linux 内核的核心机制——Namespace、Cgroups、Capabilities、Seccomp 出发，逐步理解容器隔离的本质，最终掌握安全的容器构建和运行方法。
>
> 读完本章后，你应该能够解释"容器是什么"、"容器与虚拟机的区别"、"为什么容器不是完全安全的"，并能够编写符合生产安全标准的 Dockerfile。

---

## 1.1 容器技术的历史与演进

### 1.1.1 从 chroot 到容器

容器技术并非凭空出现，它经历了近四十年的演进：

| 年份 | 技术 | 里程碑 |
|------|------|--------|
| 1979 | chroot | 第一个文件系统隔离机制 |
| 2000 | FreeBSD Jail | 系统级隔离 |
| 2001 | Linux VServer | 早期的操作系统级虚拟化 |
| 2002 | Namespace 进入 Linux 2.4.19 | 资源视图隔离 |
| 2006 | Google Process Containers | Cgroups 的前身 |
| 2007 | Cgroups 进入 Linux 2.6.24 | 资源限制机制 |
| 2008 | LXC（Linux Containers） | 第一个完整的容器实现 |
| 2013 | Docker 发布 | 容器大众化 |
| 2015 | OCI 成立 | 容器标准化 |
| 2016 | containerd 捐赠给 CNCF | 容器运行时标准化 |

**为什么容器在 Docker 出现后才爆发？**

LXC 已经具备了现代容器的核心能力，但它使用复杂、缺乏镜像标准、可移植性差。Docker 的创新在于：
1. **镜像分层格式**：解决了应用交付的一致性问题
2. **简单的用户界面**：`docker run` 替代了复杂的 LXC 配置
3. **Registry 生态**：Docker Hub 让镜像分享变得简单
4. **Build 系统**：Dockerfile 标准化了应用构建流程

### 1.1.2 容器与虚拟机的本质区别

```
┌─────────────────────────────────────────┐
│              虚拟机架构                  │
│                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
│  │  App A  │  │  App B  │  │  App C  │ │
│  │ Bin/Lib │  │ Bin/Lib │  │ Bin/Lib │ │
│  ├─────────┤  ├─────────┤  ├─────────┤ │
│  │Guest OS │  │Guest OS │  │Guest OS │ │
│  │(内核)   │  │(内核)   │  │(内核)   │ │
│  ├─────────┴──┴─────────┴──┴─────────┤ │
│  │          Hypervisor                 │ │
│  │    (KVM / VMware / Xen)             │ │
│  ├─────────────────────────────────────┤ │
│  │          Host OS                     │ │
│  │          (内核 + 硬件驱动)           │ │
│  └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘

┌─────────────────────────────────────────┐
│              容器架构                    │
│                                         │
│  ┌─────────┐  ┌─────────┐  ┌─────────┐ │
│  │  App A  │  │  App B  │  │  App C  │ │
│  │ Bin/Lib │  │ Bin/Lib │  │ Bin/Lib │ │
│  ├─────────┤  ├─────────┤  ├─────────┤ │
│  │Container│  │Container│  │Container│ │
│  │(隔离视图)│  │(隔离视图)│  │(隔离视图)│ │
│  ├─────────┴──┴─────────┴──┴─────────┤ │
│  │          Container Engine           │ │
│  │    (Docker / containerd / CRI-O)   │ │
│  ├─────────────────────────────────────┤ │
│  │          Host OS (共享内核)          │ │
│  │          (Namespace + Cgroups)       │ │
│  └─────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

| 对比项 | 虚拟机 | 容器 |
|--------|--------|------|
| 隔离级别 | 硬件级（完全隔离） | 操作系统级（共享内核） |
| 启动速度 | 分钟级 | 秒级甚至毫秒级 |
| 资源开销 | 大（每个VM独立内核） | 小（共享内核） |
| 性能 | 接近原生（需虚拟化开销） | 接近原生（无虚拟化开销） |
| 镜像大小 | GB 级 | MB 级 |
| 密度 | 单机 10-100 个 | 单机 100-1000 个 |
| 安全性 | 高（内核隔离） | 中（共享内核，存在逃逸风险） |
| 适用场景 | 强隔离、多操作系统 | 微服务、CI/CD、云原生 |

---

## 1.2 Linux Namespace：容器隔离的基石

### 1.2.1 什么是 Namespace

Namespace 是 Linux 内核提供的一种资源隔离机制。它不是虚拟化，而是**资源视图的隔离**——进程仍然共享同一套内核，但每个进程可以看到不同的资源集合。

Namespace 的核心设计思想来源于操作系统的一个基本问题：**如何让一组进程相信它们是系统中唯一的进程？** chroot 只能隔离文件系统视图，而 Namespace 将这种思想扩展到了所有系统资源。

### 1.2.2 系统调用与 Namespace

Linux 提供了三个与 Namespace 相关的核心系统调用：

| 系统调用 | 功能 | 说明 |
|---------|------|------|
| `clone()` | 创建新进程并指定 Namespace | 类似 fork，可传递 CLONE_NEW* 标志 |
| `unshare()` | 将当前进程移到新 Namespace | 不创建新进程，只创建新 Namespace |
| `setns()` | 将进程加入已有 Namespace | `nsenter` 命令的底层实现 |

**clone() 系统调用示例**：

```c
// clone() 创建带有新 PID Namespace 的进程
#define _GNU_SOURCE
#include <sched.h>
#include <unistd.h>
#include <stdio.h>

int child_func(void *arg) {
    printf("Child PID: %d\n", getpid());  // 在新 Namespace 中 PID = 1
    return 0;
}

int main() {
    char stack[1024 * 1024];
    // CLONE_NEWPID = 创建新的 PID Namespace
    // CLONE_NEWNS = 创建新的 Mount Namespace
    int pid = clone(child_func, stack + sizeof(stack), 
                    CLONE_NEWPID | CLONE_NEWNS | SIGCHLD, NULL);
    printf("Parent PID: %d, Child PID in parent: %d\n", getpid(), pid);
    waitpid(pid, NULL, 0);
    return 0;
}
```

```bash
# 编译运行
gcc -o ns_demo ns_demo.c
sudo ./ns_demo
# Parent PID: 1234, Child PID in parent: 1235
# Child PID: 1   <-- 在子进程的 PID Namespace 中，它认为自己是 PID 1
```

**unshare() 系统调用**：

```bash
# 使用 unshare 命令进入新的 Namespace
# --pid：新 PID Namespace
# --fork：fork 子进程执行命令
# --mount-proc：重新挂载 /proc
sudo unshare --pid --fork --mount-proc /bin/bash

# 在新 Namespace 中
ps aux
#   PID USER   COMMAND
#     1 root   /bin/bash
#    10 root   ps aux
# 只有当前 bash 和 ps 进程，看不到宿主机其他进程

# 退出 Namespace
exit
```

### 1.2.3 Linux 支持的 8 种 Namespace

| Namespace | 标志 | 隔离资源 | 引入内核版本 | 核心用途 |
|-----------|------|---------|-------------|---------|
| Mount (mnt) | CLONE_NEWNS | 文件系统挂载点 | 2.4.19 | 容器有自己的根文件系统 |
| UTS | CLONE_NEWUTS | 主机名和域名 | 2.6.19 | 容器可以有自己的 hostname |
| IPC | CLONE_NEWIPC | System V IPC、POSIX 消息队列 | 2.6.19 | 隔离共享内存和信号量 |
| PID | CLONE_NEWPID | 进程 ID | 2.6.24 | 容器内 PID 从 1 开始 |
| Network (net) | CLONE_NEWNET | 网络设备、端口、路由、防火墙 | 2.6.24 | 容器有独立的网络栈 |
| User | CLONE_NEWUSER | 用户和组 ID | 3.8 | rootless 容器的基础 |
| Cgroup | CLONE_NEWCGROUP | Cgroup 根目录 | 4.6 | 隐藏 Cgroup 信息 |
| Time | CLONE_NEWTIME | 系统时间 | 5.6 | 容器有自己的时间偏移 |

### 1.2.4 PID Namespace 深度解析

PID Namespace 是容器隔离中最重要的 Namespace 之一，因为它决定了进程在容器内的视图。

**PID Namespace 的层次结构**：

```
宿主机 PID Namespace
    │
    ├─ PID 1: systemd/init
    ├─ PID 100: containerd
    │   │
    │   └─ PID 500: containerd-shim  (作为子 Namespace 的 init)
    │       │
    │       └─ 容器 PID Namespace (child)
    │           │
    │           ├─ PID 1: nginx (容器主进程)
    │           ├─ PID 5: nginx worker
    │           └─ PID 10: /bin/sh
    │
    └─ PID 200: containerd-shim (另一个容器)
        │
        └─ 容器 PID Namespace (另一个 child)
            │
            ├─ PID 1: redis-server
            └─ PID 8: redis worker
```

**关键特性：**

1. **PID 1 的特殊性**：在 PID Namespace 中，PID 1 的进程具有类似 init 的特殊职责——回收孤儿进程。如果容器内的 PID 1 进程没有正确处理 SIGCHLD 信号，僵尸进程会累积。

2. **嵌套 Namespace**：PID Namespace 可以嵌套，形成层次结构。父 Namespace 可以看到子 Namespace 的所有进程，但子 Namespace 看不到父 Namespace 的进程。

```bash
# 宿主机查看容器进程（能看到真实 PID）
ps aux | grep nginx
# root      12345  0.0  ...  nginx: master process

# 容器内查看（只能看到 Namespace 内的 PID）
docker exec <container> ps aux
# PID   USER   COMMAND
#   1   root   nginx: master process
#   5   root   nginx: worker process

# 从宿主机查看进程的 Namespace
ls -la /proc/12345/ns/pid
# lrwxrwxrwx 1 root root 0 Jan  1 00:00 /proc/12345/ns/pid -> pid:[4026532289]
```

3. **孤儿进程回收**：当父进程先于子进程退出时，子进程成为孤儿进程。在宿主机中，孤儿进程被 init（PID 1）收养。在容器中，孤儿进程被容器内的 PID 1 收养。

```bash
# 实验：容器内产生僵尸进程
docker run --rm -it ubuntu bash
# 在容器内执行：
( sleep 1 & ) && ps aux | grep sleep
# 如果容器主进程（PID 1）是 bash，它不会回收子进程
# 子进程结束后会变成僵尸状态

# 对比：使用 tini 作为 init
docker run --rm -it --init ubuntu bash
# tini 作为 PID 1，会正确回收孤儿进程
```

### 1.2.5 Mount Namespace 与容器根文件系统

Mount Namespace 让每个容器拥有自己的挂载点视图。这是容器"有自己的文件系统"的技术基础。

**容器启动时的挂载过程**：

```bash
# 1. 创建新的 Mount Namespace
unshare --mount

# 2. 挂载容器镜像的只读层和可写层（OverlayFS）
# lowerdir=/layers/ubuntu:/layers/nginx
# upperdir=/diff
# workdir=/work
# merged=/merged

# 3. pivot_root 切换根文件系统
# 将 /merged 设为新的根，原根挂载到 /.old_root

# 4. 卸载 /.old_root
```

**宿主机 vs 容器内挂载视图对比**：

```bash
# 宿主机上查看所有挂载
mount | head -20
# sysfs on /sys type sysfs (rw,nosuid,nodev,noexec,relatime)
# proc on /proc type proc (rw,nosuid,nodev,noexec,relatime)
# /dev/sda1 on / type ext4 (rw,relatime)
# ...

# 容器内查看挂载
docker run --rm ubuntu mount
# overlay on / type overlay (...)
# proc on /proc type proc (...)
# tmpfs on /dev type tmpfs (...)
# /dev/sda1 on /etc/resolv.conf type ext4 (...)   <-- 从宿主机挂载的文件
# /dev/sda1 on /etc/hostname type ext4 (...)       <-- 从宿主机挂载的文件
```

### 1.2.6 User Namespace：rootless 容器的基础

User Namespace 是容器安全领域最重要的进展之一。它允许容器内的 root 用户映射到宿主机上的一个非特权用户。

**UID/GID 映射机制**：

```
容器内视图          宿主机视图
UID 0 (root)  ──►  UID 100000
UID 1         ──►  UID 100001
UID 1000      ──►  UID 101000
```

```bash
# 查看进程的 UID 映射
cat /proc/self/uid_map
# 输出格式：容器内起始UID 宿主机起始UID 映射范围
# 0          1000       1
# 表示：容器内 UID 0 映射到宿主机 UID 1000

# Docker 启用 User Namespace
cat /etc/docker/daemon.json
{
  "userns-remap": "default"
}

# 重启 Docker
sudo systemctl restart docker

# 查看自动创建的映射用户
grep docker /etc/subuid
# dockremap:100000:65536
# 表示 dockremap 用户的 ID 范围是 100000-165535

# 启动容器后验证
ps aux | grep nginx
# 100000    ...  nginx    # 容器内 root 映射到 UID 100000

docker exec <container> id
# uid=0(root) gid=0(root)   # 容器内仍然认为是 root
```

**User Namespace 的安全意义**：

即使攻击者从容器逃逸到宿主机，它也只有 UID 100000+ 的权限，不是真正的 root。

---

## 1.3 Linux Cgroups：资源限制

### 1.3.1 Cgroups 的设计原理

Cgroups（Control Groups）是 Linux 内核提供的资源管理机制。与 Namespace 不同，Namespace 解决的是"能看到什么"的问题，而 Cgroups 解决的是"能用多少"的问题。

**Cgroups 的两个版本**：

| 特性 | Cgroups v1 | Cgroups v2 |
|------|-----------|-----------|
| 架构 | 每个控制器独立层级 | 统一层级树 |
| 根 cgroup | 可写 | 只能控制子 cgroup |
| 进程归属 | 一个进程可在不同控制器的不同组 | 一个进程只能在同一个组 |
| 委派 | 复杂 | 简单安全 |
| 默认发行版 | CentOS 7, Ubuntu 18.04 | CentOS 8, Ubuntu 22.04 |
| 推荐 | 逐渐淘汰 | 新部署应使用 |

**Cgroups v1 层级结构**：

```
sys/fs/cgroup/
├── cpu/
│   ├── docker/
│   │   ├── container_a/
│   │   └── container_b/
│   └── system.slice/
├── memory/
│   ├── docker/
│   │   ├── container_a/
│   │   └── container_b/
│   └── system.slice/
└── blkio/
    └── ...
```

**Cgroups v2 统一层级**：

```
/sys/fs/cgroup/
├── cgroup.procs              # 当前 cgroup 的进程列表
├── cgroup.controllers        # 可用的控制器
├── cgroup.subtree_control    # 启用的子树控制器
├── memory.max                # 内存硬限制
├── memory.high               # 内存回收阈值
├── cpu.max                   # CPU 限制
├── io.max                    # IO 限制
├── pod_a/                    # 子 cgroup（对应一个 Pod）
│   ├── memory.max
│   ├── cpu.max
│   └── container_a/          # 子子 cgroup
└── pod_b/
```

### 1.3.2 Cgroups 控制器详解

**CPU 控制器**：

```bash
# v1: cpu.cfs_quota_us / cpu.cfs_period_us
cat /sys/fs/cgroup/cpu/docker/<container-id>/cpu.cfs_quota_us
# -1 = 无限制
# 50000 (period=100000) = 0.5 CPU

cat /sys/fs/cgroup/cpu/docker/<container-id>/cpu.cfs_period_us
# 默认 100000 (100ms)

# v2: cpu.max
cat /sys/fs/cgroup/<path>/cpu.max
# "50000 100000" = 0.5 CPU
# "max 100000" = 无限制
```

**Memory 控制器**：

```bash
# v1: memory.limit_in_bytes
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.limit_in_bytes
# 536870912 = 512MB

cat /sys/fs/cgroup/memory/docker/<container-id>/memory.usage_in_bytes
cat /sys/fs/cgroup/memory/docker/<container-id>/memory.stat

# v2: memory.max, memory.current
cat /sys/fs/cgroup/<path>/memory.max
cat /sys/fs/cgroup/<path>/memory.current
cat /sys/fs/cgroup/<path>/memory.stat
```

**关键指标解释**：

| 指标 | 说明 | 监控意义 |
|------|------|---------|
| `memory.usage_in_bytes` | 当前使用的内存 | 接近 limit 时可能触发 OOM |
| `memory.limit_in_bytes` | 硬限制 | 超过即触发 OOM Killer |
| `memory.working_set` | 工作集（活跃内存） | K8s 中用于判断 Pod 内存使用 |
| `memory.failcnt` | 分配失败次数 | 内存压力指标 |
| `memory.kmem.usage_in_bytes` | 内核内存使用 | 内核内存泄漏检测 |

### 1.3.3 OOM（Out of Memory）机制

当容器内存使用超过 `memory.limit_in_bytes` 时，Linux 的 OOM Killer 会介入。

**OOM 评分计算**：

```bash
# OOM 评分 = 进程占用内存 / 总内存 * 1000
cat /proc/<pid>/oom_score
# 分数越高越容易被杀

# 容器内的进程通常分数较高，因为它们的内存使用相对于 cgroup limit 很大

# Docker 可以通过 --oom-score-adj 调整
```

**K8s 中的 OOM 处理**：

```bash
# 查看 OOM 事件
kubectl get events --field-selector reason=OOMKilled

# 查看 Pod 状态
kubectl get pod <pod> -o yaml | grep -A 5 lastState
# lastState:
#   terminated:
#     containerID: ...
#     exitCode: 137        # 128 + 9 (SIGKILL)
#     reason: OOMKilled
#     finishedAt: ...

# 注意：exitCode 137 = 128 + SIGKILL(9)
# 如果是 exitCode 143 = 128 + SIGTERM(15)，是正常终止
```

---

## 1.4 Linux Capabilities：特权细分

### 1.4.1 从 root 到 Capabilities

传统 Unix 系统中，用户只有两种身份：root（UID=0）和普通用户。这种二元模型过于粗糙——很多操作需要 root 权限，但一旦获得 root，就拥有了系统的全部权限。

Linux 2.2 引入 Capabilities，将 root 的特权拆分为多个独立的能力单元。从 Linux 2.6.24 开始，Capabilities 被扩展到线程级别。

**文件能力 vs 线程能力**：

| 类型 | 说明 | 查看方式 |
|------|------|---------|
| Permitted | 进程可能被授予的能力 | `CapPrm` |
| Effective | 当前生效的能力 | `CapEff` |
| Inheritable | 子进程可继承的能力 | `CapInh` |
| Bounding | 能力上限集 | `CapBnd` |
| Ambient | 通过 execve 保持的能力 | `CapAmb` |

```bash
# 查看进程的 Capabilities
cat /proc/self/status | grep Cap
# CapInh: 0000000000000000
# CapPrm: 0000003fffffffff
# CapEff: 0000003fffffffff
# CapBnd: 0000003fffffffff
# CapAmb: 0000000000000000

# 解码能力位掩码
capsh --decode=0000003fffffffff
# 0x0000003fffffffff=cap_chown,cap_dac_override,cap_dac_read_search,
# cap_fowner,cap_fsetid,cap_kill,cap_setgid,cap_setuid,cap_setpcap,
# cap_linux_immutable,cap_net_bind_service,cap_net_broadcast,
# cap_net_admin,cap_net_raw,cap_ipc_lock,cap_ipc_owner,cap_sys_module,
# cap_sys_rawio,cap_sys_chroot,cap_sys_ptrace,cap_sys_pacct,
# cap_sys_admin,cap_sys_boot,cap_sys_nice,cap_sys_resource,
# cap_sys_time,cap_sys_tty_config,cap_mknod,cap_lease,cap_audit_write,
# cap_audit_control,cap_setfcap,cap_mac_override,cap_mac_admin,
# cap_syslog,cap_wake_alarm,cap_block_suspend,cap_audit_read
```

### 1.4.2 41 种 Capabilities 详解

Linux 5.x 内核支持 41 种 Capabilities。以下是容器安全相关的重点能力：

| 能力 | 值 | 说明 | 容器风险 |
|------|-----|------|---------|
| `CAP_CHOWN` | 0 | 修改文件所有者 | 低 |
| `CAP_DAC_OVERRIDE` | 1 | 绕过文件读/写/执行权限检查 | 中 |
| `CAP_DAC_READ_SEARCH` | 2 | 绕过文件读/搜索权限 | 中 |
| `CAP_FOWNER` | 3 | 绕过文件所有者检查 | 中 |
| `CAP_FSETID` | 4 | 不清理 setuid/setgid 位 | 中 |
| `CAP_KILL` | 5 | 发送信号给任意进程 | 低 |
| `CAP_SETGID` | 6 | 修改进程 GID | 中 |
| `CAP_SETUID` | 7 | 修改进程 UID | **高** |
| `CAP_SETPCAP` | 8 | 修改进程能力 | **高** |
| `CAP_NET_BIND_SERVICE` | 10 | 绑定到特权端口 (<1024) | 低 |
| `CAP_NET_ADMIN` | 12 | 网络管理（接口、路由、防火墙） | **高** |
| `CAP_NET_RAW` | 13 | 使用原始套接字 | 中 |
| `CAP_SYS_MODULE` | 16 | 加载/卸载内核模块 | **极高** |
| `CAP_SYS_RAWIO` | 17 | 原始 I/O 访问（/dev/mem, /dev/port） | **极高** |
| `CAP_SYS_CHROOT` | 18 | 使用 chroot | 中 |
| `CAP_SYS_PTRACE` | 19 | ptrace 调试其他进程 | **高** |
| `CAP_SYS_PACCT` | 20 | 启用进程记账 | 低 |
| `CAP_SYS_ADMIN` | 21 | 系统管理（被称为"新 root"） | **极高** |
| `CAP_SYS_BOOT` | 22 | 重启系统 | **高** |
| `CAP_SYS_NICE` | 23 | 提升进程优先级 | 中 |
| `CAP_SYS_RESOURCE` | 24 | 突破资源限制 | **高** |
| `CAP_SYS_TIME` | 25 | 修改系统时间 | 中 |
| `CAP_SYS_TTY_CONFIG` | 26 | 配置 TTY | 低 |
| `CAP_AUDIT_CONTROL` | 30 | 启用/禁用内核审计 | **高** |
| `CAP_SETFCAP` | 31 | 设置文件能力 | **高** |
| `CAP_MAC_ADMIN` | 33 | 配置 MAC（SELinux） | **高** |
| `CAP_SYSLOG` | 34 | 查看内核日志 | 中 |

### 1.4.3 CAP_SYS_ADMIN："新的 root"

`CAP_SYS_ADMIN` 能力如此危险，以至于安全社区称之为"新的 root"。它允许执行大量系统管理操作：

- mount/umount 文件系统
- 使用 `unshare` 创建新的 Namespace（容器逃逸）
- 使用 `pivot_root` 切换根文件系统
- 修改系统调用表
- 访问内核调试接口

```bash
# 拥有 CAP_SYS_ADMIN 的容器可以轻易逃逸
# 实验：使用 unshare 创建新的 Mount Namespace
sudo unshare --mount /bin/bash
# 在子 shell 中执行 mount 操作

# Docker 默认会移除 CAP_SYS_ADMIN
# 如果显式添加，极度危险：
docker run --cap-add=SYS_ADMIN ubuntu unshare --mount /bin/bash
```

### 1.4.4 Docker 的 Capabilities 默认策略

Docker 默认保留 14 种能力，移除其余 27 种：

```bash
# Docker 默认保留的能力
cap_chown, cap_dac_override, cap_fsetid, cap_fowner,
cap_mknod, cap_net_raw, cap_setgid, cap_setuid,
cap_setfcap, cap_setpcap, cap_net_bind_service,
cap_sys_chroot, cap_kill, cap_audit_write

# 查看容器的能力
docker run --rm ubuntu capsh --print
# Current: = cap_chown,cap_dac_override,cap_fowner,... +ep
```

**生产环境最佳实践**：

```bash
# 1. 丢弃所有能力，按需添加
docker run \
  --cap-drop=ALL \
  --cap-add=NET_BIND_SERVICE \
  nginx

# 2. 结合 SecurityContext（K8s）
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    image: nginx
    securityContext:
      capabilities:
        drop:
        - ALL
        add:
        - NET_BIND_SERVICE
```

---

## 1.5 Seccomp：系统调用过滤

### 1.5.1 Seccomp 的历史与原理

Seccomp（Secure Computing Mode）最初由 Google Chrome 的开发者引入 Linux 2.6.12，用于沙箱化渲染进程。

**三种模式**：

| 模式 | 说明 | 使用场景 |
|------|------|---------|
| **Strict** | 只允许 read/write/exit/sigreturn | 极简单程序 |
| **BPF Filter** | 使用 BPF 程序自定义允许的系统调用 | 容器标准 |
| **Notify** (Linux 5.0+) | 拦截系统调用并通知用户空间处理 | 高级沙箱 |

**Seccomp-BPF 的工作原理**：

```
应用程序发起系统调用
        │
        ▼
┌───────────────┐
│ Seccomp Filter │  ← BPF 程序判断
│ (加载到内核)   │
└───────┬───────┘
        │
   ┌────┴────┐
   │允许    │拒绝
   ▼        ▼
执行系统调用  返回 EPERM/EFAULT
```

BPF 程序本质上是一个状态机，它检查系统调用号（syscall number），然后根据规则决定允许（`SECCOMP_RET_ALLOW`）或拒绝（`SECCOMP_RET_ERRNO` / `SECCOMP_RET_KILL`）。

### 1.5.2 Docker 默认 Seccomp Profile

Docker 默认使用一个 Seccomp Profile，禁止了约 50 个危险系统调用：

```bash
# 查看 Docker 默认 Seccomp Profile
cat /var/lib/docker/seccomp/default.json | jq '.syscalls[] | select(.action=="SCMP_ACT_ERRNO") | .names' | jq -s 'add | length'
# 约 50 个被禁止的系统调用

# 常见被禁止的调用：
# reboot, kexec_load, open_by_handle_at, init_module,
# delete_module, iopl, ioperm, swapon, swapoff,
# nfsservctl, vm86, vm86old, create_module,
# get_kernel_syms, query_module, perf_event_open,
# personality, process_vm_readv, process_vm_writev,
# ptrace, s390_runtime_instr, s390_pci_mmio_write,
# s390_pci_mmio_read, setns, sysfs, _sysctl,
# uselib, ustat, vhangup, acct, add_key,
# afs_syscall, bdflush, bpf, clock_adjtime,
# clock_settime, delete_module, fanotify_init,
# finit_module, fsconfig, fsmount, fsopen,
# fspick, get_mempolicy, init_module, ioperm,
# iopl, kcmp, kexec_file_load, kexec_load,
# keyctl, lookup_dcookie, mbind, migrate_pages,
# modify_ldt, mount, move_pages, open_by_handle_at,
# perf_event_open, pivot_root, process_vm_readv,
# process_vm_writev, ptrace, reboot, request_key,
# set_mempolicy, setns, stime, swapoff, swapon,
# sysfs, sysctl, umount2, unshare, uselib,
# userfaultfd, ustat, vhangup, vmsplice
```

### 1.5.3 自定义 Seccomp Profile

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"],
  "syscalls": [
    {
      "names": [
        "accept", "accept4", "access", "adjtimex", "alarm",
        "bind", "brk", "capget", "capset", "chdir", "chmod",
        "chown", "chown32", "clock_adjtime", "clock_getres",
        "clock_gettime", "clock_nanosleep", "clone", "close",
        "connect", "copy_file_range", "creat", "dup", "dup2",
        "dup3", "epoll_create", "epoll_create1", "epoll_ctl",
        "epoll_ctl_old", "epoll_pwait", "epoll_wait",
        "epoll_wait_old", "eventfd", "eventfd2", "execve",
        "execveat", "exit", "exit_group", "faccessat",
        "fadvise64", "fadvise64_64", "fallocate", "fanotify_mark",
        "fchdir", "fchmod", "fchmodat", "fchown", "fchown32",
        "fchownat", "fcntl", "fcntl64", "fdatasync",
        "fgetxattr", "flistxattr", "flock", "fork",
        "fremovexattr", "fsetxattr", "fstat", "fstat64",
        "fstatat64", "fstatfs", "fstatfs64", "fsync",
        "ftruncate", "ftruncate64", "futex", "getcpu",
        "getcwd", "getdents", "getdents64", "getegid",
        "getegid32", "geteuid", "geteuid32", "getgid",
        "getgid32", "getgroups", "getgroups32",
        "getitimer", "getpeername", "getpgid", "getpgrp",
        "getpid", "getppid", "getpriority", "getrandom",
        "getresgid", "getresgid32", "getresuid",
        "getresuid32", "getrlimit", "get_robust_list",
        "getrusage", "getsid", "getsockname", "getsockopt",
        "get_thread_area", "gettid", "gettimeofday",
        "getuid", "getuid32", "getxattr", "inotify_add_watch",
        "inotify_init", "inotify_init1", "inotify_rm_watch",
        "io_cancel", "ioctl", "io_destroy", "io_getevents",
        "io_pgetevents", "ioprio_get", "ioprio_set",
        "io_setup", "io_submit", "io_uring_enter",
        "io_uring_register", "io_uring_setup", "kill",
        "lchown", "lchown32", "lgetxattr", "link", "linkat",
        "listen", "listxattr", "llistxattr", "lremovexattr",
        "lseek", "lsetxattr", "lstat", "lstat64", "madvise",
        "memfd_create", "mincore", "mkdir", "mkdirat",
        "mknod", "mknodat", "mlock", "mlock2", "mlockall",
        "mmap", "mmap2", "mprotect", "mq_getsetattr",
        "mq_notify", "mq_open", "mq_timedreceive",
        "mq_timedsend", "mq_unlink", "mremap", "msgctl",
        "msgget", "msgrcv", "msgsnd", "msync", "munlock",
        "munlockall", "munmap", "nanosleep", "newfstatat",
        "open", "openat", "pause", "pidfd_getfd",
        "pidfd_open", "pidfd_send_signal", "pipe", "pipe2",
        "pivot_root", "poll", "ppoll", "prctl", "pread64",
        "preadv", "preadv2", "prlimit64", "pselect6",
        "pwrite64", "pwritev", "pwritev2", "read",
        "readahead", "readdir", "readlink", "readlinkat",
        "readv", "recv", "recvfrom", "recvmmsg", "recvmsg",
        "remap_file_pages", "removexattr", "rename",
        "renameat", "renameat2", "restart_syscall",
        "rmdir", "rseq", "rt_sigaction", "rt_sigpending",
        "rt_sigprocmask", "rt_sigqueueinfo",
        "rt_sigreturn", "rt_sigsuspend", "rt_sigtimedwait",
        "rt_tgsigqueueinfo", "sched_getaffinity",
        "sched_getattr", "sched_getparam",
        "sched_get_priority_max", "sched_get_priority_min",
        "sched_getscheduler", "sched_rr_get_interval",
        "sched_setaffinity", "sched_setattr",
        "sched_setparam", "sched_setscheduler",
        "sched_yield", "seccomp", "select", "semctl",
        "semget", "semop", "semtimedop", "send", "sendfile",
        "sendfile64", "sendmmsg", "sendmsg", "sendto",
        "setfsgid", "setfsgid32", "setfsuid", "setfsuid32",
        "setgid", "setgid32", "setgroups", "setgroups32",
        "setitimer", "setpgid", "setpriority", "setregid",
        "setregid32", "setresgid", "setresgid32",
        "setresuid", "setresuid32", "setreuid",
        "setreuid32", "setrlimit", "set_robust_list",
        "setsid", "setsockopt", "set_thread_area",
        "set_tid_address", "setuid", "setuid32",
        "setxattr", "shmat", "shmctl", "shmdt", "shmget",
        "shutdown", "sigaltstack", "signalfd", "signalfd4",
        "sigpending", "sigprocmask", "sigreturn", "socket",
        "socketcall", "socketpair", "splice", "stat",
        "stat64", "statfs", "statfs64", "statx", "symlink",
        "symlinkat", "sync", "sync_file_range",
        "syncfs", "sysinfo", "tee", "tgkill", "time",
        "timer_create", "timer_delete", "timer_getoverrun",
        "timer_gettime", "timer_settime", "timerfd_create",
        "timerfd_gettime", "timerfd_settime", "times",
        "tkill", "truncate", "truncate64", "ugetrlimit",
        "umask", "uname", "unlink", "unlinkat", "utime",
        "utimensat", "utimes", "vfork", "wait4", "waitid",
        "waitpid", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

使用自定义 Profile：
```bash
docker run --security-opt seccomp=custom-profile.json nginx
```

---

## 1.6 Docker 容器安全基础

### 1.6.1 Docker 架构与安全边界

```
Docker Client  ──►  Docker Daemon  ──►  containerd  ──►  runc
     │                  │                  │             │
     │                  │                  │             │
     │              ┌───┴───┐         ┌───┴───┐    ┌───┴───┐
     │              │Image  │         │Image  │    │Process│
     │              │Store  │         │Pull/Push│   │Create │
     │              └───┬───┘         └───┬───┘    └───┬───┘
     │                  │                  │             │
     │                  ▼                  ▼             ▼
     │            Docker Registry      containerd    Namespace
     │                                  snapshotter   Cgroups
     │                                  content       Seccomp
     │                                  runtime       Capabilities
```

**containerd-shim 的作用**：

当 containerd 通过 runc 启动容器后，runc 会退出。containerd-shim 作为容器的父进程继续运行，负责：
1. 保持容器的标准输入/输出打开
2. 向 containerd 报告容器状态
3. 回收容器内产生的僵尸进程

```bash
# 查看 shim 进程
ps aux | grep containerd-shim
# root      1234  0.0  ... containerd-shim -namespace moby -workdir ...

# 每个运行中的容器对应一个 shim
```

### 1.6.2 镜像分层与安全

Docker 镜像由多个只读层（Layer）组成，基于联合文件系统（UnionFS）：

```
容器运行时视图
┌─────────────────────────────────────────┐
│ [容器可写层]  ← 容器内写入的数据        │  Container Layer
│   (copy-on-write)                       │
├─────────────────────────────────────────┤
│ [应用层]      ← COPY app /app           │  Layer N
├─────────────────────────────────────────┤
│ [依赖层]      ← RUN pip install ...     │  Layer N-1
├─────────────────────────────────────────┤
│ [基础镜像层]  ← FROM ubuntu:22.04       │  Layer 1
│   (操作系统文件)                         │
└─────────────────────────────────────────┘
```

**安全影响**：

1. **基础镜像漏洞传递**：基础镜像中的漏洞会传递到所有子镜像
2. **层不可变**：已构建的层无法修改，只能通过新增层覆盖
3. **敏感信息残留**：如果某层包含敏感文件，即使后续层删除，仍然存在于镜像历史中

```bash
# 查看镜像历史（可能泄露敏感信息）
docker history myapp:latest

# 使用 dive 工具分析镜像层
 dive myapp:latest

# 检查某层的内容
docker save myapp:latest -o myapp.tar
tar xf myapp.tar
# 检查各层的 layer.tar
```

### 1.6.3 Dockerfile 安全最佳实践

**反模式与正确做法对比**：

```dockerfile
# ============================================
# ❌ 反模式 1：使用 latest 标签
# ============================================
FROM ubuntu:latest
# 问题：无法追溯，每次构建可能使用不同版本
# 安全：无法确定基础镜像的安全状态

# ✅ 正确做法：使用带 digest 的特定版本
FROM ubuntu:22.04@sha256:abcdef123456...
# 优点：完全可复现，可验证镜像完整性

# ============================================
# ❌ 反模式 2：以 root 运行
# ============================================
FROM ubuntu:22.04
RUN apt-get install -y myapp
CMD ["myapp"]
# 问题：容器内进程以 root (UID 0) 运行
# 安全：容器逃逸后直接获得宿主机 root

# ✅ 正确做法：创建非 root 用户
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends myapp \
    && rm -rf /var/lib/apt/lists/*
RUN groupadd -r appgroup && useradd -r -g appgroup -u 1000 appuser
USER appuser
CMD ["myapp"]

# ============================================
# ❌ 反模式 3：在镜像中遗留构建工具
# ============================================
FROM ubuntu:22.04
RUN apt-get install -y gcc make curl wget vim git
COPY . /app
RUN make
# 问题：编译工具、包管理器、shell 都留在镜像中
# 安全：攻击者有更多工具可用

# ✅ 正确做法：多阶段构建
# 构建阶段
FROM golang:1.21 AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -o server

# 运行阶段（最小镜像）
FROM gcr.io/distroless/static-debian12
COPY --from=builder /app/server /server
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/server"]
# 优点：无 shell、无包管理器、无编译工具

# ============================================
# ❌ 反模式 4：COPY . /app（复制所有文件）
# ============================================
COPY . /app
# 问题：可能将 .env、credentials、.git 复制到镜像

# ✅ 正确做法：使用 .dockerignore + 精确复制
# .dockerignore 文件：
# .git
# .env
# *.md
# Dockerfile
# docker-compose.yml

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY src/ ./src/

# ============================================
# ❌ 反模式 5：不使用 HEALTHCHECK
# ============================================
# 无 HEALTHCHECK
# 问题：K8s/Docker 无法知道应用是否健康

# ✅ 正确做法：定义健康检查
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl -f http://localhost:8080/health || exit 1
```

### 1.6.4 容器运行安全参数

```bash
# 生产环境推荐的安全容器启动参数
docker run -d \
  --name secure-app \
  \
  # 1. 用户隔离
  --user 1000:1000 \
  \
  # 2. 文件系统安全
  --read-only \                          # 只读根文件系统
  --tmpfs /tmp:rw,noexec,nosuid,size=100m \  # 临时目录内存挂载
  \
  # 3. 能力限制
  --cap-drop=ALL \                       # 丢弃所有能力
  --cap-add=NET_BIND_SERVICE \           # 只添加需要的能力
  \
  # 4. 安全选项
  --security-opt=no-new-privileges:true \ # 禁止提权（如 setuid 程序）
  --security-opt seccomp=default.json \   # seccomp 配置
  --security-opt apparmor=docker-default \ # AppArmor 策略
  \
  # 5. 资源限制
  --memory=512m \                        # 内存限制
  --memory-swap=512m \                   # 禁止交换（防止 OOM 绕过）
  --cpus=1.0 \                           # CPU 限制
  --pids-limit=100 \                     # 进程数限制
  \
  # 6. 网络限制
  --network=bridge \                     # 不使用 host 网络
  \
  # 7. 日志限制
  --log-opt max-size=10m \
  --log-opt max-file=3 \
  \
  nginx:alpine
```

---

## 1.7 生产案例：容器安全事件分析

### 1.7.1 案例：挖矿程序入侵容器

**事件背景**：
某互联网公司发现集群中多个节点的 CPU 使用率突然飙升至 100%，但业务负载正常。

**排查过程**：

```bash
# 1. 发现异常进程
kubectl top node
# NAME         CPU   MEMORY
# node-1       98%   40%
# node-2       95%   38%

# 2. 登录节点查看
ssh node-1
ps aux --sort=-%cpu | head -20
# PID   USER   CPU  COMMAND
# 12345 1000   99.2 ./xmrig -o pool.minexmr.com:4444

# 3. 查找进程所属的容器
sudo cat /proc/12345/cgroup
# 0::/kubepods.slice/.../docker-<container-id>.scope

# 4. 定位到 Pod
kubectl get pods --all-namespaces -o wide | grep node-1

# 5. 分析入侵路径
# - 该 Pod 使用了 ubuntu:latest 镜像
# - 镜像中存在 CVE-2021-4034 (pkexec 提权漏洞)
# - Pod 以 root 运行
# - 攻击者通过漏洞利用获得容器 root
# - 由于未启用 User Namespace，容器 root = 宿主机 root
```

**根本原因**：
1. 使用未修复漏洞的基础镜像
2. 容器以 root 运行
3. 未启用 seccomp 或 AppArmor
4. 容器资源无限制（允许挖矿程序耗尽 CPU）

**修复措施**：
1. 镜像漏洞扫描纳入 CI/CD
2. 所有容器强制非 root 运行
3. 启用 seccomp + AppArmor
4. 限制容器资源
5. 部署 Falco 检测异常进程

---

## 1.8 本章实验

### 实验 1.1：Namespace 创建与观察（20 分钟）

```bash
# 步骤 1：创建新的 PID 和 Mount Namespace
sudo unshare --pid --fork --mount-proc /bin/bash

# 步骤 2：验证隔离效果
echo $$    # 当前 shell 的 PID
# 输出应为 1（在新的 PID Namespace 中）

ps aux     # 只看到当前 shell 和 ps 进程

# 步骤 3：创建子进程
sleep 1000 &
ps aux     # 看到 sleep 进程

# 步骤 4：在宿主机另一个终端查看
ps aux | grep sleep
# 看到 sleep 的真实 PID（不是 1）

# 步骤 5：退出 Namespace
exit
```

### 实验 1.2：User Namespace 与 rootless 容器（30 分钟）

```bash
# 步骤 1：查看当前进程的 UID 映射
cat /proc/self/uid_map
# 0          0 4294967295
# 表示：UID 0-4294967295 映射到宿主机相同 UID

# 步骤 2：创建新的 User Namespace
unshare --user --fork /bin/bash

# 步骤 3：在 User Namespace 内
echo $$
id
# uid=65534(nobody) gid=65534(nogroup)  # 默认映射

# 步骤 4：写入 UID 映射（需要外部有 CAP_SYS_ADMIN 的进程）
# 在宿主机终端：
echo "0 1000 1" | sudo tee /proc/<pid>/uid_map
echo "0 1000 1" | sudo tee /proc/<pid>/gid_map

# 步骤 5：回到 User Namespace
id
# uid=0(root) gid=0(root)   # 容器内认为是 root

# 步骤 6：验证不是真正的 root
ls /root
# 权限被拒绝（因为实际 UID 是 1000）
```

### 实验 1.3：Cgroups v2 资源限制实验（30 分钟）

```bash
# 步骤 1：确认使用 cgroups v2
mount | grep cgroup2
# cgroup2 on /sys/fs/cgroup type cgroup2 (rw,nosuid,nodev,noexec,relatime)

# 步骤 2：创建测试 cgroup
sudo mkdir /sys/fs/cgroup/test-cgroup

# 步骤 3：设置资源限制
echo 50000000 | sudo tee /sys/fs/cgroup/test-cgroup/cpu.max
# 输出：50000 100000 = 0.5 CPU

echo 134217728 | sudo tee /sys/fs/cgroup/test-cgroup/memory.max
# 128MB

# 步骤 4：将当前 shell 加入 cgroup
echo $$ | sudo tee /sys/fs/cgroup/test-cgroup/cgroup.procs

# 步骤 5：运行 CPU 密集型任务
yes > /dev/null &
PID=$!

# 步骤 6：观察 CPU 使用（应为 50%）
top -p $PID

# 步骤 7：测试内存限制
python3 -c "a = 'x' * (200 * 1024 * 1024)"
# Killed（OOM Killer 触发）

# 步骤 8：清理
sudo rmdir /sys/fs/cgroup/test-cgroup
```

### 实验 1.4：Capabilities 对比实验（20 分钟）

```bash
# 步骤 1：默认容器的能力
docker run --rm ubuntu capsh --print | grep Current

# 步骤 2：丢弃所有能力
docker run --rm --cap-drop=ALL ubuntu capsh --print | grep Current
# Current: =

# 步骤 3：尝试在丢弃能力的容器中执行特权操作
docker run --rm --cap-drop=ALL ubuntu ip link add dummy0 type dummy
# RTNETLINK answers: Operation not permitted

# 步骤 4：添加 NET_ADMIN 能力
docker run --rm --cap-drop=ALL --cap-add=NET_ADMIN ubuntu ip link add dummy0 type dummy
# 成功

# 步骤 5：清理
docker run --rm --cap-drop=ALL --cap-add=NET_ADMIN ubuntu ip link del dummy0
```

### 实验 1.5：Seccomp 效果验证（20 分钟）

```bash
# 步骤 1：默认 seccomp 下尝试加载内核模块
docker run --rm --privileged ubuntu modprobe xfs
# modprobe: ERROR: could not insert 'xfs': Operation not permitted
# 被 seccomp 阻止

# 步骤 2：禁用 seccomp 后
docker run --rm --privileged --security-opt seccomp=unconfined ubuntu modprobe xfs
# 成功（但可能宿主机没有 xfs 模块）

# 步骤 3：查看容器 seccomp 状态
docker run --rm ubuntu cat /proc/self/status | grep Seccomp
# Seccomp:        2
# 0=disabled, 1=strict, 2=filter
```

### 实验 1.6：编写最小化安全 Dockerfile（40 分钟）

**目标**：构建一个运行 Python Flask 应用的安全镜像。

要求：
- 非 root 用户运行
- 没有 shell
- 没有包管理器
- 使用多阶段构建
- 包含 HEALTHCHECK
- 最终镜像 < 50MB

**参考答案**：

```dockerfile
# 构建阶段
FROM python:3.11-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --user --no-cache-dir -r requirements.txt

# 运行阶段
FROM python:3.11-alpine

# 安全：创建非 root 用户
RUN adduser -D -u 1000 appuser

WORKDIR /app

# 只复制必要的文件
COPY --from=builder /root/.local /home/appuser/.local
COPY --chown=appuser:appuser src/ ./src/

ENV PATH=/home/appuser/.local/bin:$PATH \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

USER appuser

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/health')" || exit 1

CMD ["python", "src/app.py"]
```

---

## 1.9 本章练习题

### 选择题

1. **以下哪种 Namespace 是容器逃逸时最先尝试突破的？**
   - A. Mount Namespace
   - B. PID Namespace
   - C. User Namespace
   - D. Network Namespace

2. **Docker 默认移除的能力中，不包括以下哪个？**
   - A. CAP_SYS_ADMIN
   - B. CAP_NET_BIND_SERVICE
   - C. CAP_SYS_MODULE
   - D. CAP_SYS_PTRACE

3. **cgroups v2 相比 v1 的主要改进是什么？**
   - A. 支持更多控制器
   - B. 统一层级树，简化管理
   - C. 性能更高
   - D. 支持热插拔

4. **容器的 readOnlyRootFilesystem 安全选项的作用是？**
   - A. 禁止读取根文件系统
   - B. 禁止修改根文件系统
   - C. 隐藏根文件系统
   - D. 加密根文件系统

### 简答题

1. 解释为什么 `CAP_SYS_ADMIN` 被称为"新的 root"？容器拥有这个能力可能带来哪些安全风险？

2. 描述使用多阶段构建 Dockerfile 时，敏感信息（如 `.env` 文件）是如何可能泄露到最终镜像中的？如何防止？

3. PID Namespace 中的 PID 1 进程有什么特殊职责？如果容器内的 PID 1 不正确处理 SIGCHLD，会导致什么问题？

### 实践题

1. 编写一个自定义 Seccomp Profile，允许容器运行 Python 应用，但禁止所有网络相关的系统调用（作为极端安全沙箱的实验）。

2. 在一个测试容器中，尝试使用 `unshare` 命令创建新的 Mount Namespace 并挂载宿主机的 `/etc` 目录。观察在默认 Docker 配置和 `--privileged` 模式下的不同结果。

---

## 1.10 本章小结

| 概念 | 作用 | 安全意义 |
|------|------|---------|
| **Namespace** | 资源视图隔离 | 容器间互不可见，但共享内核 |
| **Cgroups** | 资源用量限制 | 防止资源耗尽攻击 |
| **Capabilities** | 特权细分 | 最小权限原则，避免 root 的"全有或全无" |
| **Seccomp** | 系统调用过滤 | 缩小攻击面，阻止危险操作 |
| **非 root 用户** | 身份隔离 | 即使逃逸，破坏范围有限 |
| **只读根文件系统** | 不可变基础设施 | 防止运行时篡改 |
| **多阶段构建** | 最小化镜像 | 减少攻击面 |

**关键安全原则**：
1. **纵深防御**：Namespace + Cgroups + Capabilities + Seccomp 多层防护
2. **最小权限**：只给容器必要的权限
3. **最小镜像**：使用最小化基础镜像（Alpine、Distroless）
4. **不可变基础设施**：只读根文件系统，不运行时修改
5. **User Namespace**：将容器 root 映射到宿主机非特权用户

**扩展阅读**：
- 《Linux 容器安全》— NCC Group
- 《Container Security》— Liz Rice (O'Reilly)
- Docker 官方安全文档：https://docs.docker.com/engine/security/
- OCI Runtime Spec：https://github.com/opencontainers/runtime-spec
