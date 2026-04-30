# 第3章 Kubernetes 集群管理（CKA 级别）

> **本章目标**：掌握 Kubernetes 集群的部署、升级、备份恢复、存储管理和故障排查。这是 CKA 认证的核心内容，也是生产环境运维工程师必备的技能。
>
> 读完本章后，你应该能够独立部署高可用 K8s 集群，执行滚动升级，备份和恢复 etcd 数据，以及排查各类常见故障。

---

## 3.1 使用 kubeadm 部署高可用集群

### 3.1.1 环境准备与前置知识

在部署 Kubernetes 集群之前，需要理解 Kubernetes 的**证书体系**。这是集群安全的基石。

#### Kubernetes PKI 体系

```
┌─────────────────────────────────────────────────────────────┐
│                  Kubernetes PKI 证书体系                     │
│                                                              │
│  ┌─────────────┐                                            │
│  │  CA (自签)   │◄────────────────────────────────────┐     │
│  │  ca.crt/key │                                     │     │
│  └──────┬──────┘                                     │     │
│         │ 签发                                       │     │
│    ┌────┼────┬────────────┬─────────────┐           │     │
│    ▼    ▼    ▼            ▼             ▼           │     │
│ ┌────┐┌────┐┌──────────┐┌───────────┐┌───────────┐  │     │
│ │API ││etcd││front-proxy││kubelet    ││SA (Token)│  │     │
│ │Serv││CA  ││CA        ││client/server││(私钥)    │  │     │
│ │er  ││    ││          ││证书        ││          │  │     │
│ └────┘└────┘└──────────┘└───────────┘└───────────┘  │     │
│                                                      │     │
│ 证书有效期：默认 1 年（kubeadm 1.28+ 支持自动轮换）    │     │
│                                                              │
│ /etc/kubernetes/pki/ 目录结构：                              │
│ ├── ca.crt           # 集群 CA 证书                         │
│ ├── ca.key           # 集群 CA 私钥（绝对保密）              │
│ ├── etcd/                                             │     │
│ │   ├── ca.crt       # etcd CA 证书                       │  │
│ │   ├── ca.key       # etcd CA 私钥                       │  │
│ │   ├── server.crt   # etcd 服务器证书                     │  │
│ │   ├── peer.crt     # etcd 对等证书                       │  │
│ │   └── healthcheck-client.crt                           │  │
│ ├── front-proxy-ca.crt  # 前端代理 CA                     │
│ ├── apiserver.crt       # API Server 证书                  │
│ ├── apiserver-kubelet-client.crt  # API Server→kubelet    │
│ └── sa.key/sa.pub       # ServiceAccount 密钥对           │
└─────────────────────────────────────────────────────────────┘
```

**证书用途详解**：

| 证书 | 用途 | 通信方向 |
|------|------|---------|
| `ca.crt` | 验证集群内所有证书 | - |
| `apiserver.crt` | API Server HTTPS 服务 | 客户端 → API Server |
| `apiserver-kubelet-client.crt` | API Server 调用 kubelet | API Server → kubelet |
| `etcd/ca.crt` | etcd 集群内部证书 | etcd peer ↔ etcd peer |
| `etcd/server.crt` | etcd 客户端连接 | API Server → etcd |
| `front-proxy-ca.crt` | 前端代理认证（Webhook 等） | - |
| `sa.key/sa.pub` | 签发 ServiceAccount Token | API Server → Pod |

**kubeconfig 文件结构**：

```yaml
apiVersion: v1
kind: Config
clusters:              # 集群信息
- name: kubernetes
  cluster:
    certificate-authority-data: <base64-ca.crt>
    server: https://k8s-api.example.com:6443
users:                 # 用户信息
- name: kubernetes-admin
  user:
    client-certificate-data: <base64-client.crt>
    client-key-data: <base64-client.key>
contexts:              # 上下文（集群+用户+命名空间）
- name: kubernetes-admin@kubernetes
  context:
    cluster: kubernetes
    user: kubernetes-admin
    namespace: default
current-context: kubernetes-admin@kubernetes
```

#### 节点准备

```bash
# ===== 所有节点执行 =====

# 1. 关闭 Swap（Kubernetes 要求）
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# 2. 加载必要的内核模块
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# 3. 设置 sysctl 参数
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# 4. 安装 containerd（CRI 运行时）
sudo apt-get update
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# 修改 containerd 配置：使用 systemd cgroup driver
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# 5. 安装 kubeadm, kubelet, kubectl
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg

echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
  https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /' | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl
```

### 3.1.2 kubeadm init 的完整流程

kubeadm init 执行以下阶段（可用 `kubeadm init --skip-phases=<phase>` 跳过特定阶段）：

```
kubeadm init
    │
    ├── 1. preflight          → 环境检查（CPU/内存/端口/容器运行时）
    │
    ├── 2. certs              → 生成所有 PKI 证书
    │   ├── ca
    │   ├── apiserver
    │   ├── apiserver-kubelet-client
    │   ├── front-proxy-ca
    │   ├── etcd/ca
    │   ├── etcd/server
    │   ├── etcd/peer
    │   ├── etcd/healthcheck-client
    │   └── sa (ServiceAccount)
    │
    ├── 3. kubeconfig         → 生成 kubeconfig 文件
    │   ├── admin
    │   ├── kubelet
    │   ├── controller-manager
    │   └── scheduler
    │
    ├── 4. kubelet-start      → 写入 kubelet 配置并启动
    │
    ├── 5. control-plane      → 生成静态 Pod manifest
    │   ├── etcd.yaml
    │   ├── kube-apiserver.yaml
    │   ├── kube-controller-manager.yaml
    │   └── kube-scheduler.yaml
    │
    ├── 6. etcd               → 启动 etcd（如果是本地 etcd）
    │
    ├── 7. upload-config      → 将 kubeadm 配置上传到 ConfigMap
    │
    ├── 8. upload-certs       → 将证书上传到 Secret（用于添加控制平面节点）
    │
    ├── 9. mark-control-plane → 给节点添加控制平面标签和污点
    │   • 标签: node-role.kubernetes.io/control-plane=""
    │   • 污点: node-role.kubernetes.io/control-plane:NoSchedule
    │
    ├── 10. bootstrap-token   → 生成 bootstrap token
    │
    └── 11. addon             → 安装核心插件
        ├── CoreDNS
        └── kube-proxy
```

#### 初始化第一个控制平面节点

```bash
# 单控制平面（测试/开发）
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version=v1.29.0

# 高可用控制平面（生产）
sudo kubeadm init \
  --control-plane-endpoint "k8s-api.example.com:6443" \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --upload-certs \
  --kubernetes-version=v1.29.0
```

**关键参数说明**：

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| `--control-plane-endpoint` | 控制平面负载均衡地址 | DNS 或虚拟 IP |
| `--pod-network-cidr` | Pod IP 范围 | 不与现有网络冲突 |
| `--service-cidr` | Service IP 范围 | 不与 podCIDR 重叠 |
| `--upload-certs` | 上传证书到 Secret | 高可用必须 |
| `--certificate-key` | 自定义证书加密密钥 | 可选 |

**初始化输出示例**：

```
Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

You can now join any number of control-plane nodes by copying certificate authorities
and service account keys on each node and then running the following as root:

  kubeadm join k8s-api.example.com:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234... \
    --control-plane --certificate-key 5678...

Then you can join any number of worker nodes by running the following on each as root:

  kubeadm join k8s-api.example.com:6443 --token abcdef.0123456789abcdef \
    --discovery-token-ca-cert-hash sha256:1234...
```

#### Bootstrap Token 机制

Bootstrap Token 用于新节点安全加入集群：

```
新节点
    │
    │ kubeadm join <endpoint> --token <token> --discovery-token-ca-cert-hash <hash>
    │
    ▼
┌─────────────────┐
│  验证 Token      │  ← Token 格式: [a-z0-9]{6}.[a-z0-9]{16}
│  (有效期 24h)    │  ← 存储在 kube-system/bootstrap-token-<token-id> Secret
└────────┬────────┘
         │ Token 有效
         ▼
┌─────────────────┐
│  TLS Bootstrap   │  ← 新节点生成临时证书请求 (CSR)
│  (kubelet 证书)  │  ← controller-manager 自动审批
└────────┬────────┘
         │ 获得 kubelet 客户端证书
         ▼
┌─────────────────┐
│  节点注册        │  ← kubelet 向 API Server 注册 Node 对象
└─────────────────┘
```

```bash
# 查看现有的 bootstrap token
kubectl get secrets -n kube-system | grep bootstrap-token

# 创建新的 token（用于添加新节点）
kubeadm token create --print-join-command

# 查看 token 列表
kubeadm token list

# 删除 token
kubeadm token delete <token>
```

### 3.1.3 高可用控制平面架构

生产环境必须部署高可用（HA）控制平面。有两种架构选择：

#### 方案 A：Stacked etcd（堆叠式）

```
┌─────────────────────────────────────────────────────────────┐
│                  Stacked etcd 架构（推荐）                    │
│                                                              │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │  Master-1   │  │  Master-2   │  │  Master-3   │         │
│  │             │  │             │  │             │         │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │         │
│  │ │etcd     │ │  │ │etcd     │ │  │ │etcd     │ │         │
│  │ │(member) │◄─┼──┼►│(member) │◄─┼──┼►│(member) │ │         │
│  │ └────┬────┘ │  │ └────┬────┘ │  │ └────┬────┘ │         │
│  │      │      │  │      │      │  │      │      │         │
│  │ ┌────┴────┐ │  │ ┌────┴────┐ │  │ ┌────┴────┐ │         │
│  │ │API Serv │ │  │ │API Serv │ │  │ │API Serv │ │         │
│  │ │(LB后端) │ │  │ │(LB后端) │ │  │ │(LB后端) │ │         │
│  │ └────┬────┘ │  │ └────┬────┘ │  │ └────┬────┘ │         │
│  │      │      │  │      │      │  │      │      │         │
│  │ ┌────┴────┐ │  │ ┌────┴────┐ │  │ ┌────┴────┐ │         │
│  │ │Scheduler│ │  │ │Scheduler│ │  │ │Scheduler│ │         │
│  │ │(leader) │ │  │ │(standby)│ │  │ │(standby)│ │         │
│  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │         │
│  │ ┌─────────┐ │  │ ┌─────────┐ │  │ ┌─────────┐ │         │
│  │ │Ctrl-Mgr │ │  │ │Ctrl-Mgr │ │  │ │Ctrl-Mgr │ │         │
│  │ │(leader) │ │  │ │(standby)│ │  │ │(standby)│ │         │
│  │ └─────────┘ │  │ └─────────┘ │  │ └─────────┘ │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
│         │                │                │                  │
│         └────────────────┴────────────────┘                  │
│                          │                                   │
│                    ┌─────┴─────┐                            │
│                    │  Load     │                            │
│                    │ Balancer  │  ← HAProxy/Keepalived/云LB  │
│                    │(VIP/DNS)  │                            │
│                    └─────┬─────┘                            │
│                          │                                   │
│    Worker Nodes ◄────────┘                                   │
└─────────────────────────────────────────────────────────────┘
```

**特点**：
- etcd 与控制平面组件运行在同一节点
- 简单、资源高效
- 如果 master 节点故障，同时失去 etcd 成员和 API Server

#### 方案 B：External etcd（外部 etcd）

```
┌─────────────────────────────────────────────────────────────┐
│                 External etcd 架构                           │
│                                                              │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐                     │
│  │ etcd-1   │ │ etcd-2   │ │ etcd-3   │  ← 独立的 etcd 集群  │
│  │(member)  │◄►│(member)  │◄►│(member)  │                     │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘                     │
│       │            │            │                           │
│       └────────────┴────────────┘                           │
│                    │                                        │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐                    │
│  │ Master-1 │ │ Master-2 │ │ Master-3 │  ← 纯控制平面节点   │
│  │API Serv  │ │API Serv  │ │API Serv  │                    │
│  │Scheduler │ │Scheduler │ │Scheduler │                    │
│  │Ctrl-Mgr  │ │Ctrl-Mgr  │ │Ctrl-Mgr  │                    │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘                    │
│       │            │            │                           │
│       └────────────┴────────────┘                           │
│                    │                                        │
│              Load Balancer                                   │
│                    │                                        │
│       Worker Nodes ◄┘                                       │
└─────────────────────────────────────────────────────────────┘
```

**特点**：
- etcd 集群独立于控制平面节点
- 更高的隔离性
- 更复杂、需要更多节点

**选择建议**：
- 大多数场景使用 **Stacked etcd**（简单、高效）
- 如果需要 etcd 独立运维、或控制平面节点资源有限，使用 **External etcd**

#### 负载均衡方案

| 方案 | 实现 | 优点 | 缺点 |
|------|------|------|------|
| **HAProxy + Keepalived** | 开源 | 灵活、免费 | 需要维护 |
| **云厂商 LB** | AWS NLB / Azure LB / GCP LB | 托管、高可用 | 有费用 |
| **DNS 轮询** | 多 A 记录 | 简单 | 故障切换慢 |

```bash
# HAProxy 配置示例（用于控制平面负载均衡）
# /etc/haproxy/haproxy.cfg
global
    log /dev/log local0
    default_backend k8s-masters

frontend k8s-api
    bind *:6443
    default_backend k8s-masters

backend k8s-masters
    option tcp-check
    balance roundrobin
    server master-1 192.168.1.11:6443 check
    server master-2 192.168.1.12:6443 check
    server master-3 192.168.1.13:6443 check
```

### 3.1.4 添加节点

**添加控制平面节点**：

```bash
# 使用初始化时生成的 join 命令
sudo kubeadm join k8s-api.example.com:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234... \
  --control-plane \
  --certificate-key 5678...

# 配置 kubectl
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

**添加工作节点**：

```bash
sudo kubeadm join k8s-api.example.com:6443 \
  --token abcdef.0123456789abcdef \
  --discovery-token-ca-cert-hash sha256:1234...
```

### 3.1.5 安装 CNI 网络插件

CNI（Container Network Interface）插件为 Pod 提供网络连接。没有 CNI，Pod 之间无法通信，节点状态会显示 `NotReady`。

#### CNI 插件对比

| 插件 | 数据路径 | 网络模式 | NetworkPolicy | 性能 | 适用场景 |
|------|---------|---------|--------------|------|---------|
| **Calico** | iptables/eBPF | BGP/VXLAN | 支持 | 高 | 通用、大规模 |
| **Cilium** | eBPF | VXLAN/BGP/Direct Routing | 支持（L3-L7） | 极高 | 安全要求高的场景 |
| **Flannel** | VXLAN/Host-GW | Overlay | 不支持 | 中 | 简单场景、测试 |
| **Weave** | VXLAN | Overlay | 支持 | 中 | 简单场景 |
| **Antrea** | OVS | Overlay | 支持 | 高 | VMware 生态 |

#### Calico 安装

```bash
# 标准安装（VXLAN 模式，无需 BGP）
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# 验证
kubectl get pods -n kube-system -l k8s-app=calico-node
kubectl get nodes
# 所有节点状态应为 Ready
```

#### Cilium 安装

```bash
# 使用 Helm 安装
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# 验证
kubectl get pods -n kube-system -l k8s-app=cilium
```

#### CNI 选择决策树

```
你的场景是什么？
    │
    ├── 简单测试/学习？
    │   └── Flannel（最简单）
    │
    ├── 生产环境，需要 NetworkPolicy？
    │   ├── 需要 L7（HTTP）策略？
    │   │   └── Cilium（eBPF，L3-L7 可见性）
    │   │
    │   └── 只需要 L3/L4 策略？
    │       ├── 大规模集群（>1000 节点）？
    │       │   └── Calico BGP 模式
    │       └── 中小规模？
    │           └── Calico VXLAN 或 Cilium
    │
    └── 云厂商托管？
        └── 使用云厂商 CNI（AWS VPC CNI / Azure CNI）
```

---

## 3.2 etcd 管理与安全

### 3.2.1 etcd 架构与数据模型

etcd 使用 Raft 共识算法保证分布式一致性：

```
┌─────────────────────────────────────────────┐
│              etcd Raft 机制                  │
│                                              │
│  术语：                                       │
│  • Term：任期号，每次选举递增                  │
│  • Index：日志索引号                          │
│  • Commit Index：已提交的日志索引              │
│                                              │
│  Leader 选举：                                │
│  1. Follower 在 Election Timeout 内未收到     │
│     Leader 心跳，变为 Candidate                │
│  2. Candidate 递增 Term，向所有节点发送        │
│     RequestVote RPC                           │
│  3. 获得多数票（n/2 + 1）成为 Leader          │
│  4. Leader 定期发送 AppendEntries（心跳）     │
│                                              │
│  日志复制：                                   │
│  1. 客户端请求 → Leader                      │
│  2. Leader 追加日志到本地                     │
│  3. Leader 发送 AppendEntries 给 Followers   │
│  4. 多数 Followers 确认后，Leader 提交日志    │
│  5. Leader 通知客户端成功                     │
│  6. Followers 异步应用日志到状态机            │
└─────────────────────────────────────────────┘
```

**etcd 数据模型**：

```bash
# etcd 中的 revision 机制
# 每次写操作（put/delete）都会递增全局 revision

# 查看 key 的 revision 历史
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/pods/default/my-pod --rev=4

# revision 4 时的值
# revision 5 时的值（最新）
```

**etcd 存储的 K8s 数据**：

| 前缀 | 存储内容 | 示例 |
|------|---------|------|
| `/registry/pods/` | Pod 数据 | `/registry/pods/default/nginx-xxx` |
| `/registry/nodes/` | Node 数据 | `/registry/nodes/node-1` |
| `/registry/secrets/` | Secret | `/registry/secrets/default/db-pass` |
| `/registry/configmaps/` | ConfigMap | `/registry/configmaps/default/app-config` |
| `/registry/deployments/` | Deployment | `/registry/deployments/default/web` |
| `/registry/services/` | Service | `/registry/services/default/web-svc` |
| `/registry/serviceaccounts/` | ServiceAccount | `/registry/serviceaccounts/default/default` |
| `/registry/ranges/` | IP 分配范围 | `/registry/ranges/serviceips`、`/registry/ranges/podips` |

### 3.2.2 etcd 性能调优

```bash
# etcd 关键启动参数（在 /etc/kubernetes/manifests/etcd.yaml 中）
spec:
  containers:
  - command:
    - etcd
    - --quota-backend-bytes=8589934592    # 后端存储配额（8GB）
    - --snapshot-count=10000              # 触发快照的事务数
    - --heartbeat-interval=100            # 心跳间隔（ms）
    - --election-timeout=1000             # 选举超时（ms）
    - --auto-compaction-retention=1h      # 自动压缩保留时间
    - --max-request-bytes=1572864         # 最大请求大小（1.5MB）
```

**性能指标监控**：

```bash
# 查看 etcd 成员状态
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --cluster -w table

# 输出示例：
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
# |    ENDPOINT    |        ID        | VERSION | DB SIZE | IS LEADER | IS LEARNER | RAFT TERM | RAFT INDEX | RAFT APPLIED INDEX | ERRORS |
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
# | 127.0.0.1:2379 | 8e9e05c52164694d |   3.5.9 |   25 MB |      true |      false |         2 |       1523 |               1523 |        |
# +----------------+------------------+---------+---------+-----------+------------+-----------+------------+--------------------+--------+
```

**关键指标**：

| 指标 | 健康阈值 | 说明 |
|------|---------|------|
| `db size` | < 配额 80% | 数据库大小 |
| `raft index` | 三节点相近 | 日志索引差异 |
| `leader changes` | < 1/小时 | Leader 变更频率 |
| `proposal pending` | < 100 | 待处理提案数 |
| `disk wal fsync` | < 10ms | WAL 同步延迟 |
| `backend commit` | < 25ms | 后端提交延迟 |

### 3.2.3 etcd 备份与恢复

#### 备份

```bash
# 创建快照备份
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 验证备份
ETCDCTL_API=3 etcdctl --write-out=table snapshot status /backup/etcd-20240101-000000.db

# +----------+----------+------------+------------+
# |   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
# +----------+----------+------------+------------+
# | 1234abcd |    15234 |       5678 |     25 MB  |
# +----------+----------+------------+------------+

# 自动化备份脚本（添加到 cron）
cat <<'EOF' | sudo tee /usr/local/bin/etcd-backup.sh
#!/bin/bash
BACKUP_DIR="/backup/etcd"
RETENTION_DAYS=7
DATE=$(date +%Y%m%d-%H%M%S)

mkdir -p $BACKUP_DIR

ETCDCTL_API=3 etcdctl snapshot save $BACKUP_DIR/etcd-$DATE.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 清理旧备份
find $BACKUP_DIR -name "etcd-*.db" -mtime +$RETENTION_DAYS -delete
EOF

sudo chmod +x /usr/local/bin/etcd-backup.sh
sudo crontab -e
# 0 2 * * * /usr/local/bin/etcd-backup.sh >> /var/log/etcd-backup.log 2>&1
```

#### 恢复（灾难恢复）

```bash
# ===== 单节点恢复 =====

# 1. 停止 kube-apiserver 和 etcd
sudo systemctl stop kubelet
sudo crictl ps | grep etcd | awk '{print $1}' | xargs -I {} sudo crictl stop {}

# 2. 移动旧数据（保留备份）
sudo mv /var/lib/etcd /var/lib/etcd.old.$(date +%Y%m%d)

# 3. 恢复快照
sudo ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-20240101-000000.db \
  --data-dir=/var/lib/etcd \
  --initial-cluster=master-1=https://192.168.1.11:2380 \
  --initial-advertise-peer-urls=https://192.168.1.11:2380 \
  --name=master-1

# 4. 修复权限
sudo chown -R root:root /var/lib/etcd

# 5. 启动 kubelet（etcd 作为静态 Pod 会自动启动）
sudo systemctl start kubelet

# 6. 验证
kubectl get nodes
kubectl get pods -A
```

**重要警告**：
- etcd 恢复会**回退到备份时的状态**，备份后创建/修改的资源会丢失
- 恢复操作应在**所有控制平面节点停止**后执行
- 如果是集群恢复，**所有 etcd 节点必须使用同一个快照恢复**

### 3.2.4 etcd 静态加密

etcd 默认以明文存储所有数据（包括 Secret）。必须启用静态加密：

```bash
# 1. 生成加密密钥
ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)

# 2. 创建加密配置文件
cat <<EOF | sudo tee /etc/kubernetes/encryption-config.yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    - configmaps
    providers:
    - aescbc:
        keys:
        - name: key1
          secret: ${ENCRYPTION_KEY}
    - identity: {}  # 回退：允许读取未加密数据
EOF

# 3. 修改 API Server 配置
sudo vim /etc/kubernetes/manifests/kube-apiserver.yaml
# 添加参数：
# --encryption-provider-config=/etc/kubernetes/encryption-config.yaml

# 4. 挂载配置文件
# 在 volumes 中添加：
# - name: encryption-config
#   hostPath:
#     path: /etc/kubernetes/encryption-config.yaml
#     type: File
# 在 volumeMounts 中添加：
# - name: encryption-config
#   mountPath: /etc/kubernetes/encryption-config.yaml
#   readOnly: true

# 5. API Server 自动重启后，加密生效
# 注意：已存在的 Secret 不会自动加密，需要重写触发加密
kubectl get secrets --all-namespaces -o json | kubectl replace -f -

# 6. 验证加密
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/my-secret
# 如果加密成功，值应该是加密的乱码，不是明文 Base64
```

---

## 3.3 证书管理

### 3.3.1 证书有效期与轮换

Kubernetes 证书默认有效期为 **1 年**。需要定期检查并及时轮换。

```bash
# 检查证书过期时间
kubeadm certs check-expiration

# 输出示例：
# CERTIFICATE                EXPIRES                  RESIDUAL TIME   CERTIFICATE AUTHORITY   EXTERNALLY MANAGED
# admin.conf                 Jan 01, 2025 00:00 UTC   364d            ca                      no
# apiserver                  Jan 01, 2025 00:00 UTC   364d            ca                      no
# apiserver-etcd-client      Jan 01, 2025 00:00 UTC   364d            etcd-ca                 no
# apiserver-kubelet-client   Jan 01, 2025 00:00 UTC   364d            ca                      no
# controller-manager.conf    Jan 01, 2025 00:00 UTC   364d            ca                      no
# etcd-healthcheck-client    Jan 01, 2025 00:00 UTC   364d            etcd-ca                 no
# etcd-peer                  Jan 01, 2025 00:00 UTC   364d            etcd-ca                 no
# etcd-server                Jan 01, 2025 00:00 UTC   364d            etcd-ca                 no
# front-proxy-client         Jan 01, 2025 00:00 UTC   364d            front-proxy-ca          no
# scheduler.conf             Jan 01, 2025 00:00 UTC   364d            ca                      no
```

#### 手动轮换证书

```bash
# 1. 备份现有证书
sudo cp -r /etc/kubernetes/pki /etc/kubernetes/pki.bak.$(date +%Y%m%d)
sudo cp -r /etc/kubernetes/*.conf /etc/kubernetes/conf.bak.$(date +%Y%m%d)

# 2. 轮换所有证书
sudo kubeadm certs renew all

# 3. 更新 kubeconfig 文件
sudo kubeadm init phase kubeconfig all

# 4. 重启控制平面组件（作为静态 Pod，kubelet 会自动重启）
sudo systemctl restart kubelet

# 5. 分发新的 kubeconfig 到所有管理节点
scp /etc/kubernetes/admin.conf user@admin-host:~/.kube/config

# 6. 验证
kubeadm certs check-expiration
```

#### kubelet 客户端证书自动轮换

kubelet 的客户端证书（用于连接 API Server）默认支持自动轮换：

```bash
# kubelet 配置中启用了自动轮换
# /var/lib/kubelet/config.yaml
rotateCertificates: true

# 当证书即将过期时：
# 1. kubelet 自动生成新的 CSR（CertificateSigningRequest）
# 2. CSR 出现在集群中：kubectl get csr
# 3. controller-manager 的 csrapproving 控制器自动审批
# 4. kubelet 下载新证书

# 手动批准 CSR（如果自动审批未启用）
kubectl certificate approve <csr-name>
```

#### 证书过期监控

```bash
# 使用脚本监控证书过期
cat <<'EOF' | sudo tee /usr/local/bin/check-certs.sh
#!/bin/bash
EXPIRY_DAYS=30
for cert in /etc/kubernetes/pki/*.crt /etc/kubernetes/pki/etcd/*.crt; do
  if [ -f "$cert" ]; then
    expiry=$(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)
    expiry_epoch=$(date -d "$expiry" +%s)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))
    if [ $days_left -lt $EXPIRY_DAYS ]; then
      echo "WARNING: $cert expires in $days_left days"
    fi
  fi
done
EOF

sudo chmod +x /usr/local/bin/check-certs.sh
```

---

## 3.4 集群升级

### 3.4.1 Kubernetes 版本策略

| 版本类型 | 发布周期 | 支持周期 | 说明 |
|---------|---------|---------|------|
| 主要版本 (x) | 约 4 个月 | 14 个月 | 新特性、API 变更 |
| 次要版本 (x.y) | - | - | 补丁和 bug 修复 |
| 补丁版本 (x.y.z) | 按需 | - | 安全修复、紧急 bug |

**升级限制**：
- 不能跳过次要版本升级（如 1.28 → 1.30 不允许，必须先升到 1.29）
- kubelet 版本可以比 API Server 低一个次要版本
- kubectl 版本可以比 API Server 高或低一个次要版本

### 3.4.2 升级前检查清单

```bash
# 1. 检查当前版本
kubectl get nodes

# 2. 检查废弃 API（可能在新版本中移除）
# 使用 pluto 工具
pluto detect-helm -owide
pluto detect-api-resources -owide

# 3. 检查 kubeadm 升级计划
sudo kubeadm upgrade plan

# 4. 备份 etcd
sudo ETCDCTL_API=3 etcdctl snapshot save /backup/pre-upgrade-$(date +%Y%m%d).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 5. 检查节点资源
kubectl top nodes
kubectl describe nodes | grep -A 5 "Allocated resources"

# 6. 确认应用兼容性
# - 检查应用使用的 K8s API 版本
# - 检查 Helm Chart 兼容性
# - 检查 CSI 驱动兼容性
```

### 3.4.3 控制平面升级

```bash
# ===== 升级第一个控制平面节点 =====

# 1. 升级 kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.29.x-00
sudo apt-mark hold kubeadm

# 2. 验证升级计划
sudo kubeadm upgrade plan

# 3. 执行升级（非交互式加 --yes）
sudo kubeadm upgrade apply v1.29.x

# 4. 升级 kubelet 和 kubectl
sudo apt-get install -y kubelet=1.29.x-00 kubectl=1.29.x-00
sudo apt-mark hold kubelet kubectl

# 5. 重启 kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 6. 验证
kubectl get nodes
kubectl get pods -n kube-system
```

```bash
# ===== 升级其他控制平面节点 =====

# 1. 升级 kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.29.x-00
sudo apt-mark hold kubeadm

# 2. 升级节点（不执行 etcd 升级，因为第一个节点已处理）
sudo kubeadm upgrade node

# 3. 升级 kubelet 和 kubectl
sudo apt-get install -y kubelet=1.29.x-00 kubectl=1.29.x-00
sudo apt-mark hold kubelet kubectl

# 4. 重启 kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet
```

### 3.4.4 工作节点升级

```bash
# ===== 逐个升级工作节点 =====

# 1. 驱逐节点上的 Pod（保留 DaemonSet）
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 2. 升级 kubeadm
sudo apt-get update
sudo apt-get install -y kubeadm=1.29.x-00
sudo apt-mark hold kubeadm

# 3. 升级节点配置
sudo kubeadm upgrade node

# 4. 升级 kubelet 和 kubectl
sudo apt-get install -y kubelet=1.29.x-00 kubectl=1.29.x-00
sudo apt-mark hold kubelet kubectl

# 5. 重启 kubelet
sudo systemctl daemon-reload
sudo systemctl restart kubelet

# 6. 恢复节点调度
kubectl uncordon <node-name>

# 7. 验证
kubectl get nodes
```

### 3.4.5 升级注意事项

| 风险 | 说明 | 缓解措施 |
|------|------|---------|
| API 废弃 | 旧 API 版本被移除 | 升级前用 pluto 检查 |
| etcd 数据不兼容 | 跨大版本 etcd 格式变化 | 按文档执行 etcd 升级 |
| 网络中断 | CNI 插件不兼容 | 确认 CNI 版本兼容性 |
| 证书过期 | 升级过程中证书问题 | 提前检查证书有效期 |
| 应用不可用 | 节点驱逐导致 Pod 迁移 | 确保有足够资源冗余 |

---

## 3.5 存储管理

### 3.5.1 Volume 类型详解

| Volume 类型 | 生命周期 | 多节点读写 | 适用场景 | 安全注意 |
|------------|---------|-----------|---------|---------|
| `emptyDir` | Pod | 否（同 Pod 共享） | 临时缓存、共享数据 | 不持久 |
| `hostPath` | 节点 | 否 | 访问节点文件系统 | **高风险，容器逃逸** |
| `local` | 节点 | 否 | 本地 SSD 高性能存储 | 节点绑定 |
| `nfs` | 外部 | 是 | 共享存储 | 网络依赖 |
| `cephfs` | 外部 | 是 | 分布式文件存储 | 需要 Ceph 集群 |
| `iscsi` | 外部 | 否 | 块存储 | 单客户端挂载 |
| `persistentVolumeClaim` | PVC | 取决于后端 | 通用持久化 | 使用 StorageClass |
| `projected` | Pod | 否 | 组合多个卷源 | - |
| `downwardAPI` | Pod | 否 | 向 Pod 注入元数据 | - |
| `configMap`/`secret` | 配置 | 否 | 配置注入 | Secret 在内存中 |

#### hostPath 的风险与替代方案

```yaml
# ❌ 高风险：hostPath 允许容器访问节点文件系统
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    image: nginx
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /          # 容器可以访问整个节点文件系统！

# ✅ 更安全的替代：使用 local volume
apiVersion: v1
kind: PersistentVolume
metadata:
  name: local-pv
spec:
  capacity:
    storage: 100Gi
  accessModes:
  - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  local:
    path: /mnt/disks/ssd1
  nodeAffinity:
    required:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - node-1
```

**hostPath 的安全限制**：Pod Security Standards 的 `restricted` 级别禁止 hostPath。

### 3.5.2 CSI（Container Storage Interface）

CSI 是 Kubernetes 的标准存储接口，允许第三方存储提供商开发驱动：

```
┌─────────────────────────────────────────────────────────────┐
│                      CSI 架构                                │
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │   Pod       │    │   Pod       │    │   Pod       │     │
│  │  (使用 PVC)  │    │  (使用 PVC)  │    │  (使用 PVC)  │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                  │             │
│         └──────────────────┼──────────────────┘             │
│                            │                                │
│                    ┌───────┴───────┐                        │
│                    │   kubelet     │                        │
│                    │  (CSI 调用)   │                        │
│                    └───────┬───────┘                        │
│                            │ CSI gRPC                       │
│         ┌──────────────────┼──────────────────┐             │
│         ▼                  ▼                  ▼             │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────┐      │
│  │ CSI Driver   │  │ CSI Driver   │  │ CSI Driver   │      │
│  │ (node)       │  │ (controller) │  │ (external    │      │
│  │              │  │              │  │  provisioner)│      │
│  │ • NodeStage  │  │ • CreateVolume│  │ • Provision  │      │
│  │ • NodePublish│  │ • DeleteVolume│  │ • Delete     │      │
│  │              │  │ • Controller │  │              │      │
│  │              │  │   Publish    │  │              │      │
│  └──────────────┘  └──────────────┘  └──────────────┘      │
│                            │                                │
│                            ▼                                │
│                    后端存储（AWS EBS / Ceph / NFS）           │
└─────────────────────────────────────────────────────────────┘
```

### 3.5.3 StorageClass 高级配置

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: ebs.csi.aws.com  # AWS EBS CSI Driver
parameters:
  type: gp3                  # SSD 类型
  encrypted: "true"          # 启用加密
  kmsKeyId: alias/aws/ebs    # KMS 密钥
  iops: "3000"               # IOPS
  throughput: "125"          # MiB/s
reclaimPolicy: Retain         # Delete / Retain
volumeBindingMode: WaitForFirstConsumer  # Immediate / WaitForFirstConsumer
allowVolumeExpansion: true    # 允许在线扩容
mountOptions:
  - debug
```

| 参数 | 说明 | 推荐值 |
|------|------|--------|
| `reclaimPolicy: Retain` | PVC 删除后保留 PV | 生产环境使用 |
| `reclaimPolicy: Delete` | PVC 删除后自动删除 PV | 开发/测试环境 |
| `volumeBindingMode: Immediate` | 立即创建和绑定 PV | 不依赖拓扑 |
| `volumeBindingMode: WaitForFirstConsumer` | 等到 Pod 调度后再创建 PV | 依赖拓扑（如 local volume） |
| `allowVolumeExpansion` | 允许在线扩容 | `true` |

---

## 3.6 调度策略

### 3.6.1 Taints 和 Tolerations

Taints 用于排斥 Pod，Tolerations 用于允许 Pod 被调度到带 Taint 的节点：

```yaml
# 给节点添加 Taint
kubectl taint nodes node-1 dedicated=gpu:NoSchedule
# 效果: NoSchedule / PreferNoSchedule / NoExecute

# Pod 定义 Toleration
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-pod
spec:
  tolerations:
  - key: "dedicated"
    operator: "Equal"
    value: "gpu"
    effect: "NoSchedule"
  containers:
  - name: cuda
    image: nvidia/cuda:12.0-base
EOF
```

| Effect | 说明 |
|--------|------|
| `NoSchedule` | 不允许调度（除非有 toleration） |
| `PreferNoSchedule` | 尽量不在此节点调度（软限制） |
| `NoExecute` | 不允许调度，且驱逐已有 Pod（除非有 toleration） |

**内置的 Taint**：

| Taint | 添加者 | 说明 |
|-------|--------|------|
| `node.kubernetes.io/not-ready` | Node Controller | 节点未就绪 |
| `node.kubernetes.io/unreachable` | Node Controller | 节点不可达 |
| `node.kubernetes.io/out-of-disk` | Node Controller | 磁盘不足 |
| `node.kubernetes.io/memory-pressure` | kubelet | 内存压力 |
| `node.kubernetes.io/disk-pressure` | kubelet | 磁盘压力 |
| `node.kubernetes.io/pid-pressure` | kubelet | PID 压力 |
| `node.kubernetes.io/unschedulable` | kubelet | 节点不可调度 |
| `node-role.kubernetes.io/control-plane` | kubeadm | 控制平面节点 |

### 3.6.2 PriorityClass 和 Pod 抢占

```yaml
# 定义优先级类
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "高优先级，用于关键服务"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority
value: 1000
globalDefault: false
description: "低优先级，用于批处理任务"

# 使用 PriorityClass
apiVersion: v1
kind: Pod
spec:
  priorityClassName: high-priority
  containers:
  - name: app
    image: critical-service:1.0
```

**抢占机制**：当高优先级 Pod 无法调度时，kube-scheduler 会驱逐（抢占）低优先级 Pod 来释放资源。

### 3.6.3 自定义调度器

```yaml
# 使用自定义调度器
apiVersion: v1
kind: Pod
spec:
  schedulerName: my-custom-scheduler
  containers:
  - name: app
    image: nginx
```

---

## 3.7 故障排查

### 3.7.1 Pod 故障排查完整流程

```
Pod 状态异常
    │
    ├── kubectl get pod <pod> -o wide
    │   └── 查看 STATUS、RESTARTS、NODE
    │
    ├── kubectl describe pod <pod>
    │   └── 查看 Events（最关键！）
    │       ├── ImagePullBackOff → 镜像问题
    │       ├── CrashLoopBackOff → 应用崩溃
    │       ├── Pending → 调度问题
    │       ├── OOMKilled → 内存超限
    │       └── FailedMount → 存储挂载失败
    │
    ├── kubectl logs <pod>
    │   └── 查看应用日志
    │
    ├── kubectl logs <pod> --previous
    │   └── 查看上一个容器实例的日志（CrashLoopBackOff 时有用）
    │
    ├── kubectl exec -it <pod> -- /bin/sh
    │   └── 进入容器内部调试
    │
    └── kubectl get events --field-selector involvedObject.name=<pod>
        └── 查看该 Pod 相关的所有事件
```

### 3.7.2 常见故障详解

#### ImagePullBackOff / ErrImagePull

```bash
# 原因 1：镜像不存在或标签错误
kubectl describe pod <pod> | grep -A 5 "Failed"
# Events: Failed to pull image "nginx:latst": rpc error: ... not found

# 原因 2：私有镜像仓库认证失败
kubectl create secret docker-registry regcred \
  --docker-server=registry.example.com \
  --docker-username=user \
  --docker-password=pass

# 在 Pod 中引用
spec:
  imagePullSecrets:
  - name: regcred

# 原因 3：节点无法连接镜像仓库
kubectl run debug --rm -it --image=busybox -- nslookup docker.io
```

#### CrashLoopBackOff

```bash
# 查看日志
kubectl logs <pod> --previous

# 常见原因：
# 1. 应用启动失败（配置错误、依赖缺失）
# 2. 命令/参数错误
# 3. 权限问题（文件无法读写）
# 4. 健康检查配置错误（Liveness Probe 过早失败）

# 调试：覆盖启动命令，保持容器运行
kubectl run debug --image=<same-image> --command -- sleep 3600
kubectl exec -it debug -- /bin/sh
# 在容器中手动执行原命令，观察错误
```

#### Pending（调度失败）

```bash
kubectl describe pod <pod> | grep -A 10 "Events"

# 常见原因：
# 0/3 nodes are available: 1 node(s) had taint {node-role.kubernetes.io/control-plane: },
# that the pod didn't tolerate, 2 Insufficient cpu.

# 解决方案：
# 1. 资源不足 → 增加节点或调整资源请求
# 2. 污点不匹配 → 添加 toleration
# 3. 节点选择器不匹配 → 检查 nodeSelector/nodeAffinity
# 4. PVC 未绑定 → 检查 PV/PVC 状态
```

### 3.7.3 DNS 故障排查

```bash
# 1. 检查 CoreDNS 是否运行
kubectl get pods -n kube-system -l k8s-app=kube-dns

# 2. 检查 CoreDNS 日志
kubectl logs -n kube-system -l k8s-app=kube-dns

# 3. 从 Pod 内部测试 DNS
kubectl run test --rm -it --image=busybox:1.36 -- nslookup kubernetes.default
kubectl run test --rm -it --image=busybox:1.36 -- nslookup my-service.default.svc.cluster.local

# 4. 检查 Pod 的 /etc/resolv.conf
kubectl run test --rm -it --image=busybox:1.36 -- cat /etc/resolv.conf
# search default.svc.cluster.local svc.cluster.local cluster.local
# nameserver 10.96.0.10
# options ndots:5

# 5. 检查 Service DNS 记录
kubectl run test --rm -it --image=busybox:1.36 -- nslookup 10.96.0.10
# 反向解析 PTR 记录

# 6. 常见的 ndots 问题
# 查询 "mysql" 时，会先尝试 mysql.default.svc.cluster.local
# 如果外部 DNS 解析慢，应用启动会变慢
# 解决：使用 FQDN（mysql.default.svc.cluster.local.）
```

### 3.7.4 网络故障排查

```bash
# 1. 检查 Pod IP 和节点路由
kubectl get pod <pod> -o wide
ip route | grep <pod-cidr>

# 2. 检查 Service 端点
kubectl get endpoints <service>
kubectl get endpointslices -l kubernetes.io/service-name=<service>

# 3. 检查 iptables 规则（iptables 模式）
sudo iptables -t nat -L KUBE-SERVICES -n | grep <service-ip>

# 4. 检查 IPVS 规则（ipvs 模式）
sudo ipvsadm -Ln | grep <service-ip>

# 5. 使用 nsenter 进入容器网络命名空间
# 获取容器 PID
CRID=$(kubectl get pod <pod> -o jsonpath='{.status.containerStatuses[0].containerID}' | sed 's|containerd://||')
PID=$(sudo crictl inspect $CRID | jq -r '.info.pid')

# 进入网络命名空间执行命令
sudo nsenter -t $PID -n ip addr
sudo nsenter -t $PID -n ip route
sudo nsenter -t $PID -n ss -tlnp
```

### 3.7.5 节点 NotReady 排查

```bash
# 1. 查看节点状态和条件
kubectl describe node <node>
# Conditions:
#   Type             Status  LastHeartbeatTime
#   ----             ------  -----------------
#   MemoryPressure   False   ...
#   DiskPressure     False   ...
#   PIDPressure      False   ...
#   Ready            False   ...  ← 关键！

# 2. 查看 kubelet 状态
ssh <node>
sudo systemctl status kubelet
sudo journalctl -u kubelet -f

# 3. 常见原因：
# - 容器运行时故障
sudo systemctl status containerd
sudo crictl ps

# - CNI 插件故障
ls /etc/cni/net.d/
cat /etc/cni/net.d/10-calico.conflist

# - 证书过期
sudo openssl x509 -in /var/lib/kubelet/pki/kubelet-client-current.pem -noout -dates

# - 磁盘空间不足
df -h
# /var 分区满了会导致镜像无法拉取、Pod 无法创建

# - 内存不足
free -h
# 节点内存不足会导致 OOM、kubelet 无法正常工作
```

---

## 3.8 资源配额与限制

### 3.8.1 ResourceQuota

ResourceQuota 限制命名空间级别的资源使用：

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: team-quota
  namespace: development
spec:
  hard:
    # 计算资源
    requests.cpu: "20"
    requests.memory: 100Gi
    limits.cpu: "40"
    limits.memory: 200Gi
    
    # 存储资源
    requests.storage: 500Gi
    persistentvolumeclaims: "20"
    
    # 对象数量
    pods: "100"
    services: "20"
    services.loadbalancers: "2"
    secrets: "50"
    configmaps: "50"
    
    # GPU 资源
    nvidia.com/gpu: "4"
```

### 3.8.2 LimitRange

LimitRange 为命名空间中的 Pod/Container 设置默认值和限制：

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: default-limits
  namespace: development
spec:
  limits:
  # 容器级别的默认限制
  - default:
      cpu: "500m"
      memory: "512Mi"
    defaultRequest:
      cpu: "100m"
      memory: "128Mi"
    max:
      cpu: "2"
      memory: "4Gi"
    min:
      cpu: "50m"
      memory: "64Mi"
    type: Container
  
  # PVC 级别的限制
  - max:
      storage: "100Gi"
    min:
      storage: "1Gi"
    type: PersistentVolumeClaim
```

**LimitRange 的作用**：
- 如果 Pod 没有设置 resources，使用默认值
- 如果 Pod 设置的 resources 超出范围，拒绝创建

---

## 3.9 生产案例：集群升级事故复盘

### 3.9.1 事件背景

某游戏公司从 Kubernetes 1.24 升级到 1.26，升级后部分节点显示 `NotReady`，业务 Pod 无法调度。

### 3.9.2 排查过程

```bash
# 1. 查看节点状态
kubectl get nodes
# NAME     STATUS     ROLES           AGE   VERSION
# node-1   Ready      control-plane   1y    v1.26.0
# node-2   NotReady   <none>          1y    v1.26.0
# node-3   NotReady   <none>          1y    v1.26.0

# 2. 查看 NotReady 节点的 kubelet 日志
ssh node-2
sudo journalctl -u kubelet -n 100
# "Failed to create shim task: OCI runtime create failed: ..."
# "exec: \"docker-runc\": executable file not found in $PATH"

# 3. 根本原因
# Kubernetes 1.24 移除了对 Docker 的直接支持（dockershim 移除）
# 节点上仍然使用 Docker 作为容器运行时
# 升级前未将容器运行时从 Docker 迁移到 containerd
```

### 3.9.3 解决方案

```bash
# 紧急回滚节点 kubelet 到 1.24
sudo apt-get install -y kubelet=1.24.x-00
sudo systemctl restart kubelet

# 长期方案：
# 1. 在所有节点安装 containerd
# 2. 配置 containerd（启用 systemd cgroup driver）
# 3. 修改 /var/lib/kubelet/config.yaml 的 containerRuntimeEndpoint
# 4. 重启 kubelet
# 5. 重新执行升级
```

### 3.9.4 经验教训

1. **升级前必读 Release Notes**：1.24 的 dockershim 移除是重大变更
2. **在测试环境先演练**：不要直接在生产环境升级
3. **备份 etcd**：升级前必须备份
4. **逐个节点升级**：不要一次性升级所有节点
5. **监控升级过程**：实时观察节点状态和应用健康

---

## 3.10 本章实验

### 实验 3.1：kubeadm 证书分析（20 分钟）

```bash
# 步骤 1：查看 PKI 目录结构
ls -la /etc/kubernetes/pki/
ls -la /etc/kubernetes/pki/etcd/

# 步骤 2：查看证书信息
sudo openssl x509 -in /etc/kubernetes/pki/apiserver.crt -noout -text | head -20
sudo openssl x509 -in /etc/kubernetes/pki/ca.crt -noout -text | head -20

# 步骤 3：查看证书有效期
kubeadm certs check-expiration

# 步骤 4：查看 kubeconfig 文件
kubectl config view --raw

# 思考问题：
# 1. 为什么 etcd 有自己的 CA？
# 2. 如果 ca.key 泄露，攻击者能做什么？
# 3. front-proxy-ca 的作用是什么？
```

### 实验 3.2：etcd 备份与恢复（40 分钟）

```bash
# 步骤 1：创建测试资源
kubectl create namespace backup-test
kubectl run test-pod --image=nginx -n backup-test

# 步骤 2：备份 etcd
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 验证备份
ETCDCTL_API=3 etcdctl --write-out=table snapshot status /tmp/snapshot.db

# 步骤 3：模拟灾难（删除命名空间）
kubectl delete namespace backup-test

# 步骤 4：停止 kubelet
sudo systemctl stop kubelet
sudo crictl ps | grep etcd | awk '{print $1}' | xargs -I {} sudo crictl stop {}

# 步骤 5：恢复 etcd
sudo mv /var/lib/etcd /var/lib/etcd.old
sudo ETCDCTL_API=3 etcdctl snapshot restore /tmp/snapshot.db \
  --data-dir=/var/lib/etcd \
  --initial-cluster=$(hostname)=https://$(hostname -I | awk '{print $1}'):2380 \
  --initial-advertise-peer-urls=https://$(hostname -I | awk '{print $1}'):2380 \
  --name=$(hostname)

sudo chown -R root:root /var/lib/etcd
sudo systemctl start kubelet

# 步骤 6：验证恢复
kubectl get namespace backup-test
kubectl get pods -n backup-test

# 清理
kubectl delete namespace backup-test
sudo rm -rf /var/lib/etcd.old
```

### 实验 3.3：证书轮换（30 分钟）

```bash
# 步骤 1：记录当前证书过期时间
kubeadm certs check-expiration > /tmp/certs-before.txt

# 步骤 2：备份证书
sudo cp -r /etc/kubernetes/pki /tmp/pki-backup

# 步骤 3：轮换所有证书
sudo kubeadm certs renew all

# 步骤 4：更新 kubeconfig
sudo kubeadm init phase kubeconfig all

# 步骤 5：重启 kubelet
sudo systemctl restart kubelet

# 步骤 6：验证新证书
kubeadm certs check-expiration > /tmp/certs-after.txt
diff /tmp/certs-before.txt /tmp/certs-after.txt

# 步骤 7：验证集群正常
kubectl get nodes
kubectl get pods -n kube-system
```

### 实验 3.4：集群升级演练（60 分钟）

```bash
# 步骤 1：检查当前版本
kubectl get nodes
kubeadm version

# 步骤 2：检查升级计划
sudo apt-get update
# 安装新版本的 kubeadm（但不升级）
# sudo apt-get install -y kubeadm=1.29.x-00
sudo kubeadm upgrade plan

# 步骤 3：备份 etcd
sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/pre-upgrade.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 步骤 4：升级控制平面（如果是单节点测试集群）
# sudo kubeadm upgrade apply v1.29.x --yes

# 步骤 5：升级 kubelet
# sudo apt-get install -y kubelet=1.29.x-00 kubectl=1.29.x-00
# sudo systemctl daemon-reload
# sudo systemctl restart kubelet

# 步骤 6：验证
kubectl get nodes
kubectl version
```

### 实验 3.5：节点维护流程（25 分钟）

```bash
# 步骤 1：标记节点不可调度
kubectl cordon node-2

# 步骤 2：驱逐节点上的 Pod
kubectl drain node-2 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force

# 步骤 3：观察 Pod 迁移
kubectl get pods -o wide -A | grep node-2
kubectl get pods -o wide -A | grep -v node-2

# 步骤 4：模拟维护（在节点上执行操作）
ssh node-2
sudo apt-get update
# sudo reboot

# 步骤 5：恢复节点
kubectl uncordon node-2

# 步骤 6：验证
kubectl get nodes
```

### 实验 3.6：存储动态供给（30 分钟）

```bash
# 步骤 1：检查 StorageClass
kubectl get storageclass

# 步骤 2：创建 PVC（假设有默认 StorageClass）
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: test-pvc
spec:
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
EOF

# 步骤 3：观察 PV 自动创建
kubectl get pvc test-pvc -w
kubectl get pv

# 步骤 4：在 Pod 中使用 PVC
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: storage-test
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh', '-c', 'echo "Hello from PVC" > /data/test.txt; sleep 3600']
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: test-pvc
EOF

# 步骤 5：验证数据持久化
kubectl exec storage-test -- cat /data/test.txt

# 步骤 6：删除 Pod，数据是否保留？
kubectl delete pod storage-test
kubectl get pv

# 清理
kubectl delete pvc test-pvc
```

### 实验 3.7：DNS 故障排查（25 分钟）

```bash
# 步骤 1：检查 CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns

# 步骤 2：创建测试 Service
kubectl create deployment dns-test --image=nginx:alpine --replicas=2
kubectl expose deployment dns-test --port=80

# 步骤 3：测试 DNS 解析
kubectl run test --rm -it --image=busybox:1.36 -- nslookup dns-test
kubectl run test --rm -it --image=busybox:1.36 -- nslookup kubernetes.default.svc.cluster.local

# 步骤 4：检查 CoreDNS 配置
kubectl get configmap coredns -n kube-system -o yaml

# 步骤 5：检查 /etc/resolv.conf
kubectl run test --rm -it --image=busybox:1.36 -- cat /etc/resolv.conf

# 步骤 6：测试 ndots 影响
kubectl run test --rm -it --image=busybox:1.36 -- nslookup google.com
kubectl run test --rm -it --image=busybox:1.36 -- nslookup google.com.
# 观察两者解析速度差异

# 清理
kubectl delete deployment dns-test
kubectl delete service dns-test
```

### 实验 3.8：Pod 故障排查综合演练（30 分钟）

```bash
# 步骤 1：创建一个有问题的 Pod
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: broken-pod
spec:
  containers:
  - name: app
    image: busybox:1.36
    command: ['sh', '-c', 'echo "Starting"; sleep 5; exit 1']
    livenessProbe:
      exec:
        command:
        - cat
        - /tmp/healthy
      initialDelaySeconds: 3
      periodSeconds: 3
EOF

# 步骤 2：观察状态变化
kubectl get pod broken-pod -w

# 步骤 3：排查
kubectl describe pod broken-pod
kubectl logs broken-pod --previous

# 步骤 4：修复 Pod（创建 /tmp/healthy）
kubectl exec broken-pod -- touch /tmp/healthy
kubectl get pod broken-pod

# 步骤 5：查看事件
kubectl get events --field-selector involvedObject.name=broken-pod

# 清理
kubectl delete pod broken-pod
```

---

## 3.11 本章练习题

### 选择题

1. **etcd 集群最少需要多少个节点才能容忍 1 个节点故障？**
   - A. 1
   - B. 2
   - C. 3
   - D. 5

2. **kubeadm 初始化时，哪个参数用于指定高可用控制平面的负载均衡地址？**
   - A. --pod-network-cidr
   - B. --service-cidr
   - C. --control-plane-endpoint
   - D. --apiserver-bind-port

3. **Kubernetes 证书默认有效期是多久？**
   - A. 30 天
   - B. 90 天
   - C. 1 年
   - D. 10 年

4. **以下哪个命令用于安全地将节点上的 Pod 驱逐后再维护？**
   - A. kubectl cordon
   - B. kubectl drain
   - C. kubectl uncordon
   - D. kubectl taint

5. **CSI 驱动中的哪个组件负责在节点上挂载/卸载卷？**
   - A. CSI Controller
   - B. CSI Node
   - C. External Provisioner
   - D. External Attacher

### 简答题

1. 解释 Stacked etcd 和 External etcd 两种高可用架构的区别，各自的优缺点是什么？什么场景下应该选择 External etcd？

2. 描述 etcd 快照恢复的完整流程。为什么恢复操作会导致备份后创建的数据丢失？在生产环境中如何设计备份策略来最小化数据丢失？

3. Kubernetes 升级为什么不能跳过次要版本（如从 1.28 直接升到 1.30）？升级前应该做哪些准备工作？

### 实践题

1. 编写一个脚本，定期检查所有 Kubernetes 证书的有效期，在证书将在 30 天内过期时发送告警。

2. 在一个测试集群中，模拟以下故障并排查：
   - 一个节点上的 containerd 服务停止
   - 观察节点状态和 Pod 行为
   - 恢复 containerd 服务
   - 记录完整的排查步骤和命令输出

3. 配置一个命名空间，使其满足以下限制：
   - 最多 10 个 Pod
   - CPU 请求总和不超过 5 核，限制总和不超过 10 核
   - 内存请求总和不超过 10Gi，限制总和不超过 20Gi
   - 默认容器 CPU 请求 100m、限制 500m
   - 默认容器内存请求 128Mi、限制 512Mi

---

## 3.12 本章小结

| 主题 | 核心技能 | CKA 考试权重 | 安全要点 |
|------|---------|-------------|---------|
| **集群安装** | kubeadm init/join、证书体系 | 高 | CA 私钥保密、etcd 加密、Token 过期 |
| **高可用** | Stacked/External etcd、负载均衡 | 高 | 控制平面隔离、证书分发 |
| **etcd 管理** | 备份/恢复、Raft 原理、性能调优 | 中 | 静态加密、定期备份、监控容量 |
| **证书管理** | 手动轮换、自动轮换、过期监控 | 中 | 备份证书、定期轮换、监控告警 |
| **集群升级** | kubeadm upgrade、节点维护 | 高 | 备份优先、逐个升级、检查兼容性 |
| **存储管理** | PV/PVC/StorageClass/CSI | 中 | 避免 hostPath、使用 Retain、加密存储 |
| **调度策略** | 亲和性/污点/优先级 | 中 | 控制平面节点隔离、GPU 专用节点 |
| **故障排查** | 日志/事件/网络/DNS | **最高** | 系统化的排查流程 |
| **资源管理** | Quota/LimitRange | 中 | 防止资源耗尽、默认限制 |

**关键运维原则**：
1. **备份优先**：任何变更前先备份 etcd
2. **逐步变更**：不要一次性变更多个组件
3. **监控一切**：证书有效期、etcd 健康、节点资源
4. **文档化**：所有操作都有回滚方案
5. **测试环境先行**：所有升级在测试环境验证

**下一章预告**：进入安全专项，学习 Kubernetes 平台安全加固、RBAC、准入控制和 Pod Security Standards。
