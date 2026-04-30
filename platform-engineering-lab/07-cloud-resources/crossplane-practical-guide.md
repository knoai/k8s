# Crossplane 云资源管理深度实践

> Crossplane 是 K8s 原生的多云控制平面，通过声明式方式管理云资源。
> 本节从架构设计到生产落地，提供完整的实践指南。

---

## 一、Crossplane 架构

### 1.1 核心组件

```
Crossplane 架构：

┌─────────────────────────────────────────┐
│  User / GitOps                          │
│   - 声明 Managed Resource (MR)          │
│   - 声明 Composite Resource (XR)        │
│   - 声明 Claim (XRC)                    │
└──────────────┬──────────────────────────┘
               │ kubectl apply
               ▼
┌─────────────────────────────────────────┐
│  Crossplane Core                        │
│   - Composition Engine                  │
│   - Claim / Composite Reconciler        │
│   - Package Manager                     │
└──────────────┬──────────────────────────┘
               │ gRPC
               ▼
┌─────────────────────────────────────────┐
│  Provider (AWS/GCP/Azure/阿里云)         │
│   - Managed Reconciler                  │
│   - 调用云 API 创建/更新/删除资源        │
│   - 定期 Observe 资源状态               │
└──────────────┬──────────────────────────┘
               │ Cloud API
               ▼
┌─────────────────────────────────────────┐
│  Cloud Provider                         │
│   - RDS / S3 / VPC / ECS / SLB          │
└─────────────────────────────────────────┘

核心概念：
  Provider：云厂商插件（AWS Provider、GCP Provider 等）
  ProviderConfig：云厂商认证配置（AK/SK、IAM Role）
  Managed Resource (MR)：单一云资源的 K8s CRD（如 RDSInstance、S3Bucket）
  Composite Resource Definition (XRD)：自定义复合资源的 schema
  Composition：XRD 到 MR 的映射模板
  Composite Resource (XR)：XRD 的实例
  Claim (XRC)：XR 的命名空间级别声明
```

### 1.2 安装

```bash
# 安装 Crossplane
helm repo add crossplane-stable https://charts.crossplane.io/stable
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --set args='{"--enable-composition-revisions"}'

# 验证
kubectl get pods -n crossplane-system
# NAME                                         READY   STATUS    RESTARTS   AGE
# crossplane-xxx                               1/1     Running   0          1m
# crossplane-rbac-manager-xxx                  1/1     Running   0          1m

# 安装 Provider（以 AWS 为例）
cat > provider-aws.yaml <<'EOF'
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-rds
spec:
  package: xpkg.upbound.io/upbound/provider-aws-rds:v0.47.0
---
apiVersion: pkg.crossplane.io/v1
kind: Provider
metadata:
  name: provider-aws-s3
spec:
  package: xpkg.upbound.io/upbound/provider-aws-s3:v0.47.0
EOF
kubectl apply -f provider-aws.yaml

# 等待 Provider 就绪
kubectl wait --for=condition=Healthy provider provider-aws-rds --timeout=300s
kubectl wait --for=condition=Healthy provider provider-aws-s3 --timeout=300s

# 查看 Provider 安装的 CRD
kubectl get crd | grep -E "rds|s3" | head -10
```

---

## 二、认证配置

### 2.1 AWS 认证

```yaml
# 方法 1：使用 IAM User（AK/SK）
apiVersion: v1
kind: Secret
metadata:
  name: aws-credentials
  namespace: crossplane-system
type: Opaque
stringData:
  creds: |
    [default]
    aws_access_key_id = AKIAXXXXXXXX
    aws_secret_access_key = xxxxxxxxxxxxxxxxxxxxxxxx
---
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: default
spec:
  credentials:
    source: Secret
    secretRef:
      namespace: crossplane-system
      name: aws-credentials
      key: creds

# 方法 2：使用 IAM Role（IRSA，推荐）
# 1. 创建 IAM Role，信任关系指向 ServiceAccount
# 2. 为 Role 附加策略（AmazonRDSFullAccess、AmazonS3FullAccess）
# 3. 创建 ServiceAccount 并注解 Role ARN
apiVersion: v1
kind: ServiceAccount
metadata:
  name: crossplane-provider-aws
  namespace: crossplane-system
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/crossplane-provider-aws
---
apiVersion: aws.upbound.io/v1beta1
kind: ProviderConfig
metadata:
  name: irsa
spec:
  credentials:
    source: IRSA                    # 使用 IRSA 认证

# 方法 3：使用 Web Identity（OIDC）
# 适用于非 EKS 环境，通过 OIDC 提供者获取临时凭证
```

---

## 三、Managed Resource 管理

### 3.1 直接管理云资源

```yaml
# S3 Bucket
apiVersion: s3.aws.upbound.io/v1beta1
kind: Bucket
metadata:
  name: my-app-bucket
  labels:
    app: my-app
    environment: production
spec:
  forProvider:
    region: us-east-1
    acl: private
    versioning:
      - enabled: true
    serverSideEncryptionConfiguration:
      - rule:
          - applyServerSideEncryptionByDefault:
              - sseAlgorithm: AES256
    lifecycleRule:
      - id: delete-old-versions
        enabled: true
        noncurrentVersionExpiration:
          - days: 30
  providerConfigRef:
    name: default
  deletionPolicy: Orphan          # 删除 MR 时保留云资源

---
# RDS Instance
apiVersion: rds.aws.upbound.io/v1beta1
kind: Instance
metadata:
  name: my-app-db
spec:
  forProvider:
    allocatedStorage: 20
    engine: mysql
    engineVersion: "8.0"
    instanceClass: db.t3.micro
    dbName: myapp
    username: admin
    passwordSecretRef:
      name: db-password
      namespace: crossplane-system
      key: password
    publiclyAccessible: false
    skipFinalSnapshot: true
    storageEncrypted: true
    kmsKeyId: alias/aws/rds
    backupRetentionPeriod: 7
    multiAz: false                  # 生产环境建议 true
    region: us-east-1
  providerConfigRef:
    name: default
  deletionPolicy: Delete
  writeConnectionSecretToRef:
    name: my-app-db-connection
    namespace: crossplane-system

# 生成的 Secret 内容：
# kubectl get secret my-app-db-connection -n crossplane-system -o yaml
# data:
#   password: <base64>
#   username: <base64>
#   endpoint: <base64>
#   port: <base64>
```

### 3.2 资源引用

```yaml
# 创建 VPC
apiVersion: ec2.aws.upbound.io/v1beta1
kind: VPC
metadata:
  name: my-app-vpc
spec:
  forProvider:
    cidrBlock: 10.0.0.0/16
    region: us-east-1
    tags:
      Name: my-app-vpc

---
# 创建子网（引用 VPC）
apiVersion: ec2.aws.upbound.io/v1beta1
kind: Subnet
metadata:
  name: my-app-subnet-1a
spec:
  forProvider:
    cidrBlock: 10.0.1.0/24
    vpcIdSelector:
      matchControllerRef: true      # 引用同 Composition 中的 VPC
    availabilityZone: us-east-1a
    region: us-east-1

---
# 创建安全组（引用 VPC）
apiVersion: ec2.aws.upbound.io/v1beta1
kind: SecurityGroup
metadata:
  name: my-app-sg
spec:
  forProvider:
    name: my-app-sg
    description: Security group for my app
    vpcIdSelector:
      matchControllerRef: true
    region: us-east-1
    ingress:
      - fromPort: 80
        toPort: 80
        protocol: tcp
        cidrBlocks: ["0.0.0.0/0"]
      - fromPort: 443
        toPort: 443
        protocol: tcp
        cidrBlocks: ["0.0.0.0/0"]
    egress:
      - fromPort: 0
        toPort: 0
        protocol: "-1"
        cidrBlocks: ["0.0.0.0/0"]

---
# 创建 RDS（引用子网和安全组）
apiVersion: rds.aws.upbound.io/v1beta1
kind: Instance
metadata:
  name: my-app-db
spec:
  forProvider:
    dbSubnetGroupNameSelector:
      matchControllerRef: true
    vpcSecurityGroupIdsSelector:
      matchControllerRef: true
    # ... 其他配置
```

---

## 四、Composite Resource（复合资源）

### 4.1 定义复合资源

```yaml
# 步骤 1：定义 XRD（Composite Resource Definition）
apiVersion: apiextensions.crossplane.io/v1
kind: CompositeResourceDefinition
metadata:
  name: xpostgresqlinstances.database.example.org
spec:
  group: database.example.org
  names:
    kind: XPostgreSQLInstance
    plural: xpostgresqlinstances
  claimNames:
    kind: PostgreSQLInstance
    plural: postgresqlinstances
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
                    description: "Storage size in GB"
                  version:
                    type: string
                    enum: ["11", "12", "13", "14", "15"]
                    default: "14"
                  instanceClass:
                    type: string
                    enum: ["db.t3.micro", "db.t3.small", "db.t3.medium", "db.t3.large"]
                    default: "db.t3.micro"
                  multiAz:
                    type: boolean
                    default: false
                  backupRetentionDays:
                    type: integer
                    default: 7
                  public:
                    type: boolean
                    default: false
            required:
            - parameters

# 步骤 2：定义 Composition（模板）
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-aws
  labels:
    provider: aws
    region: us-east-1
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
    kind: XPostgreSQLInstance
  resources:
  # 资源 1：RDS Instance
  - name: rdsinstance
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: Instance
      spec:
        forProvider:
          engine: postgres
          publiclyAccessible: false
          skipFinalSnapshotBeforeDeletion: true
          storageEncrypted: true
          autoMinorVersionUpgrade: true
          performanceInsightsEnabled: true
        providerConfigRef:
          name: default
        writeConnectionSecretToRef:
          namespace: crossplane-system
    patches:
    - fromFieldPath: spec.parameters.storageGB
      toFieldPath: spec.forProvider.allocatedStorage
    - fromFieldPath: spec.parameters.version
      toFieldPath: spec.forProvider.engineVersion
    - fromFieldPath: spec.parameters.instanceClass
      toFieldPath: spec.forProvider.instanceClass
    - fromFieldPath: spec.parameters.multiAz
      toFieldPath: spec.forProvider.multiAz
    - fromFieldPath: spec.parameters.backupRetentionDays
      toFieldPath: spec.forProvider.backupRetentionPeriod
    - fromFieldPath: metadata.uid
      toFieldPath: spec.writeConnectionSecretToRef.name
      transforms:
      - type: string
        string:
          fmt: "%s-postgresql"

  # 资源 2：DB Subnet Group
  - name: dbsubnetgroup
    base:
      apiVersion: rds.aws.upbound.io/v1beta1
      kind: SubnetGroup
      spec:
        forProvider:
          description: Subnet group for PostgreSQL
          subnetIds:
          - subnet-0abc123def456
          - subnet-0abc123def457
        providerConfigRef:
          name: default
    patches:
    - fromFieldPath: metadata.name
      toFieldPath: metadata.name
      transforms:
      - type: string
        string:
          fmt: "%s-subnet-group"

  # 资源 3：自动生成的密码
  - name: password
    base:
      apiVersion: kubernetes.crossplane.io/v1alpha1
      kind: Object
      spec:
        forProvider:
          manifest:
            apiVersion: v1
            kind: Secret
            metadata:
              name: ""  # patched
              namespace: crossplane-system
            stringData:
              password: ""  # patched
        providerConfigRef:
          name: kubernetes-provider
    patches:
    - fromFieldPath: metadata.name
      toFieldPath: spec.forProvider.manifest.metadata.name
      transforms:
      - type: string
        string:
          fmt: "%s-password"
    - fromFieldPath: metadata.name
      toFieldPath: spec.forProvider.manifest.stringData.password
      transforms:
      - type: string
        string:
          fmt: "auto-generated-%s"

  # 连接信息输出
  connectionDetails:
  - fromConnectionSecretKey: username
  - fromConnectionSecretKey: password
  - fromConnectionSecretKey: endpoint
  - fromConnectionSecretKey: port

# 步骤 3：用户创建 Claim
apiVersion: database.example.org/v1alpha1
kind: PostgreSQLInstance
metadata:
  name: order-service-db
  namespace: production
spec:
  parameters:
    storageGB: 100
    version: "14"
    instanceClass: db.t3.medium
    multiAz: true
    backupRetentionDays: 14
    public: false
  compositionSelector:
    matchLabels:
      provider: aws
      region: us-east-1
  writeConnectionSecretToRef:
    name: order-service-db-connection
```

---

## 五、生产实践

### 5.1 GitOps 管理

```yaml
# ArgoCD Application 管理 Crossplane 资源
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: crossplane-infrastructure
  namespace: argocd
spec:
  project: infrastructure
  source:
    repoURL: https://github.com/my-org/infrastructure.git
    targetRevision: main
    path: crossplane/
  destination:
    server: https://kubernetes.default.svc
    namespace: crossplane-system
  syncPolicy:
    automated:
      prune: false        # 不自动删除云资源！
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
    - PrunePropagationPolicy=orphan
```

### 5.2 漂移检测

```bash
# Crossplane 自动检测云资源漂移
# 如果云控制台修改了资源，Crossplane 会尝试恢复

# 查看资源同步状态
kubectl get managed -A

# 暂停管理（防止误删）
kubectl patch rdsinstance my-app-db --type='merge' -p '
{"metadata":{"annotations":{"crossplane.io/paused":"true"}}}'

# 修改 deletionPolicy
kubectl patch rdsinstance my-app-db --type='merge' -p '{"spec":{"deletionPolicy":"Orphan"}}'
```

### 5.3 监控

```yaml
# PrometheusRule 监控 Crossplane
groups:
- name: crossplane
  rules:
  - alert: CrossplaneResourceNotSynced
    expr: crossplane_resource_synced{status="False"} == 1
    for: 10m
    labels:
      severity: warning
    annotations:
      summary: "Crossplane resource {{ $labels.name }} is not synced"

  - alert: CrossplaneProviderErrors
    expr: rate(crossplane_provider_reconcile_errors_total[5m]) > 0.1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Crossplane provider has high error rate"
```

---

## 六、面试要点

```
Q: Crossplane 与 Terraform 的区别？

A: 核心差异在控制平面和声明式模型：

   Crossplane：
   - K8s 原生，使用 YAML
   - 控制平面运行在 K8s 中
   - 持续调和（Continuous Reconciliation）
   - 支持 GitOps（ArgoCD/Flux）
   - 支持多租户（Namespace 隔离）
   - 社区相对较小
   
   Terraform：
   - 使用 HCL 语言
   - 客户端执行（CLI）
   - 一次性应用（apply 后不再管理）
   - 状态文件管理复杂
   - 生态更成熟（模块丰富）
   
   选择建议：
   - K8s 原生团队：Crossplane
   - 多云复杂架构：Terraform
   - 也可以结合：Terraform 初始部署，Crossplane 持续管理

Q: Crossplane 的 drift（漂移）如何处理？

A: Crossplane 的设计是"Git 是真理"：

   检测：
   - Provider 定期 Observe 云资源状态
   - 与 Git 中的期望状态比较
   - 发现差异时标记 Synced=False
   
   恢复：
   - 自动尝试更新云资源以匹配 Git
   - 如果云 API 不允许修改，标记错误
   
   处理策略：
   1. 修改 Git 匹配实际状态（推荐）
   2. 暂停管理（crossplane.io/paused: true）
   3. 设置 deletionPolicy: Orphan 后删除 MR
   
   注意：
   - 生产环境谨慎使用 deletionPolicy: Delete
   - 建议配合 ArgoCD 的 prune: false
```
