# 07 - 云资源编排

平台工程不仅要管理 K8s 内部资源，还要为开发者提供云资源（数据库、对象存储、消息队列等）的自助服务能力。

---

## 7.1 为什么需要云资源编排？

**传统模式**：
```
开发者需要 RDS → 提交 JIRA → 运维评估 → 手动创建 → 3-5 天 → 交付凭据
```

**平台工程模式**：
```
开发者填写 YAML → GitOps 自动创建 → 5 分钟 → 凭据注入 Pod
```

---

## 7.2 技术选型

| 工具 | 模式 | 优点 | 缺点 | 适用场景 |
|------|------|------|------|---------|
| **Crossplane** | K8s 原生 CRD | GitOps 友好、统一控制平面 | 学习曲线高 | K8s 平台团队首选 |
| **Terraform** | 声明式 HCL | 生态最成熟、 Provider 最多 | 状态管理复杂 | 基础设施基线 |
| **Pulumi** | 代码式 | 开发者友好（Python/TS/Go） | 较新、社区较小 | 开发型团队 |
| **AWS Controllers / ACK** | K8s 原生 | 云厂商官方维护 | 仅限 AWS | AWS 专属平台 |
| ** ACK / ASO / Config Connector** | 云厂商 Controller | 深度集成 | 多云时碎片化 | 单云环境 |

**推荐组合**：
- **Crossplane** 管理 K8s 内动态创建的云资源（应用级）
- **Terraform** 管理基础设施基线（VPC、IAM、网络层）

---

## 7.3 Crossplane 深度实践

### 架构

```
┌─────────────────────────────────────────────────┐
│  Composite Resource (XR) - 开发者使用            │
│  PostgreSQLInstance.team-alpha                  │
├─────────────────────────────────────────────────┤
│  Composition (平台团队定义)                       │
│  → 封装 AWS RDS + SubnetGroup + SecurityGroup   │
├─────────────────────────────────────────────────┤
│  Managed Resources (MR)                         │
│  → RDSInstance, SubnetGroup, SecurityGroup      │
├─────────────────────────────────────────────────┤
│  Provider (AWS/GCP/Azure)                       │
│  → 调用云 API 创建实际资源                       │
└─────────────────────────────────────────────────┘
```

### 安装与配置

```bash
# 安装 Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace

# 安装 AWS Provider
kubectl apply -f - <<EOF
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v1.0.0
EOF

# 配置 Provider 凭据（IRSA 推荐）
kubectl apply -f - <<EOF
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: IRSA  # 或 Secret
EOF
```

### 定义 Composite Resource Definition (XRD)

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.company.io
spec:
  group: database.company.io
  names:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
  claimNames:
    kind: PostgreSQLClaim
    plural: postgresqlclaims
  versions:
  - name: v1alpha1
    served: true
    referenceable: true
    schema:
      openAPIV3Schema:
        type: object
        properties:
          spec:
            type: object
            properties:
              parameters:
                type: object
                properties:
                  storageGB:
                    type: integer
                    default: 20
                  version:
                    type: string
                    enum: ["13", "14", "15", "16"]
                    default: "15"
                  tier:
                    type: string
                    enum: ["small", "medium", "large"]
                    default: "small"
                  environment:
                    type: string
                    enum: ["dev", "staging", "prod"]
            required:
            - parameters
```

### 定义 Composition

```yaml
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xpostgresqlinstances.aws.database.company.io
  labels:
    provider: aws
    region: us-east-1
spec:
  compositeTypeRef:
    apiVersion: database.company.io/v1alpha1
    kind: XPostgreSQLInstance
  resources:
  # ─────────────────────────────────────────────
  # 资源 1：DB Subnet Group
  # ─────────────────────────────────────────────
  - name: dbsubnetgroup
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: SubnetGroup
      spec:
        forProvider:
          description: "Subnet group for PostgreSQL"
          subnetIds:
            - subnet-12345678
            - subnet-87654321
        providerConfigRef:
          name: default
    patches:
    - fromFieldPath: "spec.parameters.environment"
      toFieldPath: "metadata.annotations[environment]"

  # ─────────────────────────────────────────────
  # 资源 2：Security Group
  # ─────────────────────────────────────────────
  - name: securitygroup
    base:
      apiVersion: ec2.aws.upbound.io/v1beta1
      kind: SecurityGroup
      spec:
        forProvider:
          description: "PostgreSQL access"
          vpcId: vpc-12345678
          ingress:
            - fromPort: 5432
              toPort: 5432
              protocol: tcp
              cidrBlocks: ["10.0.0.0/8"]
        providerConfigRef:
          name: default

  # ─────────────────────────────────────────────
  # 资源 3：RDS Instance（核心）
  # ─────────────────────────────────────────────
  - name: rdsinstance
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: Instance
      spec:
        forProvider:
          engine: postgres
          skipFinalSnapshot: true
          publiclyAccessible: false
          storageEncrypted: true
          backupRetentionPeriod: 7
          applyImmediately: false
          autoMinorVersionUpgrade: true
          deletionProtection: false
        providerConfigRef:
          name: default
        writeConnectionSecretToRef:
          namespace: crossplane-system
    patches:
    # 从 Composite Resource 传递参数
    - fromFieldPath: "spec.parameters.storageGB"
      toFieldPath: "spec.forProvider.allocatedStorage"
    - fromFieldPath: "spec.parameters.version"
      toFieldPath: "spec.forProvider.engineVersion"
    # 根据 tier 设置实例类型
    - type: ToCompositeFieldPath
      fromFieldPath: "spec.parameters.tier"
      toFieldPath: "status.atProvider.instanceClass"
      transforms:
      - type: map
        map:
          small: db.t3.micro
          medium: db.t3.large
          large: db.r6g.xlarge
    # 环境标签
    - fromFieldPath: "spec.parameters.environment"
      toFieldPath: "spec.forProvider.tags[0].key"
      transforms:
      - type: string
        string:
          fmt: "Environment"
    - fromFieldPath: "spec.parameters.environment"
      toFieldPath: "spec.forProvider.tags[0].value"

  # ─────────────────────────────────────────────
  # 连接信息输出
  # ─────────────────────────────────────────────
  - name: connection
    base:
      apiVersion: kubernetes.crossplane.io/v1alpha1
      kind: Object
      spec:
        forProvider:
          manifest:
            apiVersion: v1
            kind: Secret
            metadata:
              namespace: default  # 会被覆盖
            type: Opaque
        providerConfigRef:
          name: kubernetes-provider
    patches:
    - fromFieldPath: "metadata.labels[crossplane.io/claim-namespace]"
      toFieldPath: "spec.forProvider.manifest.metadata.namespace"
    - fromFieldPath: "status.atProvider.endpoint"
      toFieldPath: "spec.forProvider.manifest.stringData[endpoint]"
    - fromFieldPath: "status.atProvider.username"
      toFieldPath: "spec.forProvider.manifest.stringData[username]"
    - fromFieldPath: "status.atProvider.password]"
      toFieldPath: "spec.forProvider.manifest.stringData[password]"
```

### 开发者使用（Claim）

```yaml
apiVersion: database.company.io/v1alpha1
kind: PostgreSQLClaim
metadata:
  name: payment-db
  namespace: team-alpha
spec:
  compositionSelector:
    matchLabels:
      provider: aws
      region: us-east-1
  parameters:
    storageGB: 50
    version: "15"
    tier: medium
    environment: dev
  # 凭据写入目标
  writeConnectionSecretToRef:
    name: payment-db-connection
```

### 与 GitOps 集成

```yaml
# ArgoCD 管理 Crossplane 资源
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-platform
spec:
  source:
    repoURL: https://github.com/company/platform-gitops
    path: crossplane/
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    syncOptions:
      - ServerSideApply=true  # 关键：Crossplane CRD 较大，需要 SSA
```

---

## 7.4 Terraform + Crossplane 混合模式

### 职责分离

| 层级 | 工具 | 管理内容 | 变更频率 |
|------|------|---------|---------|
| 基础设施基线 | Terraform | VPC、Subnet、IAM、网络、基础安全组 | 低（季度） |
| 平台组件 | Terraform/Helm | EKS 集群、Crossplane、Ingress Controller | 中（月度） |
| 应用资源 | Crossplane | RDS、S3、SQS、ElastiCache | 高（每日） |

### Terraform 管理 Crossplane 安装

```hcl
# terraform/crossplane.tf
resource "helm_release" "crossplane" {
  name       = "crossplane"
  repository = "https://charts.crossplane.io/stable"
  chart      = "crossplane"
  namespace  = "crossplane-system"
  create_namespace = true

  set {
    name  = "args[0]"
    value = "--enable-composition-revisions"
  }
}

resource "kubectl_manifest" "provider_aws" {
  yaml_body = <<-EOF
    apiVersion: pkg.crossplane.io/v1
    kind: Provider
    metadata:
      name: provider-aws-rds
    spec:
      package: xpkg.upbound.io/upbound/provider-aws-rds:v1.0.0
  EOF

  depends_on = [helm_release.crossplane]
}
```

---

## 7.5 成本与安全控制

### 资源审批工作流

```yaml
# 使用 Kyverno 限制 Claim 的规格
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: limit-database-claims
spec:
  validationFailureAction: Enforce
  rules:
  - name: limit-storage
    match:
      resources:
        kinds:
        - PostgreSQLClaim.database.company.io
    validate:
      message: "Dev environment database storage cannot exceed 100GB"
      pattern:
        spec:
          parameters:
            =(environment): "dev"
            storageGB: "<=100"
  - name: limit-tier
    match:
      resources:
        kinds:
        - PostgreSQLClaim.database.company.io
    validate:
      message: "Only 'small' and 'medium' tiers are allowed without approval"
      pattern:
        spec:
          parameters:
            tier: "small | medium"
```

### 自动清理

```yaml
apiVersion: database.company.io/v1alpha1
kind: PostgreSQLClaim
metadata:
  name: temp-analytics-db
  namespace: team-alpha
  annotations:
    # 平台自定义：TTL 自动删除
    platform.company.io/ttl: "168h"  # 7 天后自动删除
spec:
  parameters:
    storageGB: 20
    tier: small
    environment: dev
```

---

## 7.6 替代方案：ACK / ASO / Config Connector

### AWS Controllers for Kubernetes (ACK)

```yaml
# 云厂商官方方案，更轻量
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: payment-db
spec:
  allocatedStorage: 20
  dbInstanceClass: db.t3.micro
  engine: postgres
  engineVersion: "15"
  masterUsername: admin
  publiclyAccessible: false
  storageEncrypted: true
```

**与 Crossplane 对比**：
- ACK：AWS 专属，更轻量，深度集成 AWS 特性
- Crossplane：多云统一，Composition 抽象能力强，适合构建平台

---

## 最佳实践

- [ ] XRD 设计遵循"最小可用接口"原则，不要暴露过多云厂商参数
- [ ] Composition 中强制安全默认值（加密、私有访问、备份）
- [ ] 使用 Kyverno/OPA 限制 Claim 的规格，防止资源滥用
- [ ] 敏感凭据通过 ConnectionSecret 自动注入，不手动传递
- [ ] 为开发/测试环境配置自动 TTL，防止资源闲置
- [ ] 定期审计云资源与实际 Claim 的一致性
- [ ] Crossplane Provider 定期升级，关注 CVE

## 多云资源管理策略

### 资源生命周期管理

**自动清理策略**:
```yaml
# 开发环境资源 TTL
apiVersion: resources.crossplane.io/v1alpha1
kind: ResourceClaim
metadata:
  name: dev-db
  annotations:
    crossplane.io/ttl: "168h"  # 7 天后自动删除
spec:
  compositionRef:
    name: postgresql
  parameters:
    environment: dev
    size: small
```

**成本标签策略**:
```yaml
# 强制所有云资源打标签
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-cost-labels
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-labels
    match:
      resources:
        kinds:
        - "*.aws.crossplane.io/*"
    validate:
      message: "云资源必须包含 cost-center、environment、owner 标签"
      pattern:
        metadata:
          labels:
            cost-center: "?*"
            environment: "dev|staging|prod"
            owner: "?*"
```

### 多云一致性抽象

**统一资源模型**:
```
Crossplane Claim (通用)
    ↓
Composition (多云映射)
    ↓
┌─────────────┬─────────────┬─────────────┐
│   AWS       │   GCP       │   Azure     │
│  RDS        │ Cloud SQL   │  PostgreSQL │
│  S3         │ Cloud Stg   │ Blob Stg    │
│  ElastiCache│ Memorystore │ Redis Cache │
└─────────────┴─────────────┴─────────────┘
```

**迁移场景**:
```bash
# 从 AWS 迁移到 GCP，无需修改应用
# 1. 创建新的 GCP Composition
# 2. 更新 CompositionRef
# 3. 数据迁移（使用供应商工具）
# 4. 切换 DNS/连接字符串
# 5. 删除旧 AWS 资源
```

### 资源配额与治理

**平台级配额管理**:
```yaml
# 限制每个团队的云资源预算
apiVersion: resources.crossplane.io/v1alpha1
kind: ResourceQuotaClaim
metadata:
  name: team-alpha-quota
spec:
  parameters:
    maxMonthlyCost: 5000
    allowedRegions:
    - us-east-1
    - eu-west-1
    allowedServices:
    - rds
    - s3
    - elasticache
    deniedServices:
    - ec2  # 禁止直接创建 EC2，强制使用 EKS
```

## 面试常见问题补充

**Q: Crossplane 和 Terraform 怎么配合使用？**

A: 分层架构:

| 层级 | 工具 | 职责 |
|------|------|------|
| 基础设施层 | Terraform | 创建 K8s 集群、VPC、IAM 角色（低频变更） |
| 平台层 | Crossplane | 动态资源供应（数据库、缓存、存储）（高频变更） |
| 应用层 | Helm/Kustomize | 应用部署（最高频变更） |

协作模式:
1. Terraform 创建 EKS 集群 + 安装 Crossplane
2. Crossplane 在集群内响应开发者的资源请求
3. 开发者通过 kubectl 申请资源，无需接触 Terraform

**Q: 如何处理云资源的 secrets 管理？**

A: Crossplane 的 ConnectionSecret 机制:
```yaml
# 资源创建时自动生成 secrets
apiVersion: rds.services.k8s.aws/v1alpha1
kind: DBInstance
metadata:
  name: mydb
spec:
  writeConnectionSecretToRef:
    name: mydb-connection
    namespace: default
# 自动生成:
# - endpoint
# - port
# - username
# - password
```

使用 External Secrets Operator 同步到应用:
```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
spec:
  secretStoreRef:
    name: k8s-store
    kind: ClusterSecretStore
  target:
    name: db-credentials
  dataFrom:
  - extract:
      key: mydb-connection
```

