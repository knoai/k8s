# 生产排障：Crossplane 资源漂移

> Crossplane 声明式管理云资源时，外部变更导致实际状态与期望状态不一致。
> 本节提供检测、修复和预防资源漂移的完整方法。

---

## Crossplane 架构回顾

```
用户定义 Managed Resource (MR)
    │
    ├─ Claim (XRC) → Composite Resource (XR) → Managed Resource (MR)
    │   例如：MySQLInstance Claim → XMySQLInstance → RDSInstance
    │
    └─ 直接创建 Managed Resource
        例如：RDSInstance, S3Bucket, VPC

Provider 工作流：
  Crossplane → Provider (AWS/GCP/Azure) → 云 API
       │
       ├─ Create: 调用云 API 创建资源
       ├─ Observe: 定期轮询云 API 获取实际状态
       ├─ Update: 实际状态 != 期望状态时更新
       └─ Delete: 删除资源

漂移场景：
  1. 用户在云控制台手动修改了资源（标签、安全组、实例规格）
  2. 其他自动化工具修改了资源（Terraform、其他 Crossplane Provider）
  3. 云提供商自动更新了资源（维护、升级）
  4. Crossplane Provider 未正确 Observe
```

---

## 诊断资源漂移

### 1.1 查看资源状态

```bash
# 查看 RDSInstance 状态
kubectl get rdsinstance my-db -o yaml

# 预期输出（健康，无漂移）：
# apiVersion: database.aws.crossplane.io/v1beta1
# kind: RDSInstance
# metadata:
#   name: my-db
# spec:
#   forProvider:
#     dbInstanceClass: db.t3.medium
#     engine: mysql
#     engineVersion: "8.0"
#     allocatedStorage: 20
#     tags:
#       - key: Environment
#         value: production
#       - key: ManagedBy
#         value: crossplane
# status:
#   atProvider:
#     dbInstanceStatus: available
#     dbInstanceArn: arn:aws:rds:us-east-1:123456789012:db:my-db
#     allocatedStorage: 20
#   conditions:
#   - type: Ready
#     status: "True"
#     lastTransitionTime: "2024-01-15T08:30:00Z"
#     reason: Available
#   - type: Synced
#     status: "True"
#     lastTransitionTime: "2024-01-15T08:30:00Z"
#     reason: ReconcileSuccess
# ← Ready=True, Synced=True 表示正常

# 危险信号（有漂移）：
# status:
#   conditions:
#   - type: Ready
#     status: "True"
#     reason: Available
#   - type: Synced
#     status: "False"                        ← Synced=False！
#     lastTransitionTime: "2024-01-15T08:30:00Z"
#     reason: ReconcileError
#     message: 'update failed: cannot modify RDS instance: 
#       InvalidParameterCombination: Cannot upgrade db.t3.medium to db.t3.large 
#       because ...'
# ← 云控制台修改了实例规格，Crossplane 尝试恢复失败！
```

### 1.2 查看 Provider 日志

```bash
# 查看 Crossplane Provider 日志
kubectl logs -n crossplane-system deployment/provider-aws-rds-xxx | grep -E "my-db|drift|update|observe" | tail -30

# 输出：
# 2024-01-15T08:30:00.123Z	DEBUG	provider-aws	Observing external resource	
#   {"controller": "managed/rdsinstance.database.aws.crossplane.io", 
#    "request": "/my-db", "uid": "abc123...", 
#    "version": "12345", "external-name": "my-db", 
#    "reconciler group": "database.aws.crossplane.io", 
#    "reconciler kind": "RDSInstance"}
# 
# 2024-01-15T08:30:00.234Z	DEBUG	provider-aws	Diff detected	
#   {"controller": "managed/rdsinstance.database.aws.crossplane.io", 
#    "request": "/my-db", 
#    "diff": "- dbInstanceClass: db.t3.medium\n+ dbInstanceClass: db.t3.large\n"}
# ← 检测到漂移：实例规格从 medium 变成 large！
# 
# 2024-01-15T08:30:00.345Z	DEBUG	provider-aws	Updating external resource	
#   {"controller": "managed/rdsinstance.database.aws.crossplane.io", 
#    "request": "/my-db"}
# 
# 2024-01-15T08:30:01.456Z	ERROR	provider-aws	Reconciler error	
#   {"controller": "managed/rdsinstance.database.aws.crossplane.io", 
#    "request": "/my-db", 
#    "error": "update failed: cannot modify RDS instance: 
#     InvalidParameterCombination: Cannot upgrade db.t3.medium to db.t3.large 
#     because ..."}
# ← 更新失败！因为 AWS 不允许某些修改
```

### 1.3 查看事件

```bash
kubectl get events --field-selector involvedObject.name=my-db | tail -20

# 输出：
# LAST SEEN   TYPE      REASON           OBJECT          MESSAGE
# 10m         Warning   UpdateFailed     rdsinstance/my-db    cannot update RDS instance: ...
# 10m         Normal    UpdatedExternal  rdsinstance/my-db    Successfully requested update of external resource
# 10m         Warning   UpdateFailed     rdsinstance/my-db    cannot update RDS instance: ...
# ← 反复 UpdateFailed
```

---

## 根因 1：云控制台手动修改

### 现象

```bash
# 在 AWS 控制台修改了 RDS 实例规格：db.t3.medium → db.t3.large
# Crossplane MR 中仍然是 db.t3.medium
# Crossplane 尝试恢复，但 AWS 不允许降级

# 查看实际云资源状态
aws rds describe-db-instances --db-instance-identifier my-db --query 'DBInstances[0].[DBInstanceClass,AllocatedStorage,EngineVersion,TagList]'

# 输出：
# [
#     "db.t3.large",       ← 实际是 large！
#     20,
#     "8.0.33",
#     [
#         {"Key": "Environment", "Value": "production"},
#         {"Key": "ManagedBy", "Value": "crossplane"},
#         {"Key": "manual-tag", "Value": "added-from-console"}  ← 手动添加的标签！
#     ]
# ]
```

### 修复

```bash
# 方案 1：更新 MR 匹配实际状态（推荐）
kubectl patch rdsinstance my-db --type='merge' -p '
{
  "spec": {
    "forProvider": {
      "dbInstanceClass": "db.t3.large"
    }
  }
}'

# 验证
kubectl get rdsinstance my-db -o jsonpath='{.status.conditions}' | jq .
# [
#   {"type": "Ready", "status": "True"},
#   {"type": "Synced", "status": "True"}   ← 恢复同步！
# ]

# 方案 2：删除手动添加的标签
aws rds remove-tags-from-resource \
  --resource-name arn:aws:rds:us-east-1:123456789012:db:my-db \
  --tag-keys manual-tag

# 或者更新 MR 包含新标签
kubectl patch rdsinstance my-db --type='merge' -p '
{
  "spec": {
    "forProvider": {
      "tags": [
        {"key": "Environment", "value": "production"},
        {"key": "ManagedBy", "value": "crossplane"},
        {"key": "manual-tag", "value": "added-from-console"}
      ]
    }
  }
}'

# 方案 3：如果无法自动恢复，暂停管理
kubectl patch rdsinstance my-db --type='merge' -p '
{
  "metadata": {
    "annotations": {
      "crossplane.io/paused": "true"
    }
  }
}'
# ← 暂停后 Crossplane 不再尝试同步该资源
```

---

## 根因 2：Provider 版本不兼容

### 现象

```bash
# 升级 Provider 后，某些字段不再支持
kubectl get providerrevisions

# 输出：
# NAME           HEALTHY   REVISION   IMAGE
# provider-aws   True      1          crossplane/provider-aws:v0.35.0
# provider-aws   True      2          crossplane/provider-aws:v0.40.0  ← 新版本

# 查看事件
kubectl get events | grep -E "FieldNotFound|UnknownField"

# 输出：
# Warning  UpdateFailed  rdsinstance/my-db  cannot update RDS instance: 
#   unknown field "storageEncrypted" in v1beta1.RDSInstanceParameters
# ← 新版本 Provider 中字段名称或结构变了！
```

### 修复

```bash
# 方案 1：更新 MR 使用新字段名
# 查看新版本的 CRD
kubectl get crd rdsinstances.database.aws.crossplane.io -o yaml | grep -A 5 storageEncrypted

# 发现新字段名是 "storageEncrypted" → "storageEncrypted"（可能没变，但位置变了）
# 或者需要嵌套在其他结构中

# 方案 2：降级 Provider
kubectl patch provider provider-aws --type='merge' -p '
{
  "spec": {
    "package": "crossplane/provider-aws:v0.35.0"
  }
}'

# 方案 3：手动迁移资源到新版本
# 1. 导出当前 MR
kubectl get rdsinstance my-db -o yaml > my-db-backup.yaml

# 2. 删除旧版本 MR（保留云资源！）
kubectl delete rdsinstance my-db --cascade=orphan
# --cascade=orphan 确保不删除云资源

# 3. 使用新版本的字段创建 MR
cat > my-db-new.yaml <<'EOF'
apiVersion: database.aws.crossplane.io/v1beta1
kind: RDSInstance
metadata:
  name: my-db
spec:
  forProvider:
    # 使用新版本的字段结构
    dbInstanceClass: db.t3.large
    engine: mysql
    # ... 其他字段
  providerConfigRef:
    name: default
EOF
kubectl apply -f my-db-new.yaml
```

---

## 根因 3：权限不足

### 现象

```bash
# Provider Pod 日志
kubectl logs -n crossplane-system deployment/provider-aws-rds-xxx | grep -E "AccessDenied|Unauthorized"

# 输出：
# 2024-01-15T08:30:00.123Z	ERROR	provider-aws	Reconciler error	
#   {"error": "observe failed: cannot get RDS instance: 
#    AccessDenied: User: arn:aws:sts::123456789012:assumed-role/crossplane-provider-aws/xxx 
#    is not authorized to perform: rds:DescribeDBInstances on resource: arn:aws:rds:us-east-1:123456789012:db:my-db"}
# ← IAM Role 缺少 rds:DescribeDBInstances 权限！
```

### 修复

```bash
# 方案 1：更新 IAM Policy
# 查看当前 ProviderConfig
kubectl get providerconfig aws-provider -o yaml

# 更新 IAM Role Policy
aws iam attach-role-policy \
  --role-name crossplane-provider-aws \
  --policy-arn arn:aws:iam::aws:policy/AmazonRDSFullAccess

# 或者最小权限：
cat > crossplane-rds-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBInstances",
        "rds:CreateDBInstance",
        "rds:ModifyDBInstance",
        "rds:DeleteDBInstance",
        "rds:AddTagsToResource",
        "rds:RemoveTagsFromResource"
      ],
      "Resource": "*"
    }
  ]
}
EOF
aws iam put-role-policy \
  --role-name crossplane-provider-aws \
  --policy-name crossplane-rds \
  --policy-document file://crossplane-rds-policy.json
```

---

## 根因 4：DeletionPolicy 误配导致资源被删

### 现象

```bash
# 用户删除了 MR，期望保留云资源，但资源被删除了！

# 查看 MR 的 DeletionPolicy
kubectl get rdsinstance my-db -o jsonpath='{.spec.deletionPolicy}'
# Delete  ← 默认是 Delete，删除 MR 会删除云资源！

# 云资源已被删除
aws rds describe-db-instances --db-instance-identifier my-db
# An error occurred (DBInstanceNotFound) when calling the DescribeDBInstances operation: 
#   DBInstance not found: my-db
```

### 修复与预防

```bash
# 创建资源时必须设置 DeletionPolicy
apiVersion: database.aws.crossplane.io/v1beta1
kind: RDSInstance
metadata:
  name: my-db
spec:
  deletionPolicy: Orphan    # ← 删除 MR 时保留云资源！
  forProvider:
    dbInstanceClass: db.t3.medium
    engine: mysql

# DeletionPolicy 选项：
# - Delete: 删除 MR 时删除云资源（默认）
# - Orphan: 删除 MR 时保留云资源
# - Foreground: 前台删除（等待云资源删除完成）

# 如果已经误删，从备份恢复
# AWS RDS 自动备份：
aws rds restore-db-instance-to-point-in-time \
  --source-db-instance-identifier my-db \
  --target-db-instance-identifier my-db-recovered \
  --restore-time 2024-01-15T08:00:00Z
```

---

## 预防资源漂移

### 1. 使用 Composition 和 Claims

```yaml
# 使用 XRD + Composition 封装资源，限制可修改字段
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
                  version:
                    type: string
                    enum: ["11", "12", "13", "14", "15"]  # 限制版本
---
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: postgresql-aws
spec:
  compositeTypeRef:
    apiVersion: database.example.org/v1alpha1
    kind: XPostgreSQLInstance
  resources:
  - name: rdsinstance
    base:
      apiVersion: database.aws.crossplane.io/v1beta1
      kind: RDSInstance
      spec:
        forProvider:
          engine: postgres
          # 不允许用户在 Claim 中修改这些字段
          skipFinalSnapshotBeforeDeletion: true
          publiclyAccessible: false
          deletionPolicy: Orphan
        writeConnectionSecretToRef:
          namespace: crossplane-system
    patches:
    - fromFieldPath: "spec.parameters.storageGB"
      toFieldPath: "spec.forProvider.allocatedStorage"
    - fromFieldPath: "spec.parameters.version"
      toFieldPath: "spec.forProvider.engineVersion"
```

### 2. 监控与告警

```yaml
# PrometheusRule 监控 Crossplane 资源漂移
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
      description: "Resource {{ $labels.name }} of kind {{ $labels.kind }} has been out of sync for more than 10 minutes"

  - alert: CrossplaneResourceNotReady
    expr: crossplane_resource_ready{status="False"} == 1
    for: 15m
    labels:
      severity: critical
    annotations:
      summary: "Crossplane resource {{ $labels.name }} is not ready"

  - alert: CrossplaneProviderErrors
    expr: rate(crossplane_provider_reconcile_errors_total[5m]) > 0.1
    for: 5m
    labels:
      severity: warning
    annotations:
      summary: "Crossplane provider has high error rate"
```

### 3. GitOps 管理 Crossplane 资源

```yaml
# 使用 ArgoCD 管理 Crossplane 资源
# 在 Application 中设置同步策略
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
      prune: false        # 不自动删除资源
      selfHeal: true      # 自动修复漂移
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 5
      backoff:
        duration: 5s
        factor: 2
        maxDuration: 3m
```

---

## 一键诊断脚本

```bash
#!/bin/bash
# diagnose-crossplane-drift.sh

echo "=========================================="
echo "  Crossplane 资源漂移诊断"
echo "  时间: $(date)"
echo "=========================================="

echo ""
echo "=== 1. Provider 状态 ==="
kubectl get providers

echo ""
echo "=== 2. ProviderRevision 状态 ==="
kubectl get providerrevisions

echo ""
echo "=== 3. 未同步的资源 ==="
kubectl get managed --all-namespaces -o json | jq -r '
  .items[] | select(.status.conditions[]?.status == "False" and .status.conditions[]?.type == "Synced") |
  "\(.kind)/\(.metadata.name): \(.status.conditions[] | select(.type=="Synced") | .reason) - \(.status.conditions[] | select(.type=="Synced") | .message)"
' 2>/dev/null | head -20

echo ""
echo "=== 4. 未就绪的资源 ==="
kubectl get managed --all-namespaces -o json | jq -r '
  .items[] | select(.status.conditions[]?.status == "False" and .status.conditions[]?.type == "Ready") |
  "\(.kind)/\(.metadata.name): \(.status.conditions[] | select(.type=="Ready") | .reason)"
' 2>/dev/null | head -20

echo ""
echo "=== 5. Provider Pod 日志（最近错误）==="
for pod in $(kubectl get pods -n crossplane-system -l pkg.crossplane.io/provider -o name | head -3); do
  echo "--- $pod ---"
  kubectl logs $pod -n crossplane-system --tail=10 2>/dev/null | grep -E "error|Error|failed|Failed" | tail -5
done

echo ""
echo "=== 6. 最近事件 ==="
kubectl get events --all-namespaces --field-selector reason=UpdateFailed --sort-by='.lastTimestamp' | tail -10

echo ""
echo "=========================================="
echo "  诊断完成"
echo "=========================================="
```
