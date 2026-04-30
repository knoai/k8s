# 07. 安全体系详解

## 认证（Authentication）

### 认证方式

K8s 支持多种认证方式：

| 方式 | 适用场景 | 说明 |
|------|---------|------|
| **X.509 客户端证书** | 管理员、系统组件 | 最常用 |
| **ServiceAccount Token** | Pod 内访问 API | 自动创建和挂载 |
| **静态 Token 文件** | 测试环境 | 不推荐生产 |
| **静态密码文件** | 已废弃 | 不安全 |
| **Webhook Token** | 外部认证 | 集成 LDAP/OIDC |
| **OpenID Connect (OIDC)** | 企业集成 | 集成 SSO |

### X.509 客户端证书认证

```
客户端                        apiserver
   │                            │
   ├── 发送请求 + client.crt ──►│
   │                            │
   │◄── 验证证书（CA 签名）─────│
   │                            │
   │◄── 提取证书中的 Common Name │
   │    作为用户名              │
   │    提取 Organization 作为  │
   │    用户组                  │
```

**证书中的身份信息**：
- `CN`（Common Name）：用户名
- `O`（Organization）：用户组

```bash
# 创建用户证书
openssl req -new -key user.key -out user.csr \
  -subj "/CN=alice/O=developers/O=admins"

# 用 K8s CA 签发
openssl x509 -req -in user.csr -CA /etc/kubernetes/pki/ca.crt \
  -CAkey /etc/kubernetes/pki/ca.key -out user.crt

# 配置 kubeconfig
kubectl config set-credentials alice \
  --client-certificate=user.crt --client-key=user.key
```

### ServiceAccount

```
每个 Namespace 自动创建 default ServiceAccount

Pod 自动挂载 Token：

Pod
├── Container
│   └── /var/run/secrets/kubernetes.io/serviceaccount/
│       ├── token           # JWT Token，用于访问 apiserver
│       ├── ca.crt          # CA 证书，用于验证 apiserver
│       └── namespace       # 当前 Namespace 名称
│
└── ServiceAccount: default
    └── Secret: default-token-xxx
        ├── token
        └── ca.crt
```

**Token 机制演进**：

| 版本 | 机制 | 特点 |
|------|------|------|
| < 1.24 | Secret 自动挂载 | Token 永不过期 |
| ≥ 1.24 | TokenRequest API | Token 有时效性（1h），可绑定 Pod |

```yaml
# 1.24+ 的 ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: my-sa
automountServiceAccountToken: false  # 禁止自动挂载
tokenExpirationSeconds: 3600         # Token 有效期
```

### OIDC 认证

```
用户 ──► K8s Dashboard/kubectl
    │
    ├── 重定向到 IdP（Keycloak/Dex/OKTA）
    │
    ├── 用户在 IdP 登录
    │
    ├── IdP 返回 ID Token（JWT）
    │
    └── kubectl 用 ID Token 访问 apiserver

apiserver 配置：
--oidc-issuer-url=https://idp.example.com
--oidc-client-id=kubernetes
--oidc-username-claim=email
--oidc-groups-claim=groups
```

---

## 鉴权（Authorization）

### RBAC — 基于角色的访问控制

RBAC 是 K8s 的主要鉴权机制。

#### 核心资源

| 资源 | 说明 |
|------|------|
| **Role** | Namespace 级别的权限集合 |
| **ClusterRole** | 集群级别的权限集合 |
| **RoleBinding** | 将 Role 绑定到用户/组/SA（Namespace 级别） |
| **ClusterRoleBinding** | 将 ClusterRole 绑定到用户/组/SA（集群级别） |

#### Role 定义

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-reader
rules:
- apiGroups: [""]  # "" 表示 core API 组
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list"]
```

#### ClusterRole 常用内置角色

| 角色 | 权限 |
|------|------|
| `cluster-admin` | 超级管理员，所有权限 |
| `admin` | Namespace 管理员 |
| `edit` | 可读写 Namespace 内大部分资源 |
| `view` | 只读 Namespace 内大部分资源 |

#### RoleBinding

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: read-pods
  namespace: default
subjects:
- kind: User
  name: alice
  apiGroup: rbac.authorization.k8s.io
- kind: ServiceAccount
  name: my-sa
  namespace: default
roleRef:
  kind: Role
  name: pod-reader
  apiGroup: rbac.authorization.k8s.io
```

#### 权限检查命令

```bash
# 检查用户权限
kubectl auth can-i create pods
kubectl auth can-i delete deployments --namespace production

# 检查其他用户权限
kubectl auth can-i create pods --as alice
kubectl auth can-i create pods --as system:serviceaccount:default:my-sa

# 检查某个角色有什么权限
kubectl describe clusterrole cluster-admin
```

---

## Pod 安全

### PodSecurityAdmission (PSA) — 1.25+

PSA 替代了已废弃的 PodSecurityPolicy，通过 Namespace 标签控制 Pod 安全级别。

#### 三个安全级别

| 级别 | 说明 | 限制 |
|------|------|------|
| **privileged** | 无限制 | 最宽松 |
| **baseline** | 最小限制 | 禁止特权容器、hostPath 等 |
| **restricted** | 严格限制 | 非 root、只读根文件系统等 |

#### 三种模式

| 模式 | 行为 |
|------|------|
| **enforce** | 违反策略时拒绝 Pod 创建 |
| **audit** | 违反策略时记录审计日志 |
| **warn** | 违反策略时向用户返回警告 |

#### 配置示例

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
```

**符合 restricted 的 Pod**：

```yaml
apiVersion: v1
kind: Pod
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

### SecurityContext

```yaml
apiVersion: v1
kind: Pod
spec:
  securityContext:
    runAsUser: 1000          # 以 UID 1000 运行
    runAsGroup: 1000         # 以 GID 1000 运行
    fsGroup: 1000            # 卷挂载后文件所属组
    runAsNonRoot: true       # 禁止以 root 运行
    seccompProfile:
      type: RuntimeDefault   # 使用默认 seccomp 配置
  containers:
  - name: app
    securityContext:
      privileged: false      # 非特权容器
      allowPrivilegeEscalation: false  # 禁止提权
      readOnlyRootFilesystem: true      # 只读根文件系统
      capabilities:
        drop: ["ALL"]        # 丢弃所有 capabilities
        add: ["NET_BIND_SERVICE"]  # 仅添加需要的
```

---

## NetworkPolicy

详见 [05-networking.md](05-networking.md) 的 NetworkPolicy 章节。

---

## Secret 加密

### Encryption at Rest

默认 Secret 以 base64 存储在 etcd 中，需要加密。

```yaml
# /etc/kubernetes/encryption-config.yaml
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
          secret: <base64-encoded-32-byte-key>
    - identity: {}  # 回退：允许读取未加密数据
```

**启用方式**：
```bash
# apiserver 启动参数
--encryption-provider-config=/etc/kubernetes/encryption-config.yaml
```

**加密过程**：
```
1. 首次启用时，新写入的 Secret 自动加密
2. 已存在的未加密 Secret 需要重写（可用 kubectl get + apply）
3. 加密后的数据格式：k8s:enc:aescbc:v1:key1:<加密数据>
```

---

## 准入控制（Admission Control）

### 什么是准入控制

准入控制器在请求**通过认证和鉴权后**，在**写入 etcd 前**对请求进行拦截和处理。

```
请求 → 认证 → 鉴权 → 准入控制 → 写入 etcd
                │
                ├── Mutating：修改请求
                └── Validating：验证请求
```

### 内置准入控制器

| 控制器 | 类型 | 作用 |
|--------|------|------|
| **NamespaceLifecycle** | Validating | 禁止删除 default/kube-system/active 的 Namespace |
| **LimitRanger** | Mutating + Validating | 检查资源限制（LimitRange） |
| **ResourceQuota** | Validating | 检查资源配额 |
| **PodSecurity** | Validating | PodSecurityAdmission |
| **ServiceAccount** | Mutating | 自动为 Pod 添加 ServiceAccount |
| **DefaultStorageClass** | Mutating | 为未指定 StorageClass 的 PVC 添加默认 SC |
| **DefaultTolerationSeconds** | Mutating | 为 Pod 添加默认的容忍时间 |
| **NodeRestriction** | Validating | 限制 kubelet 只能修改自己的节点 |
| **CertificateApproval/Signing** | Validating | 控制证书签名请求 |

### 动态准入控制 — Webhook

```
请求 → 认证 → 鉴权 → Mutating Webhook → Validating Webhook → 写入 etcd
```

**两种 Webhook**：

| 类型 | 作用时机 | 可修改请求？ |
|------|---------|-----------|
| **MutatingAdmissionWebhook** | 验证之前 | 是 |
| **ValidatingAdmissionWebhook** | 验证之后 | 否 |

**Webhook 配置**：

```yaml
apiVersion: admissionregistration.k8s.io/v1
kind: ValidatingWebhookConfiguration
metadata:
  name: my-webhook
webhooks:
- name: validate-pod.example.com
  rules:
  - apiGroups: [""]
    apiVersions: ["v1"]
    operations: ["CREATE", "UPDATE"]
    resources: ["pods"]
  clientConfig:
    service:
      namespace: webhook
      name: my-webhook
      path: /validate
    caBundle: <CA_BUNDLE>
  admissionReviewVersions: ["v1"]
  sideEffects: None
```

**Webhook 服务**：

```
apiserver ──HTTPS──► Service: my-webhook.webhook.svc
                        │
                        ▼
                    Webhook Pod
                    （验证请求，返回 AdmissionResponse）
```

---

## 安全最佳实践

### 1. 最小权限原则

```bash
# 不要给所有人 cluster-admin
# 按角色分配权限

# 开发团队
Role: pod-reader, deployment-editor
Namespace: dev

# 运维团队
ClusterRole: node-reader, event-reader
Namespace: all

# CI/CD
ClusterRole: deployment-editor (限定 Namespace)
```

### 2. Pod 安全

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
```

### 3. 网络隔离

```bash
# 默认拒绝所有流量
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
spec:
  podSelector: {}
  policyTypes:
  - Ingress
  - Egress
EOF
```

### 4. Secret 管理

- 启用 Encryption at Rest
- 使用外部 Secret 管理工具（Vault、Sealed Secrets、External Secrets Operator）
- 定期轮换 Secret
- 设置 ServiceAccount Token 过期时间

### 5. 审计日志

```yaml
# 启用审计
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
- level: RequestResponse
  resources:
  - group: ""
    resources: ["pods", "secrets"]
- level: Metadata
  resources:
  - group: ""
    resources: ["*"]
```
