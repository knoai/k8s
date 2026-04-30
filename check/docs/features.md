# 功能说明文档

## 目录

- [总体架构](#总体架构)
- [模块功能详解](#模块功能详解)
- [验收标准汇总](#验收标准汇总)
- [依赖清单](#依赖清单)
- [可能失败的场景](#可能失败的场景)

---

## 总体架构

```
┌─────────────────────────────────────────────┐
│              run-acceptance.sh               │
│              （主控调度器）                    │
└──────────────────┬──────────────────────────┘
                   │
    ┌──────────────┼──────────────┐
    │              │              │
┌───▼───┐    ┌───▼───┐    ┌─────▼─────┐
│common │    │k8s-   │    │checks/    │
│.sh    │    │utils  │    │（10个模块）│
│       │    │.sh    │    │           │
│• 日志  │    │       │    │• 00-env   │
│• 报告  │    │• wait │    │• 10-node  │
│• 清理  │    │• exec │    │• 20-core  │
│       │    │       │    │• ...      │
└───────┘    └───────┘    └───────────┘
                   │
                   ▼
          ┌──────────────┐
          │ manifests/   │
          │ （测试资源）  │
          │              │
          │• network/    │
          │• storage/    │
          │• scheduling/ │
          │• operator/   │
          └──────────────┘
```

### 数据流

```
检查脚本 ──► 调用 common.sh 日志函数
                │
                ▼
         终端输出（彩色）
                │
                ▼
         日志文件（时间戳）
                │
                ▼
         报告累加器（临时文件）
                │
                ▼
         gen_report() ──► Markdown 报告
```

---

## 模块功能详解

### 00-env-check.sh — 环境预检

**目的**：在执行实际验收前，验证执行环境是否满足基本条件。

**检查内容**：
1. `kubectl` 命令是否存在
2. `kubectl` 版本信息
3. kubeconfig 是否配置且能连接集群
4. 当前用户权限（`can-i list nodes` 和 `can-i list pods --all-namespaces`）

**实现原理**：
```bash
command -v kubectl          # 检查命令存在
kubectl cluster-info        # 检查集群连接
kubectl auth can-i ...      # 检查 RBAC 权限
```

**验收标准**：
- kubectl 已安装
- 能成功连接集群
- 有 list nodes 和 list pods 权限

**失败场景**：
- kubectl 未安装
- kubeconfig 丢失或配置错误
- 当前上下文指向不存在的集群
- RBAC 权限不足

---

### 10-node-check.sh — 节点健康

**目的**：验证集群所有工作节点处于健康状态。

**检查内容**：
1. 节点总数与 Ready 节点数
2. Ready 率是否达到阈值
3. 节点压力状态（DiskPressure、MemoryPressure、PIDPressure）

**实现原理**：
```bash
kubectl get nodes -o wide           # 获取节点列表
kubectl get nodes -o json | jq ...  # 检查压力状态
```

**验收标准**：
- 所有节点状态为 Ready
- Ready 率 ≥ `NODE_READY_MIN_RATIO`（默认 100%）
- 无 DiskPressure、MemoryPressure、PIDPressure

**失败场景**：
- 有节点 NotReady
- 磁盘空间不足触发 DiskPressure
- 内存不足触发 MemoryPressure
- 进程数过多触发 PIDPressure

---

### 20-core-component.sh — 核心组件

**目的**：验证 K8s 控制平面核心组件运行正常。

**检查内容**：
1. kube-system Namespace 中核心 Pod 的 Running 比例
2. apiserver 响应延迟
3. etcd 成员健康状态
4. CoreDNS Deployment 就绪副本数

**实现原理**：
```bash
kubectl get pod -n kube-system          # 检查核心 Pod 状态
apiserver_latency_ms() { ... }          # 测量 /healthz 响应时间
kubectl exec etcd-pod -- etcdctl ...    # 检查 etcd 健康
kubectl get deployment coredns ...      # 检查 CoreDNS
```

**验收标准**：
- kube-system Pod Running 率 ≥ `CORE_POD_READY_MIN_RATIO`
- apiserver 延迟 ≤ `APISERVER_LATENCY_MS_MAX`（默认 500ms）
- etcd 健康成员数 ≥ `ETCD_HEALTHY_MIN`
- CoreDNS readyReplicas > 0

**失败场景**：
- 核心 Pod CrashLoopBackOff
- apiserver 负载过高导致响应慢
- etcd 数据不一致或成员离线
- CoreDNS Pod 未启动

---

### 30-network-check.sh — 网络功能

**目的**：验证集群网络（CNI、DNS、Service）工作正常。

**检查内容**：
1. DaemonSet 在所有节点部署测试 Pod
2. Pod 间跨节点通信
3. DNS 解析（kubernetes.default.svc 和 Service DNS）
4. IngressClass 存在性（可选）

**实现原理**：
```bash
# 1. 部署 DaemonSet 在每个节点运行 nginx
kubectl apply -f manifests/network-test/daemonset.yaml

# 2. 执行 DNS 解析 Job
kubectl apply -f manifests/network-test/dns-check-job.yaml
# Job 内执行: nslookup kubernetes.default.svc.cluster.local

# 3. 执行连通性 Job
kubectl apply -f manifests/network-test/connectivity-job.yaml
# Job 内: 遍历所有 net-test-nginx Pod IP 并 curl
```

**验收标准**：
- DaemonSet Pod 在所有节点 Ready
- DNS 解析 Job 成功完成
- 跨节点连通性 Job 成功完成

**失败场景**：
- CNI 插件异常（如 Calico/Flannel Pod 未运行）
- DNS 解析失败（CoreDNS 配置错误）
- 网络策略阻断 Pod 间通信
- 节点间网络不通

---

### 40-storage-check.sh — 存储供给

**目的**：验证集群存储（StorageClass、PVC、PV）功能正常。

**检查内容**：
1. StorageClass 存在性
2. 动态 PVC 绑定能力
3. Pod 挂载卷后的读写能力

**实现原理**：
```bash
kubectl get storageclass                      # 检查 SC
kubectl apply -f manifests/storage-test/pvc-pod.yaml
# 等待 PVC Bound
# 在 Pod 中执行: echo data > /data/testfile && cat /data/testfile
```

**验收标准**：
- PVC 在超时内变为 Bound
- Pod 成功挂载卷
- 读写操作正常

**失败场景**：
- 无 StorageClass（无法动态供给）
- CSI 驱动未运行
- 后端存储（Ceph/NFS/云盘）不可用
- 权限不足无法创建 PVC

---

### 50-scheduling-check.sh — 调度策略

**目的**：验证调度器能正确放置 Pod，且资源配额生效。

**检查内容**：
1. 基础 Deployment 调度
2. Pod 反亲和性分布
3. ResourceQuota / LimitRange 生效

**实现原理**：
```bash
kubectl apply -f manifests/scheduling-test/deployment.yaml
# Deployment 配置了 podAntiAffinity，要求副本分布在不同节点
kubectl apply -f manifests/scheduling-test/quota.yaml
# 创建 ResourceQuota 和 LimitRange
```

**验收标准**：
- Deployment 所有副本 Ready
- ResourceQuota/LimitRange 创建成功

**失败场景**：
- 节点资源不足导致 Pod Pending
- 污点配置阻止调度
- ResourceQuota 已超限

---

### 60-security-check.sh — 安全基线

**目的**：检查集群安全配置是否符合基线要求。

**检查内容**：
1. PodSecurityAdmission (PSA) 配置
2. default ServiceAccount 自动挂载
3. 以 root 运行的容器
4. 镜像拉取策略

**实现原理**：
```bash
kubectl get ns -o json | jq ...   # 检查 PSA 标签
kubectl get sa default -A -o json | jq ...  # 检查 automount
kubectl get pods -A -o json | jq ...        # 检查 root 容器
```

**验收标准**：
- 检测到 PSA 配置（ WARN 级别，非强制失败）
- 列出潜在安全风险（供人工审查）

**失败场景**：
- 无（此模块为基线扫描，主要输出 WARN 供人工审查）

---

### 70-ha-check.sh — 高可用

**目的**：验证集群高可用架构配置。

**检查内容**：
1. 控制平面 Endpoint 多后端
2. etcd 成员数量
3. 工作节点数量

**实现原理**：
```bash
kubectl get endpoints kubernetes -n default -o json | jq ...  # Endpoint 地址数
kubectl get pod -n kube-system -l component=etcd              # etcd Pod 数
kubectl get nodes | grep -v control-plane                    # 工作节点数
```

**验收标准**：
- 控制平面有多个后端（非单节点）
- etcd 成员 ≥ 2（非单节点）
- 工作节点 ≥ 2（可验证分布）

**失败场景**：
- 单节点集群（非高可用架构）
- 控制平面节点故障

---

### 80-operator-crd.sh — Operator/CRD 专项

**目的**：验证自定义资源和 Operator 控制器工作正常。

**检查内容**：
1. 所有 CRD 的 Established 状态
2. Operator Pod 运行状态（通过标签选择器）
3. 示例 CR 的生命周期（apply → wait Ready → delete）
4. Conversion Webhook 检测

**实现原理**：
```bash
kubectl get crd -o json | jq ...          # 检查 CRD Established
kubectl get pod -A -l "${OPERATOR_LABELS}" # 检查 Operator Pod
kubectl apply -f manifests/operator-test/sample-cr.yaml
# 等待 status.conditions[type=Ready].status == True
kubectl delete -f manifests/operator-test/sample-cr.yaml
```

**验收标准**：
- 所有 CRD 状态为 Established
- Operator Pod 全部 Running
- CR 能成功创建并变为 Ready
- CR 删除后成功清理

**失败场景**：
- CRD 定义错误导致无法 Established
- Operator Pod CrashLoopBackOff
- CR 缺少必填字段
- Webhook 服务不可达

---

### 90-performance-check.sh — 性能基准

**目的**：测量集群网络和调度性能基线。

**检查内容**：
1. 网络吞吐量（iperf3）
2. 调度并发能力（批量创建 Pod）

**实现原理**：
```bash
# iperf3 服务端 Deployment
kubectl apply -f manifests/network-test/iperf-server.yaml
# iperf3 客户端 Job
kubectl apply -f manifests/network-test/iperf-client-job.yaml
# 调度压测：创建 50 个 busybox Pod
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
spec:
  replicas: 50
EOF
```

**验收标准**：
- iperf3 Job 成功完成（输出带宽）
- 调度压测 Pod 大部分成功调度

**失败场景**：
- 集群无法访问公网（无法拉取 iperf3 镜像）
- 节点资源不足无法压测
- 网络带宽极低

---

## 验收标准汇总

| 模块 | 通过条件 | 失败条件 | 超时 |
|------|---------|---------|------|
| 环境检查 | kubectl+权限正常 | 命令缺失/连接失败/权限不足 | 无 |
| 节点检查 | 全部 Ready，无压力 | 有节点 NotReady/有压力 | 无 |
| 核心组件 | Pod Running 率达标，延迟低，etcd 健康 | 核心 Pod 异常/延迟高/etcd 不健康 | 无 |
| 网络检查 | DNS+连通性 Job 完成 | Pod 未就绪/Job 失败 | 120s~180s |
| 存储检查 | PVC Bound，读写正常 | PVC Pending/读写失败 | 120s |
| 调度检查 | Deployment Ready | 调度失败/Pending | 180s |
| 安全检查 | 基线扫描完成 | 无（WARN 级别） | 无 |
| 高可用检查 | 多节点架构确认 | 单节点（WARN 级别） | 无 |
| Operator/CRD | CRD Established，CR 生命周期正常 | CRD 异常/Operator 异常/CR 未 Ready | 300s |
| 性能基准 | iperf3+调度压测完成 | Job 失败 | 180s |

---

## 依赖清单

| 依赖 | 用途 | 是否必需 |
|------|------|---------|
| `bash` | 脚本执行环境 | 是 |
| `kubectl` | 与 K8s 集群交互 | 是 |
| `jq` | JSON 解析（部分模块） | 否（ gracefully fallback） |
| `date` | 时间戳生成 | 是 |
| `awk` | 数值计算 | 是 |
| `networkstatic/iperf3` 镜像 | 网络性能测试 | 否（仅性能模块） |
| `busybox:stable` 镜像 | 通用测试容器 | 是 |
| `nginx:alpine` 镜像 | 网络测试服务端 | 是 |

---

## 可能失败的场景

### 生产环境限制

| 限制 | 影响模块 | 解决方案 |
|------|---------|---------|
| 无法访问公网拉取镜像 | 网络/存储/调度/性能 | 提前导入镜像到私有仓库，修改 manifests 中的 image |
| 没有 StorageClass | 存储检查 | 跳过 `CHECK_STORAGE=false`，或部署本地存储 provisioner |
| 单节点集群 | 高可用检查 | 预期内结果，HA 模块输出 WARN |
| 权限受限（只读） | 全部模块 | 使用具有 cluster-admin 权限的 kubeconfig |

### 常见配置错误

| 错误 | 现象 | 修复 |
|------|------|------|
| `OPERATOR_LABELS` 配置错误 | Operator 检查跳过或找不到 Pod | 使用 `kubectl get pod -A -l your-labels` 验证 |
| `sample-cr.yaml` 不匹配实际 CRD | CR 生命周期测试失败 | 根据实际 CRD 的 `spec` 和 `status` 字段修改示例 CR |
| 超时配置过短 | 大集群 Pod 未就绪即判定失败 | 增大 `TIMEOUT_POD_READY` 等配置 |
