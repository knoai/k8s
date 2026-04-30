# 容器运行时深度解析

> 从 Docker 到 containerd 再到 CRI-O，含 OCI 规范、cgroups v2、以及生产环境配置。

---

## 容器运行时演进

```
Docker (2013)
    │
    ├─ dockerd (daemon)
    │   ├─ containerd (容器管理)
    │   │   ├─ runc (OCI runtime)
    │   │   └─ shim (容器生命周期管理)
    │   └─ dockerd 自身功能（镜像、网络、卷）
    │
    └── 被 Kubernetes 弃用 (v1.24+)

Kubernetes CRI 标准 (2016)
    │
    ├─ containerd (Docker 捐赠给 CNCF)
    │   ├─ 原生支持 CRI
    │   ├─ 轻量、稳定、性能高
    │   └─ 当前 K8s 默认选择
    │
    └─ CRI-O (Red Hat 主导)
        ├─ 专为 K8s 设计
        ├─ 更轻量（无 Docker 兼容层）
        └─ OpenShift 默认

其他运行时：
    - Kata Containers: 基于 VM 的安全容器
    - gVisor: 用户态内核（Google）
    - Firecracker: AWS Lambda 使用的 MicroVM
```

---

## OCI 规范

### Open Container Initiative

```
OCI 定义了容器标准：

1. OCI Runtime Spec:
   - runc 实现
   - 定义容器运行时的行为
   - 包括：namespace、cgroups、capabilities、seccomp

2. OCI Image Spec:
   - 镜像格式标准
   - 分层存储（layer tarballs）
   - manifest.json 描述镜像结构

3. 实际运行时流程：
   containerd → 调用 runc → 创建容器
   
   runc create 做的事情：
   a. 创建 namespaces:
      - PID: 独立进程树
      - NET: 独立网络栈
      - IPC: 独立 IPC
      - UTS: 独立 hostname
      - MNT: 独立挂载点
      - USER: 用户 ID 映射（可选）
      - CGROUP: 独立 cgroup（可选，Linux 4.6+）
   
   b. 设置 cgroups:
      - CPU: shares, quota, period, cpuset
      - Memory: limit, swap, kernel memory
      - IO: blkio weight, throttle
      - Pids: max pids
   
   c. 设置 capabilities:
      - 默认 drop ALL
      - 按需 add（NET_BIND_SERVICE, SETGID, SETUID）
   
   d. 设置 seccomp:
      - 默认 Docker seccomp profile（过滤 ~44 个危险 syscall）
      - K8s 默认不启用 seccomp（v1.25+ 改为 RuntimeDefault）
   
   e. 设置 AppArmor/SELinux:
      - Docker: docker-default AppArmor profile
      - K8s: 默认无限制
```

### runc 配置示例

```json
{
  "ociVersion": "1.0.2",
  "process": {
    "terminal": false,
    "user": { "uid": 0, "gid": 0 },
    "args": ["/bin/sh", "-c", "nginx -g 'daemon off;'"],
    "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "cwd": "/",
    "capabilities": {
      "bounding": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETGID", "CAP_SETUID"],
      "effective": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETGID", "CAP_SETUID"],
      "permitted": ["CAP_CHOWN", "CAP_DAC_OVERRIDE", "CAP_SETGID", "CAP_SETUID"]
    },
    "rlimits": [
      { "type": "RLIMIT_NOFILE", "hard": 1048576, "soft": 1048576 }
    ]
  },
  "root": {
    "path": "rootfs",
    "readonly": false
  },
  "hostname": "nginx-pod",
  "mounts": [
    { "destination": "/proc", "type": "proc", "source": "proc" },
    { "destination": "/dev", "type": "tmpfs", "source": "tmpfs" },
    { "destination": "/sys", "type": "sysfs", "source": "sysfs", "options": ["nosuid","noexec","nodev","ro"] }
  ],
  "linux": {
    "namespaces": [
      { "type": "pid" },
      { "type": "network" },
      { "type": "ipc" },
      { "type": "uts" },
      { "type": "mount" },
      { "type": "cgroup" }
    ],
    "resources": {
      "cpu": {
        "shares": 512,
        "quota": 100000,
        "period": 100000,
        "cpus": "0-3"
      },
      "memory": {
        "limit": 268435456,
        "reservation": 134217728,
        "swap": 268435456
      }
    },
    "seccomp": {
      "defaultAction": "SCMP_ACT_ERRNO",
      "architectures": ["SCMP_ARCH_X86_64"],
      "syscalls": [
        { "names": ["exit", "exit_group", "read", "write"], "action": "SCMP_ACT_ALLOW" }
      ]
    }
  }
}
```

---

## containerd 详解

### 架构

```
containerd 架构：

  ┌─────────────────────────────────────┐
  │  Client (ctr / crictl / K8s CRI)   │
  └──────────────┬──────────────────────┘
                 │ gRPC (/run/containerd/containerd.sock)
                 ▼
  ┌─────────────────────────────────────┐
  │  containerd (daemon)               │
  │                                     │
  │  ┌─────────────┐  ┌─────────────┐ │
  │  │  Service API │  │   Events    │ │
  │  │  (images/    │  │  (pub/sub)  │ │
  │  │   containers/│  └─────────────┘ │
  │  │   snapshots/ │                  │
  │  │   content)   │  ┌─────────────┐ │
  │  └──────┬──────┘  │   Metadata  │ │
  │         │         │   (BoltDB)   │ │
  │         ▼         └─────────────┘ │
  │  ┌─────────────────────────────┐ │
  │  │         Runtime             │ │
  │  │  ┌─────────┐  ┌─────────┐  │ │
  │  │  │   shim  │  │   shim  │  │ │
  │  │  │ (v2)    │  │ (v2)    │  │ │
  │  │  └───┬─────┘  └───┬─────┘  │ │
  │  │      │            │         │ │
  │  │      ▼            ▼         │ │
  │  │   runc          runc        │ │
  │  │   (容器1)       (容器2)      │ │
  │  └─────────────────────────────┘ │
  └─────────────────────────────────────┘
```

### 关键组件

| 组件 | 功能 | 数据存储 |
|------|------|---------|
| Content | 镜像层内容寻址存储 | `/var/lib/containerd/io.containerd.content.v1.content` |
| Snapshotter | 分层文件系统 (overlayfs) | `/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs` |
| Metadata | 容器、镜像元数据 | `/var/lib/containerd/io.containerd.metadata.v1.bolt/meta.db` |
| Runtime | 容器生命周期管理 | 内存 + runc state |
| Task | 运行中的容器进程 | `/run/containerd/io.containerd.runtime.v2.task` |

### 生产配置

```toml
# /etc/containerd/config.toml
version = 2

[plugins."io.containerd.grpc.v1.cri"]
  # 沙箱镜像
  sandbox_image = "registry.k8s.io/pause:3.9"
  
  [plugins."io.containerd.grpc.v1.cri".containerd]
    default_runtime_name = "runc"
    
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc]
      runtime_type = "io.containerd.runc.v2"
      [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]
        SystemdCgroup = true    # 使用 systemd cgroup driver
    
    # 可选：启用 gVisor 作为额外运行时
    [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.gvisor]
      runtime_type = "io.containerd.runsc.v1"
  
  [plugins."io.containerd.grpc.v1.cri".registry]
    # 私有镜像仓库配置
    [plugins."io.containerd.grpc.v1.cri".registry.mirrors]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."docker.io"]
        endpoint = ["https://mirror.gcr.io", "https://registry-1.docker.io"]
      [plugins."io.containerd.grpc.v1.cri".registry.mirrors."harbor.mycompany.com"]
        endpoint = ["https://harbor.mycompany.com"]
    
    [plugins."io.containerd.grpc.v1.cri".registry.configs]
      [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.mycompany.com".tls]
        ca_file = "/etc/containerd/certs.d/harbor/ca.crt"
      [plugins."io.containerd.grpc.v1.cri".registry.configs."harbor.mycompany.com".auth]
        username = "robot"
        password = "xxxx"

[plugins."io.containerd.grpc.v1.cri".cni]
  bin_dir = "/opt/cni/bin"
  conf_dir = "/etc/cni/net.d"
  max_conf_num = 1

# 镜像垃圾回收
[plugins."io.containerd.grpc.v1.cri".containerd]
  discard_unpacked_layers = false   # 保留解压后的层（加速启动）

# 快照器
[plugins."io.containerd.snapshotter.v1.overlayfs"]
  root_path = "/var/lib/containerd/io.containerd.snapshotter.v1.overlayfs"
  # 启用加速（zstd 或 zstd:chunked）
  slow_chown = false
```

### 常用命令

```bash
# 查看 containerd 状态
systemctl status containerd

# 查看运行中的容器
crictl ps
# CONTAINER           IMAGE               CREATED             STATE               NAME                ATTEMPT             POD ID
# abc123def456        nginx:1.25          2 hours ago         Running             nginx               0                   fedcba0987654

# 查看 Pod 沙箱
crictl pods
# POD ID              CREATED             STATE               NAME                NAMESPACE           ATTEMPT
# fedcba0987654       2 hours ago         Ready               nginx-pod           default             0

# 查看容器日志
crictl logs abc123def456

# 进入容器
crictl exec -it abc123def456 /bin/sh

# 查看镜像列表
crictl images
# IMAGE                     TAG                 IMAGE ID            SIZE
# nginx                     1.25                abc123def456        187MB
# registry.k8s.io/pause     3.9                 fedcba098765        744kB

# 拉取镜像
crictl pull nginx:1.25

# 查看 containerd 内部数据
ctr -n k8s.io containers list
ctr -n k8s.io tasks list
ctr -n k8s.io snapshots list
ctr -n k8s.io content list
```

---

## cgroups v1 vs v2

### 对比

```
┌──────────────────┬────────────────────┬────────────────────┐
│ 特性             │ cgroups v1         │ cgroups v2         │
├──────────────────┼────────────────────┼────────────────────┤
│ 层次结构         │ 多层级（per-subsystem）│ 统一层级（unified）  │
│ 控制器           │ cpu,memory,blkio,...│ 同上，但统一挂载     │
│ 挂载点           │ /sys/fs/cgroup/<ctrl>│ /sys/fs/cgroup      │
│ 资源分配         │ 可能冲突            │ 严格层级，避免冲突   │
│ rootless 容器    │ 困难               │ 原生支持           │
│ 内存回收         │ 无内置压力通知      │ 有 memory.pressure │
│ 默认系统         │ CentOS 7, Ubuntu 18 │ CentOS 9, Ubuntu 22│
└──────────────────┴────────────────────┴────────────────────┘

cgroups v1 结构：
  /sys/fs/cgroup/
    ├── cpu/
    │   ├── docker/
    │   │   └── abc123.../
    │   └── kubepods/
    │       └── pod-fedcba.../
    │           └── abc123.../
    ├── memory/
    │   ├── docker/
    │   └── kubepods/
    └── blkio/
        ├── docker/
        └── kubepods/

cgroups v2 结构：
  /sys/fs/cgroup/
    ├── init.scope/           # systemd init
    ├── system.slice/         # 系统服务
    ├── user.slice/           # 用户会话
    └── kubepods.slice/       # K8s Pod
        ├── kubepods-burstable.slice/
        │   └── kubepods-burstable-pod12345.slice/
        │       └── docker-abc123.scope/
        ├── kubepods-besteffort.slice/
        └── kubepods-guaranteed.slice/
```

### CPU 限制原理

```
cgroups CPU 限制（v1 和 v2 原理相同）：

CPU shares（相对权重）：
  - 无限制时：所有容器按 shares 比例分配
  - shares=1024 是默认值
  - 容器 A shares=512, 容器 B shares=2048
  - 争用时：A 获得 20%, B 获得 80%

CPU quota（绝对限制）：
  - quota = 100000, period = 100000
  - 表示每 100ms 最多使用 100ms = 1 核
  - quota = 200000, period = 100000 → 2 核
  - quota = -1 → 无限制

实际应用：
  resources:
    requests:
      cpu: "500m"    → shares = 512 (500/1000 * 1024)
    limits:
      cpu: "2"       → quota = 200000, period = 100000
```

### 内存限制原理

```
Memory limit 行为：

设置 memory.limit_in_bytes = 512MB

场景 1：容器使用 400MB
  → 正常运行，无限制

场景 2：容器使用 510MB，尝试分配 10MB
  → 如果节点有空闲内存：
    - 先尝试回收缓存（page cache）
    - 如果回收后仍超过 limit：触发 OOM Killer
  → OOM Killer 选择 score 最高的进程杀死
    score = rss / total_rss（使用内存最多的进程）

实际 OOM 日志：
  Memory cgroup out of memory: Killed process 12345 (java) 
    total-vm:4294967296kB, anon-rss:524288000kB, file-rss:0kB
  oom_reaper: reaped process 12345 (java)

关键区别：
  - 设置了 limit：OOM Killer 杀死容器内进程
  - 未设置 limit：可能触发节点级 OOM，杀死系统进程！

内存请求 vs 限制：
  requests.memory = 256Mi  → 调度时确保节点有 256Mi 可用
  limits.memory = 512Mi    → 实际限制，超过 OOM
```

---

## 安全容器

### Kata Containers

```
Kata 架构：
  
  Pod (K8s)
    │
    ├─ containerd-shim-kata-v2
    │   │
    │   ├─ 启动轻量 VM (QEMU/Cloud Hypervisor)
    │   │   内存开销：~128MB per VM
    │   │   启动时间：~1-2 秒
    │   │
    │   └─ 在 VM 内运行 agent
    │       agent 启动 runc 容器
    │
    └─ 容器运行在 VM 内
        - 有独立内核
        - 共享宿主机内核漏洞不影响
        - 适合多租户、不可信工作负载

性能对比（与 runc）：
  指标           runc    Kata    差异
  ───────────────────────────────────
  启动时间       100ms   1.5s    15x
  内存开销       ~10MB   ~128MB  13x
  网络延迟       0.1ms   0.3ms   3x
  CPU 性能       100%    98%     2%
  
  适用场景：
  - 金融、政务等多租户隔离
  - 运行不可信代码（CI/CD）
  - 安全沙箱需求
```

### gVisor

```
gVisor 架构：

  应用进程
    │
    ▼
  ┌─────────────────────┐
  │  Sentry (用户态内核) │  ← 实现 Linux 系统调用
  │  - 用 Go 编写        │
  │  - 拦截 syscall      │
  │  - 在 用户态 处理    │
  └──────────┬──────────┘
             │
             ▼
  ┌─────────────────────┐
  │  Gofer (文件代理)    │  ← 处理文件系统操作
  │  - 9P 协议           │
  │  - 限制文件访问      │
  └──────────┬──────────┘
             │
             ▼
  宿主机内核

gVisor 两种模式：
  1. KVM 模式：Sentry 作为 guest kernel（性能更好）
  2. ptrace 模式：用 ptrace 拦截 syscall（兼容性更好）

安全级别：
  - runc: 共享内核（高危漏洞可逃逸）
  - gVisor: 双重隔离（Sentry + 沙箱）
  - Kata: VM 隔离（最彻底，但开销大）
```

---

## 面试要点

```
Q: 为什么 K8s 1.24 废弃 Docker？
A: - K8s 使用 CRI 标准与运行时交互
   - Docker 自身包含 containerd，kubelet 通过 dockershim 调用 Docker
   - dockershim 是 K8s 维护的 shim，增加维护负担
   - 直接对接 containerd 更轻量、更稳定
   - 用户仍可安装 cri-dockerd 继续使用 Docker

Q: containerd 和 CRI-O 的区别？
A: - containerd: Docker 捐赠，通用容器运行时，生态丰富
   - CRI-O: Red Hat 主导，专为 K8s 设计，更轻量
   - 功能上几乎等价，选择取决于发行版偏好

Q: cgroups v2 相比 v1 的优势？
A: - 统一层级结构，避免资源分配冲突
   - rootless 容器原生支持
   - 更精确的资源控制（memory.pressure, io.pressure）
   - 更好的 eBPF 集成
   - 缺点：部分旧工具不兼容

Q: 容器内存限制如何工作？
A: - 通过 cgroup memory.limit_in_bytes
   - 超过 limit 时：先回收 page cache，仍不足则 OOM
   - OOM Killer 选择容器内内存使用最多的进程
   - requests.memory 只用于调度，不限制实际使用
   - 不设置 limits 可能导致节点级 OOM

Q: 安全容器的选择？
A: - 普通场景：runc（性能最好）
   - 多租户隔离：Kata Containers（VM 级隔离）
   - 安全沙箱：gVisor（syscall 过滤）
   - 云服务：Firecracker（AWS Lambda）
```
