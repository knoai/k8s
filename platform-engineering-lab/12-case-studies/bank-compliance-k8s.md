# 案例研究：银行合规 K8s 平台建设

> 银行业是监管最严格的行业之一。
> 等保三级、PCI-DSS、SOX、央行监管——每一个要求都需要在平台层面实现。
> 本案例基于国内股份制银行和城商行的真实 K8s 平台建设实践整理。

---

## 第一章：银行业的监管框架

### 1.1 合规要求矩阵

```
银行业面临的监管要求：

┌─────────────────┬─────────────────────────────┬────────────────────────────────────────┐
│ 法规            │ 技术要求                    │ K8s 平台实现                           │
├─────────────────┼─────────────────────────────┼────────────────────────────────────────┤
│ 等保三级        │ 访问控制、审计日志、加密    │ RBAC + 审计 + KMS 加密                 │
│ 央行规范        │ 数据本地化、运维审计        │ 私有云部署 + 堡垒机 + 操作录屏         │
│ PCI-DSS         │ 支付数据隔离、加密传输      │ NetworkPolicy + mTLS + Secret 加密     │
│ SOX             │ 变更管理、配置冻结          │ GitOps + 变更审批 + 配置版本化         │
│ 反洗钱          │ 交易可追溯、不可篡改        │ 审计日志 WORM 存储 + 区块链存证        │
│ 个人信息保护法  │ 数据最小化、删除权          │ 数据分类标签 + 自动清理策略            │
└─────────────────┴─────────────────────────────┴────────────────────────────────────────┘

关键数字：
  - 等保三级测评周期：每年一次
  - 央行现场检查：每年 1-2 次
  - 审计日志保留期：10 年（部分永久）
  - 变更审批时间：平均 3-5 天
  - 生产环境部署窗口：每月 1-2 次（凌晨 0:00-4:00）
```

### 1.2 银行的特殊约束

```
约束 1：物理隔离
  - 生产环境必须在自有数据中心
  - 不允许使用公有云（或只能用于开发测试）
  - 网络与互联网物理隔离

约束 2：变更审批
  - 任何生产变更都需要多级审批
  - 开发人员不能直接操作生产环境
  - 变更操作必须通过堡垒机，全程录屏

约束 3：数据本地化
  - 客户数据不得离开国境
  - 备份必须在同城异地
  - 跨境数据传输需要监管审批

约束 4：高可用要求
  - 核心交易系统：99.999%（年停机 < 5 分钟）
  - 网银系统：99.99%（年停机 < 52 分钟）
  - 必须支持两地三中心
```

---

## 第二章：私有云 K8s 平台架构

### 2.1 部署模式

```
模式：私有云 + 自有数据中心

┌────────────────────────────────────────────────────────────────────┐
│                    生产数据中心 A（主中心）                          │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐ │
│  │ K8s 控制平面 │  │ K8s Worker  │  │ 存储（Ceph/GlusterFS）      │ │
│  │ (3 节点 HA)  │  │ (50+ 节点)  │  │                             │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘ │
│                                                                      │
│  网络：Calico BGP + 自有骨干网                                        │
│  存储：Ceph RBD（块存储）+ CephFS（文件存储）                         │
│  监控：Prometheus + Grafana + 自研告警                                │
│  日志：ELK（本地部署）                                                │
│  GitOps：ArgoCD（离线部署）                                           │
└────────────────────────────────────────────────────────────────────┘

                          同城异地复制
                                │
                                ▼
┌────────────────────────────────────────────────────────────────────┐
│                    生产数据中心 B（备中心）                          │
│                                                                      │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────────┐ │
│  │ K8s 控制平面 │  │ K8s Worker  │  │ 存储（Ceph 同步复制）       │ │
│  │ (3 节点 HA)  │  │ (50+ 节点)  │  │                             │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────────┘ │
└────────────────────────────────────────────────────────────────────┘

硬件配置（单节点）：
  - CPU：64 核 Intel Xeon
  - 内存：512GB DDR4
  - 磁盘：8TB NVMe SSD（系统盘）+ 20TB SAS HDD（数据盘）
  - 网络：双 25Gbps 网卡
  - 数量：50+ Worker 节点
```

### 2.2 网络隔离

```yaml
# 银行网络的严格隔离要求
# 生产环境分为多个安全域

apiVersion: v1
kind: Namespace
metadata:
  name: core-banking
  labels:
    security-zone: dmz-high
    data-classification: critical
---
# 核心银行系统：默认拒绝所有流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: core-banking-deny-all
  namespace: core-banking
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
---
# 只允许来自 API 网关的流量
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: core-banking-allow-gateway
  namespace: core-banking
spec:
  podSelector:
    matchLabels:
      app: core-api
  policyTypes:
  - Ingress
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: api-gateway
    ports:
    - protocol: TCP
      port: 8080
---
# 只允许访问数据库
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: core-banking-allow-db
  namespace: core-banking
spec:
  podSelector:
    matchLabels:
      app: core-api
  policyTypes:
  - Egress
  egress:
  - to:
    - namespaceSelector:
        matchLabels:
          name: database
    ports:
    - protocol: TCP
      port: 3306
  - to:  # DNS
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: kube-system
      podSelector:
        matchLabels:
          k8s-app: kube-dns
    ports:
    - protocol: UDP
      port: 53
```

---

## 第三章：变更管理与 GitOps

### 3.1 变更审批流程

```
传统变更流程（不使用 K8s）：
  1. 开发人员提交变更申请单
  2. 技术经理审批
  3. 安全团队审批
  4. 运维团队审批
  5. 变更评审会（CAB）审批
  6. 预约变更窗口
  7. 运维人员手动执行变更
  8. 变更验证
  9. 变更关闭
  
  总耗时：3-10 天

GitOps 优化后的流程：
  1. 开发人员提交 PR（包含变更的 YAML）
  2. CI 自动验证（语法检查、策略检查）
  3. 技术经理 Code Review
  4. 安全团队审计（通过 Policy as Code）
  5. PR 合并到主分支
  6. ArgoCD 自动同步到集群（在变更窗口内）
  7. 自动验证（健康检查、冒烟测试）
  8. 变更记录自动归档
  
  总耗时：1-3 天（节省 50-70%）
  人工操作：减少 80%
```

### 3.2 变更窗口控制

```yaml
# ArgoCD 同步窗口控制
# 只允许在凌晨 0:00-4:00 同步生产环境

apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: production
  namespace: argocd
spec:
  description: Production Environment
  sourceRepos:
  - https://github.com/bank/gitops-prod.git
  destinations:
  - namespace: '*'
    server: https://prod-k8s.api
  syncWindows:
  - kind: allow
    schedule: '0 0 * * *'      # 每天 0:00 开始
    duration: 4h               # 持续 4 小时
    applications:
    - '*'
    clusters:
    - https://prod-k8s.api
  - kind: deny                 # 其他时间禁止同步
    schedule: '0 4 * * *'
    duration: 20h
    applications:
    - '*'
    clusters:
    - https://prod-k8s.api
```

---

## 第四章：审计与合规

### 4.1 不可篡改审计日志

```
审计要求：
  - 所有操作必须记录
  - 日志不可删除、不可修改
  - 保留期：10 年

技术实现：

API Server 审计日志
    │
    ├── 实时流 → Fluentd
    │              │
    │              ├──→ Kafka
    │              │       │
    │              │       ├──→ ELK（实时查询）
    │              │       │
    │              │       └──→ 区块链存证
    │              │               │
    │              │               └──→ 永久存储
    │              │
    │              └──→ WORM 存储（磁带库）
    │                      └──→ 离线归档
    │
    └── 本地保留 → 节点磁盘（30 天）

区块链存证：
  - 每 1000 条日志生成一个 Merkle Root
  - 写入联盟链（银行联盟）
  - 任何篡改都会导致 Root 不匹配
```

### 4.2 堡垒机集成

```
所有运维操作必须通过堡垒机：

运维人员 → VPN → 堡垒机 → 录屏审计 → K8s API Server
                 │
                 ├── 身份认证（LDAP + MFA）
                 ├── 操作授权（RBAC）
                 ├── 操作录屏（录屏保存 1 年）
                 ├── 命令审计（高危命令拦截）
                 └── 会话回放（事后审计）

高危命令拦截：
  - kubectl delete --all
  - kubectl drain
  - kubectl taint
  - 直接修改 etcd
  - 修改 kube-system 命名空间资源
```

---

## 第五章：两地三中心

### 5.1 架构设计

```
两地三中心：

  同城（同一城市，相距 < 50km）
    ├── 中心 A（主中心）
    │     - 承载 100% 生产流量
    │     - 数据库主节点
    │     
    └── 中心 B（同城灾备）
          - 同步复制
          - RPO = 0（数据零丢失）
          - RTO < 1 分钟

  异地（相距 > 500km）
    └── 中心 C（异地灾备）
          - 异步复制
          - RPO < 1 小时
          - RTO < 30 分钟

K8s 实现：
  - 中心 A 和 B：同一 K8s 集群（跨可用区）
  - 中心 C：独立 K8s 集群
  - 使用 Velero 备份应用状态到中心 C
```

### 5.2 数据库高可用

```yaml
# 使用 MySQL Operator 实现跨可用区高可用
apiVersion: mysql.oracle.com/v2
kind: InnoDBCluster
metadata:
  name: banking-mysql
  namespace: database
spec:
  secretName: banking-mysql-secret
  tlsUseSelfSigned: true
  instances: 3
  router:
    instances: 2
  podSpec:
    resources:
      requests:
        memory: 32Gi
        cpu: "8"
      limits:
        memory: 64Gi
        cpu: "16"
    affinity:
      podAntiAffinity:
        requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
            - key: app.kubernetes.io/name
              operator: In
              values: [mysql]
          topologyKey: topology.kubernetes.io/zone
```

---

## 第六章：面试核心考点

```
Q: 银行 K8s 平台与普通互联网平台的三个最大区别？

A:
   1. 合规是生死线：
      - 等保三级、央行规范必须 100% 满足
      - 审计日志保留 10 年，不可篡改
      - 任何不合规都可能导致牌照被吊销
   
   2. 变更管理极其严格：
      - 生产变更需要 3-5 级审批
      - 变更窗口每月只有 1-2 次
      - 所有操作必须通过堡垒机，全程录屏
   
   3. 高可用要求极高：
      - 核心系统 99.999%（年停机 < 5 分钟）
      - 必须支持两地三中心
      - 数据零丢失（RPO = 0）

Q: GitOps 如何帮助银行满足合规要求？

A:
   1. 变更可追溯：
      - 所有变更都在 Git 中有记录
      - 谁、什么时候、改了什么，一目了然
      - 满足审计要求
   
   2. 变更审批自动化：
      - PR Review 替代纸质审批单
      - Policy as Code 自动检查合规性
      - 减少人工错误
   
   3. 回滚能力：
      - Git 回滚 = 系统回滚
      - 秒级回滚到任意历史版本
      - 满足故障恢复要求
   
   4. 配置冻结：
      - Git 中的配置是唯一的来源
      - 手动修改会被 ArgoCD 自动恢复
      - 防止未经审批的变更

Q: 银行私有云 K8s 的存储方案如何选择？

A:
   银行通常使用 Ceph 或商业存储：
   
   Ceph：
   - 开源、无厂商锁定
   - 支持块存储（RBD）、文件存储（CephFS）、对象存储（RGW）
   - 需要专业运维团队
   - 性能：中等
   
   商业存储（如华为 OceanStor）：
   - 技术支持好
   - 性能高
   - 成本高
   - 需要原厂支持
   
   选择建议：
   - 大型银行：商业存储 + Ceph（分层）
   - 中小银行：Ceph（成本优先）
```
