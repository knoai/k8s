# 10. K8s 面试常见问题

## 基础问题

### Q1: 什么是 Pod？为什么需要 Pod 而不是直接调度容器？

**答**：Pod 是 K8s 的最小调度单元，包含一个或多个紧密协作的容器。需要 Pod 的原因：
1. **共享网络命名空间**：Pod 内所有容器共享同一个 IP 和端口空间
2. **共享存储卷**：Pod 内所有容器可以挂载同一个 Volume
3. **紧密的生命周期绑定**：Pod 内容器同生共死

例如：一个主应用容器 + 一个日志收集 Sidecar，它们需要共享日志目录和网络。

### Q2: Pod 的生命周期有哪些状态？

**答**：
- **Pending**：已创建但尚未调度或容器尚未创建
- **Running**：已绑定节点，至少一个容器在运行
- **Succeeded**：所有容器成功退出（exit 0）
- **Failed**：所有容器退出，至少一个非 0
- **Unknown**：无法获取状态（通常节点失联）

常见异常状态：
- **CrashLoopBackOff**：容器反复崩溃
- **ImagePullBackOff**：拉取镜像失败
- **OOMKilled**：内存超限被杀死
- **Evicted**：节点资源不足被驱逐

### Q3: Deployment 和 StatefulSet 的区别？

**答**：

| 特性 | Deployment | StatefulSet |
|------|-----------|-------------|
| 适用场景 | 无状态应用 | 有状态应用 |
| Pod 命名 | 随机后缀 | 有序编号（-0, -1, -2） |
| 网络身份 | 不固定 | 稳定（有状态 DNS） |
| 存储 | 共享 PVC 模板 | 每个 Pod 独立 PVC |
| 更新策略 | 并行滚动 | 按序，可配置 |
| 缩容 | 随机 | 从后往前 |

### Q4: Service 的四种类型？

**答**：
1. **ClusterIP**：集群内部虚拟 IP（默认）
2. **NodePort**：暴露节点端口（30000-32767）
3. **LoadBalancer**：云厂商负载均衡器
4. **ExternalName**：DNS CNAME 记录

### Q5: 什么是 K8s 的网络模型？

**答**：K8s 网络模型有三个基本要求：
1. 所有 Pod 可以直接通信（无需 NAT）
2. 所有节点可以直接通信
3. Pod 可以看到自己的 IP

这意味着 Pod IP 必须是**可路由的**（在集群内部）。

---

## 控制平面

### Q6: kube-apiserver 的作用？为什么所有组件都要通过它通信？

**答**：
- apiserver 是 K8s 的 API 网关，暴露 REST API
- 处理认证、鉴权、准入控制
- 所有数据读写都经过它，然后写入 etcd
- 组件之间不直接通信，都通过 apiserver，保证了：
  - 统一的认证鉴权入口
  - 数据一致性（单一数据源 etcd）
  - 事件通知（Watch 机制）

### Q7: etcd 是什么？为什么集群中必须有奇数个 etcd 节点？

**答**：
- etcd 是 K8s 的分布式键值存储，保存所有集群状态
- 使用 Raft 协议保证一致性
- 奇数个节点是为了避免脑裂（split-brain）
- Raft 要求多数派（quorum）同意才能写入
  - 3 节点：quorum=2，可容忍 1 个故障
  - 4 节点：quorum=3，也只能容忍 1 个故障
  - 3 节点和 4 节点的容错能力相同，但 4 节点写入需要更多确认

### Q8: kube-scheduler 的调度流程？

**答**：
1. **预选（Predicates）**：过滤掉不符合条件的节点
   - 资源充足？污点容忍？亲和性满足？
2. **优选（Priorities）**：给剩余节点打分
   - 资源利用率、节点亲和性、镜像本地性等
3. **绑定（Bind）**：选择最高分节点，更新 Pod 的 nodeName

### Q9: kube-controller-manager 里有哪些控制器？

**答**：
- Node Controller：节点健康监控和驱逐
- Deployment Controller：管理 ReplicaSet 更新
- ReplicaSet Controller：维护 Pod 数量
- StatefulSet/DaemonSet/Job/CronJob Controller
- Endpoint Controller：维护 Service 和 Pod 对应关系
- PV/PVC Controller：存储卷生命周期
- Namespace Controller：清理被删除 Namespace 的资源

---

## 工作节点

### Q10: kubelet 的职责？

**答**：
1. 向 apiserver 注册节点
2. 接收分配给本节点的 Pod
3. 调用 CRI 创建/管理容器
4. 监控容器状态并上报
5. 执行健康检查（liveness/readiness/startup）
6. 管理卷挂载和网络配置

### Q11: kube-proxy 的三种模式？

**答**：
1. **iptables（默认）**：使用 iptables 规则实现 NAT 和负载均衡，随机分发
2. **IPVS（推荐）**：使用内核 IPVS，支持更多负载均衡算法，性能更好
3. **eBPF（实验性）**：一些 CNI（如 Cilium）实现了 kube-proxy 功能

### Q12: CRI 是什么？containerd 和 Docker 的关系？

**答**：
- CRI（Container Runtime Interface）是 kubelet 和容器运行时之间的标准接口
- containerd 是符合 CRI 标准的容器运行时
- Docker 本身不符合 CRI，Docker 被移除后，由 containerd 替代
- containerd 内部使用 runc 创建容器

---

## 网络

### Q13: CNI 是什么？Flannel 和 Calico 的区别？

**答**：
- CNI 是容器网络接口标准，K8s 通过 CNI 调用网络插件配置 Pod 网络
- **Flannel**：简单，使用 VXLAN 隧道，适合小型集群
- **Calico**：功能丰富，支持 BGP 路由和 NetworkPolicy，适合生产
- **Cilium**：基于 eBPF，高性能，支持 L7 策略和 Service Mesh

### Q14: Service 的 ClusterIP 是怎么实现的？

**答**：
- ClusterIP 是一个虚拟 IP，不绑定任何网络接口
- kube-proxy 在每个节点上维护 iptables/IPVS 规则
- 访问 ClusterIP 时，通过 DNAT 将目标 IP 改为后端 Pod IP
- 负载均衡由 iptables（随机）或 IPVS（多种算法）实现

### Q15: DNS 在 K8s 中如何工作？

**答**：
- CoreDNS 是集群 DNS 服务器
- Pod 的 `/etc/resolv.conf` 指向 CoreDNS Service（默认 10.96.0.10）
- CoreDNS 通过 apiserver 获取 Service 和 Pod 的 Endpoints
- Service DNS：`service-name.namespace.svc.cluster.local`
- Headless Service DNS：直接返回 Pod IP 列表

---

## 存储

### Q16: PV、PVC、StorageClass 的关系？

**答**：
- **PV**：集群中的实际存储卷（由管理员或动态供给创建）
- **PVC**：用户对存储的请求（声明需要多少容量、什么访问模式）
- **StorageClass**：存储模板，定义如何动态创建 PV
- 静态供给：管理员创建 PV，PVC 绑定到 PV
- 动态供给：PVC 引用 StorageClass，自动创建 PV

### Q17: CSI 是什么？解决了什么问题？

**答**：
- CSI（Container Storage Interface）是容器存储的标准接口
- 解决的问题：
  - 存储驱动与 K8s 核心代码解耦
  - 存储厂商可以独立开发和发布驱动
  - 支持高级功能：快照、克隆、扩容
- 架构：Controller Plugin（创建/删除卷）+ Node Plugin（挂载/卸载卷）

---

## 安全

### Q18: RBAC 中的 Role 和 ClusterRole 有什么区别？

**答**：
- **Role**：Namespace 级别的权限，只能访问该 Namespace 的资源
- **ClusterRole**：集群级别的权限，可以访问所有 Namespace 或集群范围资源
- **RoleBinding**：将 Role/ClusterRole 绑定到用户（Namespace 范围）
- **ClusterRoleBinding**：将 ClusterRole 绑定到用户（集群范围）

### Q19: ServiceAccount 是什么？Pod 如何访问 K8s API？

**答**：
- ServiceAccount 是 Pod 访问 K8s API 的身份
- 每个 Namespace 自动创建 default ServiceAccount
- Pod 创建时自动挂载 ServiceAccount Token：
  - `/var/run/secrets/kubernetes.io/serviceaccount/token`
- 1.24+ 版本使用 TokenRequest API，Token 有有效期（默认 1 小时）

### Q20: PodSecurityAdmission 和 PodSecurityPolicy 的区别？

**答**：
- **PodSecurityPolicy（PSP）**：已废弃（1.21 弃用，1.25 移除）
- **PodSecurityAdmission（PSA）**：1.25+ 替代 PSP
- PSA 通过 Namespace 标签控制安全级别：
  - `privileged`：无限制
  - `baseline`：最小限制
  - `restricted`：严格限制
- PSA 不创建新的 API 资源，更简洁

---

## 调度

### Q21: K8s 如何防止一个节点上的 Pod 过多？

**答**：
1. **资源限制**：Pod 设置 requests/limits，调度器根据 requests 分配
2. **ResourceQuota**：Namespace 级别的资源配额限制
3. **LimitRange**：Namespace 内 Pod/容器的默认/最大资源限制
4. **Pod 数量限制**：kubelet 参数 `--max-pods`（默认 110）
5. **拓扑分布约束**：`topologySpreadConstraints` 控制 Pod 分布

### Q22: 污点（Taint）和容忍（Toleration）是什么？

**答**：
- **Taint**：节点上的"污点"，排斥 Pod
- **Toleration**：Pod 的"容忍"，允许被调度到带污点的节点
- 应用场景：
  - 专用节点：`dedicated=production:NoSchedule`
  - 维护节点：`node.kubernetes.io/unreachable:NoExecute`
  - GPU 节点：`nvidia.com/gpu=true:NoSchedule`

### Q23: 亲和性（Affinity）和反亲和性（Anti-Affinity）？

**答**：
- **NodeAffinity**：Pod 倾向于/必须调度到某些节点
- **PodAffinity**：Pod 倾向于/必须与某些 Pod 在一起
- **PodAntiAffinity**：Pod 倾向于/必须与某些 Pod 分开
- 软约束：`preferredDuringSchedulingIgnoredDuringExecution`
- 硬约束：`requiredDuringSchedulingIgnoredDuringExecution`

---

## 高级

### Q24: 什么是 Operator？它和 Controller 的区别？

**答**：
- **Controller**：监听 K8s 资源变化，执行 reconcile 逻辑
- **Operator**：使用 CRD 扩展 K8s API，封装领域知识，实现自动化运维
- Operator = Controller + CRD + 领域知识
- 例如：MySQL Operator 可以自动完成备份、故障转移、扩容

### Q25: K8s 中如何实现灰度发布？

**答**：
1. **Deployment 滚动更新**：逐步替换旧版本 Pod
2. **Canary Deployment**：部署少量新版本 Pod，逐步增加流量
   - 使用两个 Deployment + Service（Label 选择部分 Pod）
   - 或使用 Ingress Controller 的流量分割
3. **Blue-Green**：同时部署两套环境，瞬间切换流量
4. **A/B 测试**：基于 Header/Cookie 分发流量到不同版本

### Q26: apiserver 挂了会怎样？

**答**：
- 正在运行的 Pod **不受影响**（kubelet 会继续管理）
- 但无法创建/更新/删除任何资源
- Controller 无法获取事件，自愈能力停止
- kubectl 命令无法执行
- 高可用部署（多 apiserver + LB）可以解决这个问题

### Q27: etcd 挂了会怎样？

**答**：
- **少数节点挂**（如 3 节点挂 1 个）：集群继续工作
- **多数节点挂**（如 3 节点挂 2 个）：集群变为只读，无法写入
- 正在运行的 Pod 不受影响
- 所有写操作（创建/更新/删除）失败

### Q28: 一个 Pod 的创建流程？

**答**：
1. 用户执行 `kubectl apply`
2. apiserver 认证、鉴权、准入控制
3. apiserver 写入 etcd
4. apiserver 发送 Add 事件
5. scheduler 发现未调度的 Pod，选择节点
6. scheduler 更新 Pod 的 nodeName
7. 目标节点的 kubelet 发现分配的 Pod
8. kubelet 调用 CNI 配置网络
9. kubelet 调用 CRI 拉取镜像、创建容器
10. kubelet 上报 Pod 状态 Running

### Q29: HPA 和 VPA 的区别？

**答**：
- **HPA（Horizontal Pod Autoscaler）**：水平扩容，增加/减少 Pod 副本数
- **VPA（Vertical Pod Autoscaler）**：垂直扩容，调整 Pod 的 requests/limits
- HPA 适用于无状态应用
- VPA 适用于有状态应用或难以水平扩展的应用
- 不建议同时启用 HPA 和 VPA

### Q30: 如何排查一个 Pod 一直处于 Pending？

**答**：
1. `kubectl describe pod <pod>` 查看 Events
2. 常见原因：
   - 资源不足：`Insufficient memory/cpu`
   - 没有匹配节点：`0/3 nodes are available`
   - 污点不匹配：`node(s) had taint`
   - PVC 未绑定：`unbound immediate PersistentVolumeClaims`
   - 亲和性不满足：`node(s) didn't match pod affinity/anti-affinity`
3. 检查节点资源：`kubectl describe node`
4. 检查调度器日志

---

## 场景题

### S1: 集群有 100 个节点，某个 Deployment 的 Pod 只分布在部分节点上，可能是什么原因？

**答**：
1. 节点资源不足（CPU/内存/磁盘）
2. 节点污点阻止调度
3. PodAntiAffinity 限制
4. 节点标签不匹配 nodeSelector/nodeAffinity
5. 某些节点 NotReady
6. ResourceQuota 限制

### S2: 滚动更新时，部分用户请求失败，如何排查？

**答**：
1. 检查 readinessProbe 是否正确配置
2. 检查 `maxUnavailable` 是否过大
3. 检查 graceful shutdown 是否实现（SIGTERM 处理）
4. 检查 Service Endpoint 更新是否及时
5. 考虑使用 PDB（PodDisruptionBudget）

### S3: 节点磁盘满了，会有什么影响？

**答**：
1. kubelet 触发 DiskPressure，标记节点
2. 驱逐低优先级 Pod（BestEffort → Burstable → Guaranteed）
3. 新 Pod 无法调度到该节点
4. 镜像无法拉取（无空间）
5. 日志无法写入

### S4: 如何给一个 Pod 固定 IP？

**答**：
- K8s 本身不支持固定 Pod IP
- 方案：
  1. 使用 StatefulSet + Headless Service（有状态 DNS）
  2. 使用静态 IP 分配方案（如 Calico IPAM）
  3. 使用 Service（ClusterIP 固定）
  4. 使用固定 IP 的 CNI 插件
