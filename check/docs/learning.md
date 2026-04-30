# K8s 集群验收测试学习指南

## 目录

- [为什么要做集群验收](#为什么要做集群验收)
- [验收测试的理论基础](#验收测试的理论基础)
- [逐层理解检查项](#逐层理解检查项)
- [如何阅读验收报告](#如何阅读验收报告)
- [常见故障诊断思路](#常见故障诊断思路)
- [扩展自己的检查模块](#扩展自己的检查模块)

---

## 为什么要做集群验收

### 集群交付的常见问题

在生产环境中，K8s 集群交付后常遇到以下问题：

1. **网络不通**：Pod 间无法通信，DNS 解析失败
2. **存储无法挂载**：PVC 一直 Pending，应用无法启动
3. **节点压力**：磁盘满、内存不足导致节点被驱逐
4. **Operator 无法工作**：CRD 未正确建立，自定义资源无法创建
5. **性能不达标**：网络带宽、存储 IOPS 未达到承诺指标

这些问题如果在业务上线前没有被发现，将直接影响生产稳定性。

### 验收测试的价值

| 阶段 | 价值 |
|------|------|
| **交付前** | 作为交付 checklist，确保集群达到可用标准 |
| **升级后** | 验证升级未破坏核心功能 |
| **变更后** | 验证网络/存储/安全策略变更的影响 |
| **故障后** | 快速定位故障范围（网络？存储？控制平面？） |
| **日常巡检** | 周期性执行，提前发现潜在问题 |

---

## 验收测试的理论基础

### K8s 集群的层次结构

```
┌─────────────────────────────────────────┐
│  第 4 层：应用层（Pod/Deployment/Service）│
├─────────────────────────────────────────┤
│  第 3 层：调度层（Scheduler/配额/亲和性） │
├─────────────────────────────────────────┤
│  第 2 层：资源层（网络/存储/计算）        │
├─────────────────────────────────────────┤
│  第 1 层：控制层（API Server/Etcd/CM/S）  │
├─────────────────────────────────────────┤
│  第 0 层：基础设施（节点/OS/容器运行时）  │
└─────────────────────────────────────────┘
```

**测试原则**：自下而上逐层验证。如果下层有问题，上层必然受影响。

### 本方案的检查层次映射

| 层次 | 对应模块 | 验证目标 |
|------|---------|---------|
| 基础设施 | 环境检查 + 节点检查 | kubectl 可用、节点健康 |
| 控制层 | 核心组件检查 | apiserver、etcd、scheduler、controller-manager |
| 资源层 | 网络检查 + 存储检查 | CNI、DNS、PV/PVC |
| 调度层 | 调度检查 | 调度策略、ResourceQuota |
| 应用层 | 安全 + HA + Operator | RBAC、高可用、CRD |

---

## 逐层理解检查项

### 第一层：环境与节点

**环境检查（00-env）**

这是整个验收的**前提**。如果 kubectl 无法连接集群，后续所有检查都无法进行。

```bash
# 核心命令
kubectl cluster-info    # 验证连接
kubectl auth can-i ...  # 验证权限
```

**关键概念**：
- `kubeconfig`：包含集群地址、证书、用户信息的配置文件
- `context`：当前操作的集群上下文
- `RBAC`：基于角色的访问控制，决定你能做什么

**节点检查（10-node）**

节点是 K8s 的工作单元。节点不健康意味着：
- 已有 Pod 可能被驱逐
- 新 Pod 无法调度到该节点
- 该节点上的应用可能异常

**关键概念**：
- `Ready`：节点是否可接受 Pod
- `DiskPressure`：节点磁盘空间不足（默认阈值 85%）
- `MemoryPressure`：节点内存不足
- `PIDPressure`：节点进程数过多（默认阈值 32768）

---

### 第二层：核心组件

**核心组件检查（20-core）**

K8s 控制平面由以下组件组成：

```
┌─────────────────────────────────┐
│  kube-apiserver                 │  ← 所有操作的入口，检查延迟
├─────────────────────────────────┤
│  etcd                           │  ← 集群状态存储，检查健康
├─────────────────────────────────┤
│  kube-scheduler                 │  ← Pod 调度决策
├─────────────────────────────────┤
│  kube-controller-manager        │  ← 控制器循环
├─────────────────────────────────┤
│  CoreDNS                        │  ← 集群 DNS 服务
├─────────────────────────────────┤
│  CNI (Calico/Flannel/...)       │  ← 网络插件
└─────────────────────────────────┘
```

**apiserver 延迟**

apiserver 是集群的"心脏"。高延迟意味着：
- 控制平面负载过高
- 网络到 apiserver 不稳定
- etcd 响应慢（apiserver 依赖 etcd）

正常值：< 200ms  
警告值：200ms ~ 500ms  
危险值：> 500ms

**etcd 健康**

etcd 是集群的"大脑"，存储所有配置和状态。如果 etcd 不健康：
- 集群状态可能不一致
- 新资源无法创建
- 已有资源状态可能错误

---

### 第三层：网络与存储

**网络检查（30-network）**

K8s 网络模型要求：
1. 所有 Pod 可以直接通信（无需 NAT）
2. 所有节点可以直接通信
3. Pod 可以看到自己的 IP

**测试方法**：
- DaemonSet：在每个节点部署 nginx
- Job A：测试 DNS 解析
- Job B：从每个节点 curl 其他节点的 nginx

**DNS 解析流程**：
```
Pod → CoreDNS Service → CoreDNS Pod → 返回解析结果
```

DNS 失败常见原因：
- CoreDNS Pod 未运行
- CoreDNS ConfigMap 配置错误
- 节点防火墙阻断 53 端口

**存储检查（40-storage）**

K8s 存储模型：
```
Pod ──► PVC ──► PV ──► 后端存储
           ↑
    StorageClass（动态供给）
```

**关键概念**：
- `StorageClass`：定义存储"类型"（如 SSD、HDD、NFS）
- `PVC`：Pod 申请存储的声明
- `PV`：实际的存储卷
- `动态供给`：无需手动创建 PV，StorageClass 自动创建

PVC 一直 Pending 的原因：
- 没有默认 StorageClass
- CSI 驱动未安装
- 后端存储容量不足

---

### 第四层：调度与资源

**调度检查（50-scheduling）**

调度器根据以下因素决定 Pod 放在哪个节点：

```
1. 资源请求（requests）
2. 资源限制（limits）
3. 节点选择器（nodeSelector）
4. 亲和性/反亲和性（affinity）
5. 污点与容忍（taint/toleration）
6. ResourceQuota
```

**Pod 反亲和性**

本方案的 Deployment 配置了 `podAntiAffinity`，要求副本分布在不同节点。这验证了：
- 调度器能理解亲和性规则
- 集群有足够节点满足分布要求

**ResourceQuota**

限制 Namespace 能使用的资源总量。验证：
- 配额系统正常工作
- 超过配额时创建资源会被拒绝

---

### 第五层：安全与高可用

**安全检查（60-security）**

K8s 安全涉及多个层面：
- **PodSecurityAdmission (PSA)**：限制 Pod 的安全上下文
- **ServiceAccount**：Pod 访问 API 的身份
- **RBAC**：谁可以做什么
- **镜像安全**：镜像来源、拉取策略

**关键实践**：
- 容器不以 root 运行
- 默认 ServiceAccount 不自动挂载 token
- 使用特定镜像版本而非 latest

**高可用检查（70-ha）**

高可用意味着**没有单点故障**。

控制平面高可用：
```
单节点：apiserver × 1, etcd × 1  ← 任一故障集群宕机
高可用：apiserver × 3, etcd × 3  ← 可容忍 1~2 个节点故障
```

---

### 第六层：Operator 与 CRD

**Operator/CRD 检查（80-operator）**

**CRD（Custom Resource Definition）**

扩展 K8s API 的方式。例如：
```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: myapps.example.com
spec:
  group: example.com
  names:
    kind: MyApp
  scope: Namespaced
```

CRD 必须达到 `Established` 状态才能使用。

**Operator 模式**

```
用户创建 CR ──► Operator 监听 ──► Operator 协调 ──► 创建实际资源
                  (Controller)      (Reconcile Loop)
```

本方案的 CR 生命周期测试验证了完整的 reconcile 循环：
1. 用户创建 CR
2. Operator 检测到变化
3. Operator 创建子资源
4. Operator 更新 CR status 为 Ready
5. 用户删除 CR
6. Operator 清理子资源（通过 finalizer 或 ownerReference）

---

## 如何阅读验收报告

### 报告结构

```markdown
# K8s 集群验收报告

## 汇总统计
| 指标 | 数值 |
|------|------|
| 总计 | 10 |
| 通过 | 8 |
| 失败 | 1 |
| 跳过 | 1 |

## 详细结果
| 模块 | 状态 | 耗时 | 关键结论 | 失败详情 |
|------|------|------|----------|----------|
| 网络检查 | FAIL | 125s | Pod 跨节点通信失败 | connectivity-check Job 未完成 |
```

### 分析步骤

**Step 1：看汇总**
- 通过率 = 通过 / 总计
- 通过率 < 80%：集群存在严重问题，不建议上线
- 通过率 80%~95%：存在一般问题，需评估影响
- 通过率 > 95%：基本可用，修复剩余问题

**Step 2：看失败的层次**
- 如果是下层失败（环境/节点/核心组件）：先修复下层
- 如果是上层失败（网络/存储）：可能是下层问题导致的

**Step 3：看失败详情**
- 详情中包含具体的 kubectl 命令片段
- 按照详情提示的命令手动排查

### 示例分析

```
| 模块 | 状态 | 耗时 | 关键结论 | 失败详情 |
| 环境检查 | PASS | 2s | 环境就绪 | - |
| 节点检查 | PASS | 3s | 所有节点正常 | - |
| 核心组件 | PASS | 5s | 核心组件正常 | - |
| 网络检查 | FAIL | 125s | DNS 解析失败 | dns-check Job 未完成 |
| 存储检查 | PASS | 45s | 存储功能正常 | - |
```

**分析**：
1. 环境、节点、核心组件都通过了 → 下层正常
2. 只有网络检查失败 → 问题集中在网络层
3. 失败点是 DNS → 检查 CoreDNS Pod 状态
4. 排查命令：`kubectl get pod -n kube-system -l k8s-app=kube-dns`

---

## 常见故障诊断思路

### 网络问题诊断树

```
Pod 间不通？
├── CNI Pod 是否 Running？
│   └── 否：检查 CNI 插件安装
│   └── 是：下一步
├── CoreDNS 是否 Running？
│   └── 否：检查 CoreDNS Deployment
│   └── 是：下一步
├── DNS 解析是否正常？
│   └── 否：检查 CoreDNS 配置
│   └── 是：下一步
└── 安全策略是否阻断？
    └── 是：调整 NetworkPolicy
    └── 否：检查底层网络（VPC、路由表）
```

### 存储问题诊断树

```
PVC 一直 Pending？
├── 有 StorageClass 吗？
│   └── 否：创建 StorageClass
│   └── 是：下一步
├── StorageClass 有 provisioner 吗？
│   └── 否：安装 CSI 驱动
│   └── 是：下一步
├── PVC 的 storageClassName 正确吗？
│   └── 否：修正 PVC 配置
│   └── 是：下一步
└── 后端存储有容量吗？
    └── 否：扩容后端存储
    └── 是：检查 CSI 驱动日志
```

### Operator 问题诊断树

```
CR 无法创建？
├── CRD 存在吗？
│   └── 否：安装 CRD
│   └── 是：下一步
├── CRD 是 Established 吗？
│   └── 否：检查 CRD 定义是否有语法错误
│   └── 是：下一步
├── Operator Pod 在运行吗？
│   └── 否：检查 Operator Deployment
│   └── 是：下一步
├── CR 创建后 status 有变化吗？
│   └── 否：检查 Operator 日志
│   └── 是：等待 reconcile 完成
```

---

## 扩展自己的检查模块

### 模块开发规范

1. **文件命名**：`NN-描述-check.sh`，NN 为 00~99 的序号
2. **加载公共库**：必须 source `lib/common.sh`
3. **入口函数**：必须定义 `run_check()` 函数
4. **返回值**：返回 0 表示通过，返回 1 表示失败
5. **报告输出**：使用 `add_report_line` 和 `add_summary` 记录结果

### 最小模块示例

```bash
#!/usr/bin/env bash
# 99-my-check.sh - 自定义检查示例
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

run_check() {
    local start end duration status conclusion detail
    start=$(date +%s)
    status="PASS"
    conclusion="自定义检查通过"
    detail="-"

    # 你的检查逻辑
    if ! kubectl get pods --all-namespaces &>/dev/null; then
        status="FAIL"
        conclusion="无法获取 Pod 列表"
        detail="kubectl get pods 执行失败"
    fi

    end=$(date +%s)
    duration=$((end - start))s
    add_report_line "自定义检查" "${status}" "${duration}" "${conclusion}" "${detail}"
    add_summary "${status}"
    [[ "${status}" == "PASS" ]]
}

run_check "$@"
```

### 注册新模块

将文件放入 `checks/` 目录即可，主控脚本会自动识别：

```bash
cp 99-my-check.sh checks/
./run-acceptance.sh --dry-run
# 输出中将包含 99-my-check
```

### 常用公共函数

```bash
# 日志输出
log_info "消息"   # 蓝色 [INFO]
log_pass "消息"   # 绿色 [PASS]
log_warn "消息"   # 黄色 [WARN]
log_fail "消息"   # 红色 [FAIL]

# K8s 工具（需 source lib/k8s-utils.sh）
wait_for_pod <ns> <label> <timeout>          # 等待 Pod Ready
wait_for_deployment <ns> <name> <timeout>    # 等待 Deployment Ready
wait_for_job <ns> <name> <timeout>           # 等待 Job 完成
apply_and_wait <file> <ns> <kind> <name>     # 应用并等待
exec_check <ns> <pod> <cmd>                  # Pod 内执行命令
get_pod_by_label <ns> <label>                # 获取 Pod 名称
resource_exists <kind> <name> [ns]           # 检查资源是否存在

# 报告
add_report_line <module> <status> <duration> <conclusion> <detail>
add_summary <PASS|FAIL|SKIP>
```

---

## 总结

本验收方案遵循**自下而上、逐层验证**的原则：

1. **先验证基础设施**：kubectl 可用、节点健康
2. **再验证控制平面**：apiserver、etcd、DNS 正常
3. **然后验证资源层**：网络可通、存储可用
4. **最后验证应用层**：调度策略、安全基线、Operator 功能

每层的失败都会影响上层，因此排查时应**从下往上**逐层确认。
