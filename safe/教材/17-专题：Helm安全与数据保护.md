# 第17章 专题：Helm Chart 安全与 K8s 数据保护

> **本章目标**：深入理解 Helm（K8s 包管理器）的安全风险与最佳实践，以及使用 Velero 进行集群备份、灾难恢复和数据加密。
>
> 读完本章后，你应该能够：安全地使用和管理 Helm Chart；审查 Chart 的安全风险；使用 Velero 实施备份策略；设计灾难恢复方案。

---

## 17.1 Helm 安全概述

### 17.1.1 Helm v2 vs v3 安全差异

| 特性 | Helm v2 | Helm v3 |
|------|---------|---------|
| **Tiller** | 有（服务端组件，权限极大） | **无**（纯客户端） |
| **权限模型** | Tiller 通常以 cluster-admin 运行 | 用户自身 RBAC 权限 |
| **Release 存储** | ConfigMap（明文，无加密） | Secret（base64，可 etcd 加密） |
| **Release 位置** | 存储在 Tiller 命名空间 | 存储在发布命名空间 |
| **状态大小** | 无限制（ConfigMap 1MB） | 受 Secret 1MB 限制 |
| **依赖管理** | requirements.yaml | Chart.yaml dependencies |

> ⚠️ **Helm v2 已废弃**。如果还有 Tiller 在运行，这是严重的安全隐患——任何能访问 Tiller 的人都可以以 cluster-admin 权限操作集群。

### 17.1.2 Helm v3 安全架构深度解析

```
Helm v3 架构：

Helm CLI（纯客户端）
    │
    ├─ 读取本地 kubeconfig（使用当前上下文）
    ├─ 读取本地 Chart（目录或 tgz）
    ├─ 渲染模板（Go template + values）
    │
    ▼
API Server（认证 + 授权）
    │
    ├─ 用户需有创建所有模板资源的权限
    ├─ 如果缺少权限，渲染成功但安装失败
    │
    ▼
etcd（存储 Release 信息）
    │
    ├─ Release 以 Secret 形式存储
    ├─ Secret 名称格式：sh.helm.release.v1.<release-name>.v<version>
    ├─ 包含完整渲染后的 manifest
    └─ 受 etcd 加密保护（如果配置了 encryption-provider-config）

安全优势：
- 无中间权限放大（无 Tiller）
- 用户只能在自己的 RBAC 范围内操作
- Release Secret 可加密存储
- 审计日志记录所有 Helm 操作（通过 API Server）
```

### 17.1.3 Release Secret 结构

```bash
# 查看 Helm Release Secret
kubectl get secrets -n <namespace> | grep sh.helm.release

# 解码 Release 内容
kubectl get secret sh.helm.release.v1.myapp.v1 \
  -n default -o jsonpath='{.data.release}' | base64 -d | base64 -d | gunzip

# 输出是 JSON 格式的 Release 对象：
# {
#   "name": "myapp",
#   "info": { "status": "deployed", "description": "Install complete" },
#   "chart": { "metadata": { "name": "myapp", "version": "1.0.0" } },
#   "manifest": "apiVersion: v1\nkind: Service\n...",
#   "config": { "replicaCount": 3, "image": { "tag": "1.2.3" } }
# }
```

---

## 17.2 Helm Chart 安全

### 17.2.1 Chart 来源验证

```bash
# 添加可信仓库（使用 HTTPS）
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx

# 验证仓库索引签名（如果支持）
helm repo update --debug

# 搜索 Chart
helm search repo nginx --versions

# 拉取 Chart 到本地审查（重要！）
helm pull bitnami/nginx --untar
cd nginx
ls -la
# 应审查：
# - Chart.yaml（Chart 元数据、依赖）
# - values.yaml（默认值、可能的敏感信息）
# - templates/（所有 K8s 资源模板）
# - README.md（使用说明）

# 渲染模板（不部署）
helm template test . > rendered.yaml
# 审查生成的 K8s 清单
```

### 17.2.2 Chart 安全审查清单

```bash
#!/bin/bash
# helm-security-audit.sh

CHART_DIR="${1:-.}"

echo "=== Helm Chart 安全审查 ==="
echo "Chart: $CHART_DIR"

# 1. 检查敏感信息泄露
echo "\n[1] 检查敏感信息"
grep -ri -E "password|secret|token|key|credential" "$CHART_DIR/values.yaml" 2>/dev/null || echo "  No sensitive strings found in values.yaml"

# 2. 检查是否使用 latest 标签
echo "\n[2] 检查镜像标签"
grep -ri "image:.*:latest\|imageTag.*latest\|tag.*latest" "$CHART_DIR/templates/" "$CHART_DIR/values.yaml" 2>/dev/null || echo "  No 'latest' tags found"

# 3. 检查 SecurityContext
echo "\n[3] 检查 SecurityContext"
grep -ri -A 5 "securityContext" "$CHART_DIR/templates/" 2>/dev/null || echo "  No securityContext found (WARNING)"

# 4. 检查特权配置
echo "\n[4] 检查特权配置"
grep -ri "privileged:.*true\|hostPID:.*true\|hostNetwork:.*true\|hostIPC:.*true" "$CHART_DIR/templates/" 2>/dev/null || echo "  No privileged configs found"

# 5. 检查 RBAC
echo "\n[5] 检查 RBAC"
grep -ri "ClusterRole\|cluster-admin" "$CHART_DIR/templates/" 2>/dev/null || echo "  No ClusterRole/cluster-admin found"

# 6. 检查 NetworkPolicy
echo "\n[6] 检查 NetworkPolicy"
grep -ri "NetworkPolicy" "$CHART_DIR/templates/" 2>/dev/null || echo "  No NetworkPolicy found (WARNING)"

# 7. 检查 hostPath
echo "\n[7] 检查 hostPath"
grep -ri "hostPath" "$CHART_DIR/templates/" 2>/dev/null || echo "  No hostPath found"

# 8. 检查资源限制
echo "\n[8] 检查资源限制"
grep -ri "resources:" "$CHART_DIR/templates/" 2>/dev/null || echo "  No resource limits found (WARNING)"

echo "\n=== 审查完成 ==="
```

### 17.2.3 Chart 签名验证（Provenance）

```bash
# 生成 GPG 密钥
export KEYNAME=$(gpg --list-secret-keys | grep sec | head -1 | awk '{print $2}')
echo $KEYNAME

# 打包并签名 Chart
helm package --sign ./my-chart \
  --key $KEYNAME \
  --keyring ~/.gnupg/secring.gpg

# 生成两个文件：
# - my-chart-1.0.0.tgz（Chart 包）
# - my-chart-1.0.0.tgz.prov（签名文件）

# 验证签名
helm verify my-chart-1.0.0.tgz \
  --keyring ~/.gnupg/pubring.gpg

# 安装时验证
helm install my-app my-chart-1.0.0.tgz --verify

# 如果验证失败：
# Error: failed to load provenance file: openpgp: signature made by unknown entity
```

### 17.2.4 OCI 仓库（现代 Chart 分发）

```bash
# Helm 3.8+ 原生支持 OCI 仓库
# 将 Chart 推送到容器仓库（如 Harbor、ECR、ACR）

# 登录 OCI 仓库
helm registry login registry.company.io -u username

# 推送 Chart
helm push my-chart-1.0.0.tgz oci://registry.company.io/charts

# 拉取 Chart
helm pull oci://registry.company.io/charts/my-chart --version 1.0.0

# OCI 仓库的优势：
# 1. 复用现有的容器镜像安全机制
# 2. 支持镜像签名（cosign/notation）
# 3. 统一的访问控制和扫描
```

### 17.2.5 使用 helm-secrets 管理敏感值

```bash
# 安装 helm-secrets 插件
helm plugin install https://github.com/jkroepke/helm-secrets --version v4.5.0

# 配置 SOPS（使用 AWS KMS 示例）
cat > .sops.yaml << 'EOF'
creation_rules:
  - path_regex: .*secrets\.yaml$
    kms: arn:aws:kms:us-west-2:123456789012:key/my-key-id
EOF

# 创建加密的 values 文件
cat > values-secrets.yaml << 'EOF'
db:
  password: super-secret-password
  host: postgres.internal
api:
  key: sk-1234567890abcdef
EOF

# 加密
sops -e -i values-secrets.yaml
# 文件现在被加密，只有持有 KMS 权限的人可以解密

# 安装时使用加密值
helm secrets install my-app ./my-chart \
  -f values.yaml \
  -f values-secrets.yaml

# 升级时同样使用
helm secrets upgrade my-app ./my-chart \
  -f values.yaml \
  -f values-secrets.yaml
```

### 17.2.6 安全的 Helm Chart 模板

```yaml
# values.yaml（安全默认值）
image:
  registry: registry.company.io
  repository: myapp
  tag: "1.2.3"           # 固定版本，绝不用 latest
  pullPolicy: IfNotPresent
  pullSecrets: []

securityContext:
  runAsNonRoot: true
  runAsUser: 1000
  fsGroup: 1000
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop:
    - ALL

resources:
  limits:
    cpu: 500m
    memory: 256Mi
  requests:
    cpu: 100m
    memory: 128Mi

# 默认启用 NetworkPolicy
networkPolicy:
  enabled: true
  ingress:
  - from:
    - namespaceSelector:
        matchLabels:
          name: frontend
    ports:
    - protocol: TCP
      port: 8080

# 最小权限 RBAC
rbac:
  create: true
  scope: namespace           # 不使用 ClusterRole

# Pod Disruption Budget
podDisruptionBudget:
  enabled: true
  minAvailable: 1

# 安全扫描（Trivy 侧车）
securityScan:
  enabled: false
```

```yaml
# templates/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "my-chart.fullname" . }}
  labels:
    {{- include "my-chart.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.replicaCount }}
  selector:
    matchLabels:
      {{- include "my-chart.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "my-chart.selectorLabels" . | nindent 8 }}
    spec:
      serviceAccountName: {{ include "my-chart.serviceAccountName" . }}
      securityContext:
        {{- toYaml .Values.securityContext | nindent 8 }}
      containers:
      - name: {{ .Chart.Name }}
        image: "{{ .Values.image.registry }}/{{ .Values.image.repository }}:{{ .Values.image.tag }}"
        imagePullPolicy: {{ .Values.image.pullPolicy }}
        securityContext:
          {{- toYaml .Values.containerSecurityContext | nindent 12 }}
        resources:
          {{- toYaml .Values.resources | nindent 12 }}
        ports:
        - name: http
          containerPort: 8080
          protocol: TCP
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        {{- if .Values.readOnlyRootFilesystem }}
        - name: cache
          mountPath: /cache
        {{- end }}
      volumes:
      - name: tmp
        emptyDir: {}
      {{- if .Values.readOnlyRootFilesystem }}
      - name: cache
        emptyDir: {}
      {{- end }}
```

---

## 17.3 Helm 安全检测工具

### 17.3.1 helm lint

```bash
# 基础语法和最佳实践检查
helm lint ./my-chart

# 严格模式（更多检查）
helm lint --strict ./my-chart

# 使用特定 values 文件检查
helm lint ./my-chart -f values-production.yaml
```

### 17.3.2 chart-testing

```bash
# 安装 chart-testing
helm plugin install https://github.com/helm/chart-testing

# lint 检查
cd my-chart-repo
ct lint --charts ./charts/my-chart

# 安装测试（实际部署到集群测试）
ct install --charts ./charts/my-chart

# 自动检测变更的 Chart
ct list-changed --target-branch main
ct install --target-branch main
```

### 17.3.3 Checkov Helm 扫描

```bash
# 安装 Checkov
pip install checkov

# 扫描 Helm Chart
checkov -d ./my-chart --framework helm

# 输出格式选择
checkov -d ./my-chart --framework helm -o json > checkov-report.json
checkov -d ./my-chart --framework helm -o sarif > checkov-report.sarif

# 常见检查项：
# CKV_K8S_1: 容器不应以 root 运行
# CKV_K8S_8: 应配置 Liveness Probe
# CKV_K8S_9: 应配置 Readiness Probe
# CKV_K8S_20: 应配置 SecurityContext
# CKV_K8S_21: 默认命名空间不应使用
# CKV_K8S_22: 应使用 readOnlyRootFilesystem
# CKV_K8S_25: 应配置资源限制
```

### 17.3.4 Polaris Helm 扫描

```bash
# 安装 Polaris
kubectl apply -f https://github.com/FairwindsOps/polaris/releases/latest/download/dashboard.yaml

# 命令行扫描 Helm Chart
polaris audit --audit-path ./my-chart --format yaml

# 或安装到集群后扫描已部署资源
polaris audit --namespace production --format yaml
```

---

## 17.4 K8s 数据保护与备份

### 17.4.1 备份范围与策略

```
需要备份的 K8s 资源：

┌─────────────────────────────────────────────────────────────┐
│  集群状态（Cluster State）                                     │
│  ├─ etcd 快照（所有 K8s 资源定义）                            │
│  ├─ 控制平面证书（/etc/kubernetes/pki）                       │
│  ├─ kubeadm 配置（集群拓扑、网络配置）                        │
│  └─ 自定义 API Server 配置                                    │
├─────────────────────────────────────────────────────────────┤
│  工作负载配置（Workload Config）                               │
│  ├─ Deployment/StatefulSet/DaemonSet/Job                     │
│  ├─ Service/Ingress/Gateway                                   │
│  ├─ ConfigMap/Secret（注意：Secret 需要加密备份）             │
│  ├─ RBAC（Role/RoleBinding/ClusterRole/ClusterRoleBinding）   │
│  ├─ NetworkPolicy                                             │
│  ├─ PVC/PV/StorageClass                                       │
│  ├─ Helm Release（sh.helm.release.v1.* Secrets）              │
│  └─ 自定义资源（CRD + CR 实例）                               │
├─────────────────────────────────────────────────────────────┤
│  持久化数据（Persistent Data）                                 │
│  ├─ PVC 数据（数据库、文件存储）                              │
│  ├─ 对象存储数据（S3/GCS/Azure Blob）                         │
│  └─ 外部数据库备份                                            │
├─────────────────────────────────────────────────────────────┤
│  安全与策略配置（Security Config）                             │
│  ├─ Pod Security Standards（命名空间标签）                    │
│  ├─ OPA/Kyverno 策略                                          │
│  ├─ Falco 规则                                                │
│  └─ 审计策略配置                                              │
└─────────────────────────────────────────────────────────────┘
```

### 17.4.2 etcd 备份与恢复

```bash
# ========== etcd 快照备份 ==========
# 在控制平面节点上执行
ETCDCTL_API=3 etcdctl snapshot save /backup/etcd-$(date +%Y%m%d-%H%M%S).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# 验证快照
ETCDCTL_API=3 etcdctl --write-out=table snapshot status /backup/etcd-*.db

# 定时备份（crontab）
# 0 2 * * * /usr/local/bin/etcd-backup.sh

# ========== etcd 恢复 ==========
# 警告：恢复 etcd 会回滚所有集群状态到快照时间点！

# 1. 停止 API Server（在所有控制平面节点上）
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/

# 2. 停止 etcd
mv /etc/kubernetes/manifests/etcd.yaml /tmp/

# 3. 清理旧 etcd 数据
rm -rf /var/lib/etcd

# 4. 恢复快照
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-xxx.db \
  --data-dir=/var/lib/etcd \
  --initial-cluster=control-plane-1=https://10.0.0.1:2380 \
  --initial-cluster-token=etcd-cluster-1 \
  --initial-advertise-peer-urls=https://10.0.0.1:2380

# 5. 重启 etcd 和 API Server
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

### 17.4.3 Velero 备份工具深度使用

**Velero 架构**：

```
Velero CLI
    │
    ▼
Velero Server (Deployment in velero namespace)
    │
    ├─ Backup Controller ──▶ 创建备份
    │   ├─ 调用 API Server 获取资源清单
    │   ├─ 序列化为 JSON
    │   └─ 上传到云对象存储 (S3/GCS/Azure Blob)
    │
    ├─ Restore Controller ──▶ 恢复备份
    │   ├─ 从对象存储下载备份
    │   ├─ 调用 API Server 创建资源
    │   └─ 处理依赖关系（Namespace 先于 Pod）
    │
    ├─ Volume Snapshot Provider ──▶ CSI 快照
    │   ├─ 调用 CSI 驱动创建卷快照
    │   └─ 快照存储在云存储中
    │
    └─ File System Backup (Kopia/Restic) ──▶ 文件级备份
        ├─ 在节点上运行 DaemonSet
        ├─ 挂载 PVC 并备份文件内容
        └─ 上传到对象存储
```

**安装 Velero**：

```bash
# 1. 安装 Velero CLI
wget https://github.com/vmware-tanzu/velero/releases/download/v1.12.0/velero-v1.12.0-linux-amd64.tar.gz
tar -xzf velero-v1.12.0-linux-amd64.tar.gz
sudo mv velero-v1.12.0-linux-amd64/velero /usr/local/bin/

# 2. 准备云凭证（AWS 示例）
cat > credentials-velero << 'EOF'
[default]
aws_access_key_id=<ACCESS_KEY>
aws_secret_access_key=<SECRET_KEY>
EOF

# 3. 安装 Velero Server
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.8.0 \
  --bucket my-velero-backups \
  --backup-location-config region=us-west-2 \
  --snapshot-location-config region=us-west-2 \
  --secret-file ./credentials-velero \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --features=EnableCSI

# 4. 验证
kubectl get pods -n velero
velero backup-location get
velero snapshot-location get
```

**备份策略**：

```bash
# 手动备份整个集群
velero backup create full-cluster-backup \
  --include-cluster-resources=true \
  --wait

# 备份特定命名空间
velero backup create production-backup \
  --include-namespaces production \
  --exclude-resources events,pods \
  --wait

# 备份带特定标签的资源
velero backup create critical-apps-backup \
  --selector "app.kubernetes.io/critical=true" \
  --wait

# 查看备份
velero backup get
velero backup describe production-backup
velero backup logs production-backup

# 查看备份内容
velero backup describe production-backup --details

# 定时备份
velero schedule create daily-backup \
  --schedule="0 2 * * *" \
  --include-namespaces production,staging \
  --ttl 720h0m0s    # 保留 30 天

velero schedule create hourly-critical \
  --schedule="0 * * * *" \
  --selector "backup-policy=frequent" \
  --ttl 168h0m0s    # 保留 7 天

# 查看定时任务
velero schedule get
```

**恢复操作**：

```bash
# 查看可用备份
velero backup get

# 完整恢复到新集群
velero restore create disaster-recovery \
  --from-backup full-cluster-backup \
  --wait

# 恢复到新命名空间
velero restore create restore-to-test \
  --from-backup production-backup \
  --namespace-mappings production:production-test \
  --wait

# 恢复特定资源
velero restore create restore-secrets-only \
  --from-backup production-backup \
  --include-resources secrets \
  --wait

# 恢复时排除某些资源
velero restore create restore-no-pods \
  --from-backup production-backup \
  --exclude-resources pods,events \
  --wait
```

**应用一致性备份（Hooks）**：

```yaml
# 在 Pod 模板中添加注解
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
spec:
  template:
    metadata:
      annotations:
        # 备份前执行：创建数据库 dump
        pre.hook.backup.velero.io/container: postgres
        pre.hook.backup.velero.io/command: >
          ["/bin/sh", "-c", "pg_dumpall -U postgres > /var/lib/postgresql/data/pre-backup.sql"]
        
        # 备份后执行：清理 dump 文件
        post.hook.backup.velero.io/container: postgres
        post.hook.backup.velero.io/command: >
          ["/bin/sh", "-c", "rm -f /var/lib/postgresql/data/pre-backup.sql"]
    spec:
      containers:
      - name: postgres
        image: postgres:15
```

### 17.4.4 备份加密

```bash
# Velero 客户端加密（使用 Restic/Kopia）
# 启用文件系统备份时自动加密

velero backup create encrypted-backup \
  --include-namespaces production \
  --default-volumes-to-fs-backup \
  --wait

# 查看 Velero 加密配置
kubectl get secret cloud-credentials -n velero -o yaml

# ========== 存储桶加密 ==========
# AWS S3 加密配置
aws s3api create-bucket \
  --bucket my-velero-backups \
  --region us-west-2 \
  --create-bucket-configuration LocationConstraint=us-west-2

aws s3api put-bucket-encryption \
  --bucket my-velero-backups \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "aws:kms",
        "KMSMasterKeyID": "arn:aws:kms:us-west-2:123456789:key/my-key"
      },
      "BucketKeyEnabled": true
    }]
  }'

# 阻止未加密上传
aws s3api put-bucket-policy \
  --bucket my-velero-backups \
  --policy '{
    "Version": "2012-10-17",
    "Statement": [{
      "Sid": "DenyUnencrypted",
      "Effect": "Deny",
      "Principal": "*",
      "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::my-velero-backups/*",
      "Condition": {
        "StringNotEquals": {
          "s3:x-amz-server-side-encryption": "aws:kms"
        }
      }
    }]
  }'
```

---

## 17.5 etcd 备份 vs Velero 备份对比

| 场景 | etcd 备份 | Velero 备份 | 推荐策略 |
|------|----------|------------|---------|
| 集群完全恢复 | ✅ 完整状态 | ⚠️ 需配合 etcd | etcd 为主 |
| 跨集群迁移 | ❌ 不适用 | ✅ 支持 | Velero |
| 命名空间级恢复 | ❌ 全部恢复 | ✅ 选择性 | Velero |
| 持久卷数据 | ❌ 不包含 | ✅ 可选包含 | Velero |
| 跨云迁移 | ❌ 不适用 | ✅ 支持 | Velero |
| 删除资源恢复 | ❌ 时间点恢复 | ✅ 精确恢复 | Velero |
| 备份速度 | ✅ 快（快照） | ⚠️ 中等 | etcd |
| 恢复粒度 | ❌ 粗粒度 | ✅ 细粒度 | Velero |

**推荐组合策略**：

```
日常备份：
├─ Velero 每日定时备份（应用级，保留 30 天）
├─ Velero 每小时关键应用备份（保留 7 天）
└─ etcd 快照（关键变更前，保留 7 天）

灾难恢复：
├─ 新集群部署
├─ etcd 快照恢复（恢复集群状态）
└─ Velero 恢复（恢复应用配置和数据）

测试环境同步：
└─ Velero 从生产恢复到测试命名空间
```

---

## 17.6 灾难恢复流程

### 17.6.1 灾难恢复 RTO/RPO 目标

| 级别 | RTO（恢复时间目标） | RPO（恢复点目标） | 策略 |
|------|-------------------|------------------|------|
| **青铜** | 24 小时 | 24 小时 | 每日 Velero 备份 |
| **白银** | 4 小时 | 1 小时 | 每小时 Velero + etcd 快照 |
| **黄金** | 1 小时 | 15 分钟 | 实时复制 + 热备集群 |

### 17.6.2 完整灾难恢复流程

```bash
# ========== 场景：整个集群不可用 ==========

# 阶段 1：准备新集群
# 1.1 使用 kubeadm 创建新控制平面
kubeadm init --config=kubeadm-config.yaml

# 1.2 加入工作节点
kubeadm join <control-plane-endpoint> --token <token> --discovery-token-ca-cert-hash <hash>

# 阶段 2：恢复 etcd
# 2.1 停止 API Server 和 etcd
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/
mv /etc/kubernetes/manifests/etcd.yaml /tmp/

# 2.2 恢复 etcd 快照
ETCDCTL_API=3 etcdctl snapshot restore /backup/etcd-latest.db \
  --data-dir=/var/lib/etcd \
  --initial-cluster=cp1=https://10.0.0.1:2380 \
  --initial-cluster-token=etcd-cluster-1 \
  --initial-advertise-peer-urls=https://10.0.0.1:2380

# 2.3 重启
mv /tmp/etcd.yaml /etc/kubernetes/manifests/
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/

# 阶段 3：验证集群状态
kubectl get nodes
kubectl get pods --all-namespaces

# 阶段 4：恢复 Velero
# 4.1 重新安装 Velero Server
velero install --provider aws --plugins ...

# 4.2 恢复应用
velero restore create dr-restore \
  --from-backup latest-production-backup \
  --wait

# 阶段 5：验证恢复
kubectl get all --all-namespaces
# 检查所有应用是否正常运行
```

---

## 17.7 本章实验

### 实验 17.1：审查第三方 Helm Chart（20 分钟）

```bash
# 步骤 1：拉取 Chart
helm pull bitnami/postgresql --untar
cd postgresql

# 步骤 2：安全审查
helm lint .

# 步骤 3：手动检查
grep -ri "privileged" templates/
grep -ri "hostPath" templates/
grep -ri "cluster-admin" templates/
grep -ri "latest" templates/
grep -ri "securityContext" templates/

# 步骤 4：使用 Checkov 扫描
checkov -d . --framework helm

# 步骤 5：渲染并 dry-run
helm template test . > rendered.yaml
kubectl apply --dry-run=client -f rendered.yaml
```

### 实验 17.2：创建安全的 Helm Chart（30 分钟）

```bash
# 步骤 1：创建 Chart
helm create secure-app

# 步骤 2：修改 values.yaml
# - 固定镜像标签
# - 配置 SecurityContext
# - 设置资源限制
# - 启用 NetworkPolicy

# 步骤 3：验证
cd secure-app
helm lint .
checkov -d . --framework helm

# 步骤 4：渲染检查
helm template test . | grep -A 10 securityContext
```

### 实验 17.3：Velero 备份与恢复（30 分钟）

```bash
# 前提：已安装 Velero 并配置存储

# 步骤 1：创建测试资源
kubectl create namespace backup-test
kubectl run nginx --image=nginx -n backup-test
kubectl expose pod nginx --port=80 -n backup-test

# 步骤 2：备份
velero backup create test-backup \
  --include-namespaces backup-test \
  --wait

# 步骤 3：验证备份
velero backup describe test-backup

# 步骤 4：删除资源
kubectl delete namespace backup-test

# 步骤 5：恢复
velero restore create --from-backup test-backup --wait

# 步骤 6：验证
kubectl get all -n backup-test
```

---

## 17.8 本章练习题

### 选择题

1. **Helm v3 相比 v2 最大的安全改进是什么？**
   - A. 支持 OCI 仓库
   - B. 移除 Tiller，使用用户自身权限
   - C. 支持 Chart 签名
   - D. 使用 Secret 存储 Release

2. **Helm Release 在 K8s 中以什么形式存储？**
   - A. ConfigMap
   - B. Secret
   - C. Custom Resource
   - D. etcd 直接存储

3. **Velero 备份和 etcd 快照的主要区别是什么？**
   - A. Velero 更快
   - B. etcd 快照包含所有集群状态，Velero 支持选择性备份
   - C. etcd 快照支持跨云
   - D. Velero 不需要对象存储

4. **为什么应该使用固定镜像标签而非 latest？**
   - A. latest 标签不安全
   - B. 固定标签确保可重复部署
   - C. latest 占用更多磁盘
   - D. 固定标签启动更快

### 简答题

1. 解释 Helm v3 的安全架构。为什么移除 Tiller 是安全上的重大改进？

2. 描述审查第三方 Helm Chart 的完整流程。应该检查哪些安全风险？

3. 对比 etcd 快照和 Velero 备份。在什么场景下应该使用哪种备份方式？

4. 设计一个生产级 K8s 备份策略。包括备份频率、保留期、加密和恢复流程。

### 实践题

1. **Chart 安全审查**（20 分钟）：
   - 拉取一个第三方 Chart（如 bitnami/postgresql）
   - 使用 helm lint、Checkov 和手动检查评估安全性
   - 列出所有发现的安全问题并提出修复建议

2. **安全 Chart 开发**（30 分钟）：
   - 创建一个包含以下安全特性的 Helm Chart：
     - SecurityContext（runAsNonRoot、readOnlyRootFilesystem、drop ALL）
     - 资源限制
     - NetworkPolicy
     - Pod Disruption Budget
   - 使用 Checkov 验证无安全问题

3. **灾难恢复演练**（45 分钟）：
   - 创建一个命名空间并部署应用
   - 使用 Velero 备份
   - 删除命名空间
   - 从备份恢复
   - 验证应用完整性

---

## 17.9 OCI 仓库安全与供应链

### 17.9.1 OCI Registry 作为 Chart 仓库

Helm 3.8+ 支持将 Chart 作为 OCI 制品存储在镜像仓库中：

```bash
# 登录 OCI 仓库
helm registry login registry.example.com \
  --username $USER --password $PASS

# 保存 Chart 为 OCI 格式
helm package ./mychart
helm push mychart-1.0.0.tgz oci://registry.example.com/charts

# 从 OCI 仓库安装
helm install myapp oci://registry.example.com/charts/mychart --version 1.0.0
```

**OCI 仓库的安全优势**：

| 特性 | 传统 Helm Repo (index.yaml) | OCI Registry |
|------|---------------------------|--------------|
| 认证 | HTTP Basic Auth | 标准 OAuth2 / 仓库认证 |
| 传输安全 | 依赖 TLS | 标准 TLS，支持 mTLS |
| 内容寻址 | 无 | 基于 SHA256 的内容地址 |
| 镜像签名 | 不支持 | 支持 Cosign/Notation 签名 |
| 漏洞扫描 | 有限 | 复用镜像扫描工具链 |
| 复用性 | 独立仓库 | 与容器镜像共用仓库 |

### 17.9.2 Chart 供应链安全最佳实践

```
Chart 供应链安全流程：

开发者                                      仓库                                      部署
├─ 开发 Chart                                ├─ 签名验证                                ├─ 策略校验
├─ helm lint                                 ├─ 漏洞扫描                                ├─ Kyverno 验证
├─ helm unittest                             ├─ SBOM 生成                               ├─ 版本锁定
├─ Checkov 扫描                              ├─ 准入控制                                └─ 监控告警
├─ helm package                              └─ 存储到 OCI
└─ helm sign (Cosign/Provenance)
```

**实施步骤**：

1. **Chart 开发阶段**：
```bash
# 1. 代码审查
helm lint ./mychart
helm template mychart ./mychart | kubectl apply --dry-run=client -f -

# 2. 单元测试
helm unittest ./mychart

# 3. 安全扫描
# Checkov
helm template mychart ./mychart > rendered.yaml
checkov -f rendered.yaml --framework kubernetes

# Kubesec
kubesec scan rendered.yaml
```

2. **签名与发布**：
```bash
# Cosign 签名（推荐）
cosign generate-key-pair
cosign sign --key cosign.key \
  registry.example.com/charts/mychart:1.0.0

# 验证签名
cosign verify --key cosign.pub \
  registry.example.com/charts/mychart:1.0.0

# 使用 Helm provenance（传统方式）
helm package --sign ./mychart \
  --key mykey --keyring ~/.gnupg/secring.gpg
helm verify mychart-1.0.0.tgz
```

3. **部署时验证**：
```yaml
# Kyverno 策略：要求 Chart 有签名
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-chart-signature
spec:
  validationFailureAction: Enforce
  rules:
  - name: check-chart-source
    match:
      resources:
        kinds:
        - Pod
    validate:
      message: "只允许使用签名验证过的镜像和 Chart"
      pattern:
        metadata:
          annotations:
            "helm.sh/chart": "?*"
```

### 17.9.3 私有 Chart 仓库安全架构

```
┌─────────────────────────────────────────────────────────────┐
│                      私有 Chart 仓库架构                       │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │ Harbor      │    │ ChartMuseum │    │ Nexus       │     │
│  │ (推荐)      │    │ (轻量)      │    │ (通用)      │     │
│  └──────┬──────┘    └──────┬──────┘    └──────┬──────┘     │
│         │                  │                  │             │
│         └──────────────────┼──────────────────┘             │
│                            ▼                                │
│              ┌─────────────────────────┐                    │
│              │   TLS + 认证 + 授权      │                    │
│              │   ├─ mTLS 客户端证书     │                    │
│              │   ├─ OIDC / LDAP 集成    │                    │
│              │   ├─ RBAC 权限控制       │                    │
│              │   └─ 审计日志            │                    │
│              └───────────┬─────────────┘                    │
│                          ▼                                  │
│              ┌─────────────────────────┐                    │
│              │   安全扫描层             │                    │
│              │   ├─ Trivy 漏洞扫描      │                    │
│              │   ├─ 恶意软件检测        │                    │
│              │   └─ 签名验证            │                    │
│              └─────────────────────────┘                    │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

**Harbor 安全配置要点**：
- 启用 HTTPS（TLS 1.2+）
- 配置 LDAP/OIDC 认证
- 启用 Trivy 自动扫描
- 配置 Cosign 签名验证
- 启用审计日志和不可变制品

---

## 17.10 Velero 高级主题

### 17.10.1 备份加密详解

Velero 支持两种加密方式：

**方式一：存储桶服务端加密（SSE）**
```bash
# AWS S3 SSE-S3
velero install \
  --provider aws \
  --bucket my-backups \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true \
  --snapshot-location-config region=us-east-1
# SSE-S3 自动启用

# AWS S3 SSE-KMS（推荐）
velero install \
  --provider aws \
  --bucket my-backups \
  --backup-location-config region=us-east-1,s3ForcePathStyle=true,serverSideEncryption=AES256
```

**方式二：Velero 客户端加密（restic/kopia）**
```bash
# 启用文件系统备份加密
velero install \
  --use-node-agent \
  --default-volumes-to-fs-backup \
  --secret-file ./credentials-velero

# 设置加密密钥（通过 Secret）
kubectl create secret generic -n velero \
  cloud-credentials \
  --from-file aws=./credentials-velero \
  --from-literal encryptionKey=$BACKUP_ENCRYPTION_KEY
```

### 17.10.2 灾难恢复 RTO/RPO 设计

| 级别 | RTO（恢复时间） | RPO（数据丢失） | 策略 |
|------|--------------|----------------|------|
| 青铜 | < 4 小时 | < 24 小时 | 每日 Velero 备份 |
| 白银 | < 1 小时 | < 1 小时 | 每小时 Velero + PV 快照 |
| 黄金 | < 15 分钟 | < 5 分钟 | 持续复制（Velero + 存储复制） |
| 白金 | < 5 分钟 | ≈ 0 | 多活架构 + 实时同步 |

### 17.10.3 灾难恢复自动化脚本

```bash
#!/bin/bash
# disaster-recovery.sh

NAMESPACE="production"
BACKUP_NAME="daily-$(date +%Y%m%d)"
ALERT_WEBHOOK="https://hooks.slack.com/services/xxx"

# 1. 执行备份
echo "创建备份: $BACKUP_NAME"
velero backup create $BACKUP_NAME \
  --include-namespaces $NAMESPACE \
  --wait

# 2. 验证备份完整性
BACKUP_STATUS=$(velero backup get $BACKUP_NAME -o json | jq -r '.status.phase')
if [ "$BACKUP_STATUS" != "Completed" ]; then
  echo "备份失败!"
  curl -X POST -H 'Content-type: application/json' \
    --data '{"text":"备份失败: '$BACKUP_NAME'"}' $ALERT_WEBHOOK
  exit 1
fi

# 3. 验证备份可恢复性（每 7 天）
if [ $(date +%u) -eq 7 ]; then
  echo "执行恢复验证..."
  RESTORE_NAME="verify-$BACKUP_NAME"
  velero restore create $RESTORE_NAME \
    --from-backup $BACKUP_NAME \
    --include-namespaces $NAMESPACE \
    --namespace-mappings $NAMESPACE:$NAMESPACE-verify
  
  # 等待并验证
  sleep 60
  VERIFY_STATUS=$(velero restore get $RESTORE_NAME -o json | jq -r '.status.phase')
  if [ "$VERIFY_STATUS" == "Completed" ]; then
    echo "恢复验证成功"
    kubectl delete namespace $NAMESPACE-verify
  else
    curl -X POST -H 'Content-type: application/json' \
      --data '{"text":"恢复验证失败!"}' $ALERT_WEBHOOK
  fi
fi

# 4. 清理旧备份（保留 30 天）
echo "清理 30 天前的备份..."
velero backup get | awk -v date=$(date -d '30 days ago' +%Y-%m-%d) \
  '$2 < date {print $1}' | xargs -r velero backup delete --confirm

echo "备份流程完成"
```

---

## 17.12 Helm 与 Velero 常见问题

### 17.12.1 Helm 问题排查

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| `release: already exists` | 同名 Release 已存在 | `helm ls -a` 检查，或 `--replace` |
| `chart not found` | 仓库未添加或版本不存在 | `helm repo update` 后重试 |
| 渲染模板错误 | values.yaml 类型不匹配 | `helm template` 调试，检查类型 |
| Hook 执行失败 | Job 超时或权限不足 | 检查 hook 的 RBAC 和资源限制 |
| Release Secret 过大 | 生成的 manifest > 1MB | 拆分 Chart 或使用 `--no-hooks` |

### 17.12.2 Velero 问题排查

| 问题 | 原因 | 解决方案 |
|------|------|----------|
| 备份 PartiallyFailed | PV 快照失败 | 检查 VolumeSnapshotClass 配置 |
| 恢复后 Service IP 变化 | ClusterIP 是动态分配的 | 备份前记录 Service ClusterIP |
| 跨集群恢复失败 | API 版本不兼容 | 使用相同 K8s 版本或使用 `--include-resources` |
| 备份文件损坏 | 存储传输错误 | 启用备份校验和 `--verify` |
| 调度备份未执行 | Cron 表达式错误或时区问题 | 检查时区设置和 CronJob 状态 |

---

## 17.13 数据保护法规与合规

### 17.13.1 主要数据保护法规要求

| 法规 | 适用场景 | K8s 相关要求 |
|------|----------|-------------|
| **GDPR** | 欧盟用户数据 | 数据加密、访问控制、删除权 |
| **等保 2.0** | 中国关键信息基础设施 | 三级要求加密存储、审计日志 |
| **SOC 2** | 美国 SaaS 企业 | 访问控制、变更管理、监控 |
| **PCI DSS** | 支付卡数据 | 网络隔离、加密传输、漏洞扫描 |
| **HIPAA** | 美国医疗数据 | 访问审计、数据加密、最小权限 |

### 17.13.2 K8s 数据保护实施清单

```
数据分类 → 加密策略 → 访问控制 → 审计追踪 → 备份恢复
    │         │          │          │          │
    ▼         ▼          ▼          ▼          ▼
┌───────┐ ┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│公共   │ │传输:   │ │RBAC    │ │审计日志│ │每日    │
│内部   │ │TLS 1.3 │ │最小权限│ │API 日志│ │自动备份│
│敏感   │ │静态:   │ │SA 隔离 │ │数据访问│ │异地    │
│机密   │ │AES-256 │ │网络隔离│ │操作记录│ │保留30天│
└───────┘ └────────┘ └────────┘ └────────┘ └────────┘
```

### 17.13.3 Secret 生命周期管理

```bash
#!/bin/bash
# secret-lifecycle-manager.sh

NAMESPACE="production"
MAX_AGE_DAYS=90

# 1. 列出所有 Secret 及其年龄
echo "=== Secret 生命周期检查 ==="
kubectl get secrets -n "$NAMESPACE" -o json | \
  jq -r '.items[] | select(.type=="Opaque") |
    "\(.metadata.name) \(.metadata.creationTimestamp)"' | \
  while read name created; do
    age_days=$(( ($(date +%s) - $(date -d "$created" +%s)) / 86400 ))
    if [ "$age_days" -gt "$MAX_AGE_DAYS" ]; then
      echo "[WARN] Secret $name 已过期 ($age_days 天)，建议轮换"
    else
      echo "[OK] Secret $name ($age_days 天)"
    fi
  done

# 2. 自动轮换数据库凭证
echo "=== 数据库凭证轮换 ==="
# 生成新密码
NEW_PASSWORD=$(openssl rand -base64 32)
# 更新 Secret
kubectl create secret generic db-credentials \
  --from-literal=password="$NEW_PASSWORD" \
  -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
# 触发 Deployment 滚动更新
kubectl rollout restart deployment/app -n "$NAMESPACE"

echo "Secret 轮换完成"
```

---

## 17.11 本章小结

| 主题 | 关键要点 |
|------|---------|
| **Helm v3 安全** | 无 Tiller、用户自身 RBAC、Release 以 Secret 存储 |
| **Chart 审查** | lint、Checkov、手动审查 templates/values |
| **Chart 签名** | GPG provenance 验证来源 |
| **敏感值管理** | helm-secrets + SOPS + KMS |
| **OCI 仓库** | 现代 Chart 分发方式，复用镜像安全机制 |
| **备份策略** | Velero（应用级）+ etcd 快照（集群级） |
| **备份加密** | 存储桶 SSE-KMS + Velero 客户端加密 |
| **灾难恢复** | RTO/RPO 目标、分级恢复策略 |

**核心原则**：
1. **不信任任何 Chart**：即使是官方 Chart，也要审查 templates/
2. **固定版本**：绝不使用 latest 标签
3. **最小权限**：Chart 中的 RBAC 应该是最小化的
4. **备份必验证**：定期测试恢复流程，确保备份可用
5. **加密存储**：备份数据必须加密，无论是在传输还是静态存储中

**推荐阅读**：
- Helm 安全最佳实践：https://helm.sh/docs/topics/security/
- Velero 文档：https://velero.io/docs/
- Checkov Helm 扫描：https://www.checkov.io/7.Scan/scanning-helm-charts.html
