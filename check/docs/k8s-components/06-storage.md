# 06. 存储体系详解

## K8s 存储模型

### 核心概念

```
┌─────────────────────────────────────────────────────┐
│                    存储体系架构                        │
│                                                     │
│  ┌─────────┐     ┌─────────┐     ┌─────────────┐   │
│  │  Pod    │────►│  PVC    │────►│     PV      │   │
│  │         │     │ (声明)   │     │  (实际卷)    │   │
│  └─────────┘     └────┬────┘     └──────┬──────┘   │
│                       │                 │           │
│                       │    ┌────────────┘           │
│                       │    │                        │
│                       ▼    ▼                        │
│                  ┌─────────────────┐                │
│                  │  StorageClass   │                │
│                  │  (动态供给模板)  │                │
│                  └─────────────────┘                │
│                                                     │
└─────────────────────────────────────────────────────┘
```

| 概念 | 说明 | 谁创建 |
|------|------|--------|
| **Volume** | Pod 内的临时/半持久存储 | 用户（Pod spec） |
| **PersistentVolume (PV)** | 集群中的实际存储卷 | 管理员 / 动态供给 |
| **PersistentVolumeClaim (PVC)** | 用户对存储的请求 | 用户 |
| **StorageClass** | 存储类型模板，用于动态供给 | 管理员 |
| **CSI** | 容器存储接口，标准化存储插件 | - |

---

## Volume 类型

### 临时存储

| 类型 | 生命周期 | 用例 |
|------|---------|------|
| `emptyDir` | Pod | 容器间共享临时数据 |
| `configMap` | Pod | 注入配置文件 |
| `secret` | Pod | 注入敏感数据 |
| `downwardAPI` | Pod | 注入 Pod/节点元数据 |
| `hostPath` | Pod | 访问节点文件系统（不推荐生产） |

### 持久存储

| 类型 | 后端 | 特点 |
|------|------|------|
| `nfs` | NFS 服务器 | 简单，适合测试 |
| `cephfs` | Ceph 集群 | 高可用，高性能 |
| `rbd` | Ceph RBD | 块存储，支持 RWO |
| `iscsi` | iSCSI 阵列 | 传统企业存储 |
| `csi` | 任意 CSI 驱动 | 标准化，云厂商首选 |

---

## emptyDir

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: writer
    image: busybox
    command: ["sh", "-c", "echo hello > /data/file; sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  - name: reader
    image: busybox
    command: ["sh", "-c", "cat /data/file; sleep 3600"]
    volumeMounts:
    - name: shared-data
      mountPath: /data
  volumes:
  - name: shared-data
    emptyDir: {}
```

**特点**：
- Pod 创建时创建，Pod 删除时删除
- 容器重启后数据保留
- 默认存储在节点磁盘上（可配置 `medium: Memory` 使用 tmpfs）

```
Pod
├── Container A ──► /data ──┐
│                           │── emptyDir (节点磁盘或内存)
└── Container B ──► /data ──┘
```

---

## ConfigMap 与 Secret

### ConfigMap

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  database.conf: |
    host=db.example.com
    port=3306
  LOG_LEVEL: "debug"
```

**使用方式**：

```yaml
# 方式 1：作为环境变量
spec:
  containers:
  - name: app
    env:
    - name: LOG_LEVEL
      valueFrom:
        configMapKeyRef:
          name: app-config
          key: LOG_LEVEL

# 方式 2：作为文件挂载
spec:
  containers:
  - name: app
    volumeMounts:
    - name: config-vol
      mountPath: /etc/config
  volumes:
  - name: config-vol
    configMap:
      name: app-config
      # /etc/config/database.conf
      # /etc/config/LOG_LEVEL
```

### Secret

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:
  username: admin
  password: secret123
data:
  # base64 编码
  token: ZXhhbXBsZS10b2tlbg==
```

**使用方式**：

```yaml
spec:
  containers:
  - name: app
    env:
    - name: DB_PASSWORD
      valueFrom:
        secretKeyRef:
          name: db-credentials
          key: password
    volumeMounts:
    - name: secret-vol
      mountPath: /etc/secrets
      readOnly: true
  volumes:
  - name: secret-vol
    secret:
      secretName: db-credentials
```

**Secret 加密**：
- 默认 Secret 数据以 base64 存储在 etcd 中（**未加密**）
- 生产环境应启用 **Encryption at Rest**

```yaml
# EncryptionConfiguration
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
    - secrets
    providers:
    - aescbc:
        keys:
        - name: key1
          secret: <base64-encoded-32-byte-key>
    - identity: {}  # 回退到不加密
```

---

## PV / PVC / StorageClass

### 静态供给

```
管理员预先创建 PV：

┌─────────────────────────────┐
│  PV: pv-1                   │
│  capacity: 10Gi             │
│  accessModes: [ReadWriteOnce]│
│  nfs:                       │
│    server: 192.168.1.100    │
│    path: /exports/pv1       │
└─────────────────────────────┘
         │
         ▼
用户创建 PVC，匹配 PV：

┌─────────────────────────────┐
│  PVC: my-claim              │
│  resources:                 │
│    requests:                │
│      storage: 10Gi          │
│  accessModes: [ReadWriteOnce]│
└─────────────────────────────┘
         │
         ▼
PVC 与 PV 绑定（1:1）
```

### 动态供给

```
管理员创建 StorageClass：

┌─────────────────────────────────┐
│  StorageClass: fast-ssd         │
│  provisioner: csi-driver        │
│  parameters:                    │
│    type: ssd                    │
│    zone: us-east-1a             │
│  reclaimPolicy: Delete          │
│  volumeBindingMode: WaitForFirstConsumer │
└─────────────────────────────────┘
         │
         ▼
用户创建 PVC（不指定 PV）：

┌─────────────────────────────┐
│  PVC: my-dynamic-claim      │
│  storageClassName: fast-ssd │
│  resources:                 │
│    requests:                │
│      storage: 50Gi          │
└─────────────────────────────┘
         │
         ▼
Provisioner 自动创建 PV：

┌─────────────────────────────┐
│  PV: pvc-xxx                │
│  capacity: 50Gi             │
│  source:                    │
│    csi:                     │
│      volumeHandle: vol-123  │
└─────────────────────────────┘
```

### 访问模式

| 模式 | 缩写 | 说明 |
|------|------|------|
| ReadWriteOnce | RWO | 单个节点读写 |
| ReadOnlyMany | ROX | 多个节点只读 |
| ReadWriteMany | RWX | 多个节点读写 |
| ReadWriteOncePod | RWOP | 单个 Pod 读写（1.22+） |

### 回收策略

| 策略 | PVC 删除后 |
|------|-----------|
| `Retain` | PV 保留，需手动清理数据 |
| `Delete` | PV 和底层存储一起删除（默认动态供给） |
| `Recycle` | 已废弃，清空数据后重新可用 |

### 绑定模式

| 模式 | 说明 |
|------|------|
| `Immediate` | PVC 创建后立即绑定 PV（不考虑调度） |
| `WaitForFirstConsumer` | 等 Pod 调度后再绑定（拓扑感知） |

**WaitForFirstConsumer 的重要性**：
```
场景：多可用区集群

Immediate 模式：
  PVC 在 Zone A 创建 PV
  Pod 被调度到 Zone B
  → Pod 无法挂载（PV 在 Zone A，Pod 在 Zone B）

WaitForFirstConsumer 模式：
  Pod 被调度到 Zone B
  PVC 根据 Pod 所在 Zone 创建 PV
  → 成功挂载
```

---

## CSI — 容器存储接口

### 架构

```
┌─────────────────────────────────────────────────────┐
│                   K8s 集群                           │
│                                                     │
│  ┌─────────────┐        ┌──────────────────────┐   │
│  │   kubelet   │◄──────►│  CSI Node Plugin     │   │
│  │             │  gRPC  │  (DaemonSet)         │   │
│  └─────────────┘        └──────────────────────┘   │
│         │                                           │
│         │                                           │
│  ┌──────┴──────┐        ┌──────────────────────┐   │
│  │  External   │◄──────►│  CSI Controller      │   │
│  │  Provisioner│  gRPC  │  Plugin (Deployment) │   │
│  │  (Sidecar)  │        │                      │   │
│  └─────────────┘        └──────────────────────┘   │
│         │                      │                    │
│         │                      │                    │
│  ┌──────┴──────┐        ┌─────┴─────┐             │
│  │  External   │        │  External │             │
│  │  Attacher   │        │  Snapshotter          │   │
│  └─────────────┘        └───────────┘             │
│                                                     │
└─────────────────────────────────────────────────────┘
         │                      │
         ▼                      ▼
┌─────────────────────────────────────────────────────┐
│              存储后端（云盘/阵列/NFS）                │
└─────────────────────────────────────────────────────┘
```

### CSI 接口

| 接口 | 说明 | 由谁实现 |
|------|------|---------|
| `CreateVolume` | 创建卷 | Controller Plugin |
| `DeleteVolume` | 删除卷 | Controller Plugin |
| `ControllerPublishVolume` | 将卷附加到节点 | Controller Plugin |
| `ControllerUnpublishVolume` | 从节点分离卷 | Controller Plugin |
| `NodeStageVolume` | 在节点上准备卷（格式化、挂载到全局路径） | Node Plugin |
| `NodePublishVolume` | 将卷挂载到 Pod 目录 | Node Plugin |
| `NodeUnpublishVolume` | 从 Pod 目录卸载 | Node Plugin |
| `NodeUnstageVolume` | 从节点全局路径卸载 | Node Plugin |

### 卷挂载流程

```
1. 用户创建 PVC
   └── apiserver 写入 etcd

2. External Provisioner 监听到 PVC
   └── 调用 CSI Controller CreateVolume
   └── 后端存储创建卷
   └── 创建 PV 并绑定 PVC

3. 用户创建 Pod，引用 PVC
   └── Scheduler 选择节点
   └── kubelet 开始创建 Pod

4. kubelet 调用 CSI Node Plugin
   └── NodeStageVolume：格式化并挂载到 /var/lib/kubelet/plugins/.../globalmount
   └── NodePublishVolume：bind mount 到 Pod 目录 /var/lib/kubelet/pods/.../volumes/.../mount

5. Pod 启动，可以访问卷

6. Pod 删除时
   └── NodeUnpublishVolume：卸载 Pod 目录
   └── NodeUnstageVolume：卸载全局路径

7. PVC 删除时（reclaimPolicy=Delete）
   └── External Provisioner 调用 DeleteVolume
   └── 后端存储删除卷
   └── PV 被删除
```

### 常见 CSI 驱动

| 驱动 | 后端 | 云厂商 |
|------|------|--------|
| `ebs.csi.aws.com` | AWS EBS | AWS |
| `pd.csi.storage.gke.io` | GCE PD | GCP |
| `disk.csi.azure.com` | Azure Disk | Azure |
| `csi-alibabacloud.com` | 阿里云盘 | 阿里云 |
| `csi.tencentcloud.com` | 腾讯云盘 | 腾讯云 |
| `csi.huaweicloud.com` | 华为云盘 | 华为云 |
| `rbd.csi.ceph.com` | Ceph RBD | 自建 |
| `cephfs.csi.ceph.com` | CephFS | 自建 |
| `nfs.csi.k8s.io` | NFS | 通用 |

---

## 存储快照与克隆

### VolumeSnapshot

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: my-snapshot
spec:
  volumeSnapshotClassName: csi-snapclass
  source:
    persistentVolumeClaimName: my-pvc
```

**用途**：
- 备份数据
- 创建卷克隆
- 恢复到某个时间点

### 从快照恢复

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: restored-pvc
spec:
  storageClassName: fast-ssd
  dataSource:
    name: my-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes:
  - ReadWriteOnce
  resources:
    requests:
      storage: 50Gi
```

---

## 存储扩容

### 在线扩容（Online Expansion）

```bash
# 1. 编辑 PVC，增大 storage
kubectl patch pvc my-pvc -p '{"spec":{"resources":{"requests":{"storage":"100Gi"}}}}'

# 2. 查看文件系统是否自动扩容
kubectl get pvc my-pvc
# STATUS: FileSystemResizePending

# 3. 重启 Pod 触发文件系统扩容（如 CSI 不支持在线扩容）
kubectl delete pod my-pod
```

**要求**：
- StorageClass 启用 `allowVolumeExpansion: true`
- CSI 驱动支持扩容
- 文件系统支持在线扩容（ext4、xfs）

---

## 存储排查命令

```bash
# 查看 PV
kubectl get pv
kubectl describe pv <pv-name>

# 查看 PVC
kubectl get pvc -A
kubectl describe pvc <pvc-name>

# 查看 StorageClass
kubectl get sc

# 查看 Pod 挂载的卷
kubectl get pod <pod> -o jsonpath='{.spec.volumes}'
kubectl get pod <pod> -o jsonpath='{.status.volumes}'

# 查看节点上的挂载
kubectl get node <node> -o jsonpath='{.status.volumesAttached}'
kubectl get node <node> -o jsonpath='{.status.volumesInUse}'

# 查看 CSI 插件日志
kubectl logs -n kube-system -l app=csi-controller
kubectl logs -n kube-system -l app=csi-node

# 在节点上查看挂载
findmnt | grep kubelet

# 查看卷详情（AWS）
aws ec2 describe-volumes --volume-ids vol-xxx
```
