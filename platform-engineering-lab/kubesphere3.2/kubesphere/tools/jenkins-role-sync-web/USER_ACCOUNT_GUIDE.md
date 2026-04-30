# KubeSphere "用户"与"账户"说明 + Web 工具账户配置指南

## 一、KubeSphere 中 "用户" 和 "账户" 的关系

### 结论：本质上是同一个东西

| 术语 | 技术实体 | 说明 |
|------|---------|------|
| **用户 (User)** | `iam.kubesphere.io/v1alpha2 User` CRD | 底层 K8s 资源，Cluster 级别 |
| **账户 (Account)** | 同一个 `User` CRD | 面向前端的业务术语，泛指可登录系统的实体 |

**代码证据**（`pkg/kapis/iam/v1alpha2/handler.go`）：
```
POST /users 的接口描述为 "Create a global user account"
```

KubeSphere 没有独立的 `Account` CRD，所有身份都统一用 `User` CRD 管理。

### 默认管理员

```yaml
apiVersion: iam.kubesphere.io/v1alpha2
kind: User
metadata:
  name: admin          # ← 用户名
spec:
  email: admin@kubesphere.io
```

- **用户名**：`admin`
- **密码**：首次登录时 `P@88w0rd`，安装后会被要求修改
- **常量定义**：`pkg/constants/constants.go` 中 `AdminUserName = "admin"`
- **特殊逻辑**：`admin` 账户强制走本地认证，不受外部 IDP 影响

---

## 二、Web 工具涉及的三类"账户"

部署 `jenkins-role-sync-web` 工具时，会涉及到 **3 个不同的账户**，不要混淆：

```
┌─────────────────────────────────────────────────────────────────┐
│                    ① 访问 Web 工具的账户                         │
│                                                                 │
│   你用浏览器打开 http://jenkins-sync.kubesphere.local          │
│   谁来保护这个页面的访问权限？                                   │
│                                                                 │
│   选项 A：不设置认证（内部网络使用）                              │
│   选项 B：Ingress + Basic Auth                                  │
│   选项 C：KubeSphere OAuth Proxy（推荐）                        │
│   选项 D：Nginx Ingress + OAuth2                                │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ② 工具读取 K8s 的 ServiceAccount              │
│                                                                 │
│   工具需要调用 K8s API 读取 User CRD                            │
│   这个不是"用户"，是 K8s 的 ServiceAccount                      │
│                                                                 │
│   名称：jenkins-role-sync-web                                   │
│   权限：list/get User CRD（iam.kubesphere.io/v1alpha2）        │
│   配置：k8s-deployment.yaml 中的 ServiceAccount + ClusterRole   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    ③ 工具连接 Jenkins 的账户                     │
│                                                                 │
│   工具需要调用 Jenkins Role Strategy API                        │
│   这个必须是 Jenkins 的管理员账户                                │
│                                                                 │
│   名称：admin（或你配置的 Jenkins 管理员）                       │
│   凭证：密码 或 API Token（推荐用 API Token）                    │
│   配置：JENKINS_USER + JENKINS_PASS 环境变量                     │
└─────────────────────────────────────────────────────────────────┘
```

---

## 三、具体配置说明

### 3.1 ① 访问 Web 工具的认证（Ingress 层面）

**方案 A：不设置认证（仅内部网络）**
```yaml
# Ingress 不添加任何认证注解
# 适合公司内部私有网络，仅限运维人员访问
```

**方案 B：Ingress Basic Auth（简单密码保护）**
```bash
# 创建 htpasswd 文件
htpasswd -c auth admin
kubectl create secret generic jenkins-sync-auth --from-file=auth \
  -n kubesphere-system

# 修改 Ingress
metadata:
  annotations:
    nginx.ingress.kubernetes.io/auth-type: basic
    nginx.ingress.kubernetes.io/auth-secret: jenkins-sync-auth
    nginx.ingress.kubernetes.io/auth-realm: "Authentication Required"
```

**方案 C：KubeSphere OAuth Proxy（推荐，与 KubeSphere 账户打通）**
```yaml
# 部署一个 oauth2-proxy sidecar
# 用户访问工具时，自动跳转到 KubeSphere 登录页
# 登录后携带 JWT Token 访问工具

# 这种方式下，"用哪个用户" = "用 KubeSphere 的任意用户"
# 但需要额外配置 RBAC，限制只有管理员能访问
```

### 3.2 ② K8s ServiceAccount（工具读取用户列表）

这是**完全自动化的**，不需要人工选择账户：

```yaml
# k8s-deployment.yaml 中已配置
apiVersion: v1
kind: ServiceAccount
metadata:
  name: jenkins-role-sync-web
  namespace: kubesphere-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: jenkins-role-sync-web
rules:
  - apiGroups: ["iam.kubesphere.io"]
    resources: ["users"]
    verbs: ["get", "list", "watch"]
```

工具启动后自动使用 `jenkins-role-sync-web` ServiceAccount 的 Token 访问 K8s API。

### 3.3 ③ Jenkins 管理员账户（核心配置）

这是**最关键的配置**，必须正确填写：

#### 获取 Jenkins 管理员密码的 3 种方式

**方式一：KubeSphere 安装时的默认密码**
```bash
# 如果从未修改过 Jenkins admin 密码
# 尝试默认值（不同版本可能不同）
kubectl get secret -n kubesphere-devops-system jenkins-admin-credentials \
  -o jsonpath='{.data.password}' | base64 -d
```

**方式二：从 KubeSphere ConfigMap 中查看**
```bash
kubectl get cm -n kubesphere-system kubesphere-config -o yaml | grep -A 5 "devops:"
# 输出示例：
# devops:
#   host: http://jenkins.kubesphere-devops-system:8080
#   username: admin
#   password: xxxxxxxx
```

**方式三：生成 Jenkins API Token（推荐，最安全）**
```bash
# 1. 找到 Jenkins Pod
kubectl get pod -n kubesphere-devops-system -l app=jenkins

# 2. 端口转发到本地
kubectl port-forward -n kubesphere-devops-system svc/jenkins 8080:8080

# 3. 浏览器打开 http://localhost:8080
#    用 admin + 密码登录

# 4. 点击右上角用户名 → Configure → API Token → Add new Token → Generate
#    复制生成的 Token（如 11abc22def33ghi44jkl55mno66pqr7）

# 5. 将 Token 填入 Web 工具的 Secret
kubectl patch secret -n kubesphere-system jenkins-admin-credentials \
  --type='json' -p='[{"op": "replace", "path": "/data/password", "value":"'$(echo -n 'YOUR_API_TOKEN' | base64)'"}]'
```

#### 为什么推荐用 API Token 而不是密码？

| 对比项 | 密码 | API Token |
|--------|------|-----------|
| 安全性 | 可能与其他系统共享 | 仅用于 API 调用，可单独撤销 |
| 稳定性 | 可能因密码策略强制修改而失效 | 不会自动过期 |
| 权限控制 | 与登录密码相同 | 可独立管理 |
| 审计 | 难以区分是用户登录还是 API 调用 | 可单独追踪 |

---

## 四、用户状态与可修复性

工具扫描出的用户可能处于不同状态，修复前需要了解：

| K8s 状态 | 含义 | 能否运行 Pipeline | 工具是否修复 |
|----------|------|------------------|-------------|
| **Active** | 正常可用 | ✅ 如果 Jenkins 角色已同步 | ✅ 是 |
| **Disabled** | 被管理员禁用 | ❌ 无法登录 KubeSphere | ⚠️ 会尝试，但用户本身已禁用 |
| **AuthLimitExceeded** | 登录失败过多被锁定 | ❌ 暂时无法登录 | ⚠️ 会尝试，但建议先解锁用户 |
| 空/未设置 | 新创建尚未初始化 | ❌ 状态未知 | ⚠️ 会尝试 |

**工具中的状态展示**：
```
用户行中的 "状态" 列显示的是 K8s User CRD 的 state 字段
如果 state 不是 Active，会额外显示 "K8s状态: Disabled" 等提示
```

---

## 五、快速配置检查清单

部署工具前，请确认以下配置：

```bash
# ✅ 1. Jenkins 管理员密码/API Token 是否正确
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -s -o /dev/null -w "%{http_code}" \
  -u "admin:YOUR_PASSWORD" http://localhost:8080/api/json
# 预期输出：200

# ✅ 2. Role Strategy 插件是否启用
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -s -u "admin:YOUR_PASSWORD" \
  http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin
# 预期输出：JSON，包含 sids 数组

# ✅ 3. K8s ServiceAccount 是否有读取 User 权限
kubectl auth can-i list users --as=system:serviceaccount:kubesphere-system:jenkins-role-sync-web
# 预期输出：yes

# ✅ 4. Web 工具 Pod 是否能访问 Jenkins
kubectl exec -it -n kubesphere-system deploy/jenkins-role-sync-web -- \
  curl -s -o /dev/null -w "%{http_code}" http://jenkins.kubesphere-devops-system:8080/api/json
# 预期输出：401（因为没有认证信息，但说明网络可达）
```

---

## 六、总结

| 问题 | 答案 |
|------|------|
| KubeSphere 的"用户"和"账户"有什么区别？ | **没有本质区别**，统一为 `iam.kubesphere.io/v1alpha2 User` CRD |
| 默认管理员是谁？ | `admin`，密码安装时为 `P@88w0rd`，首次登录需修改 |
| Web 工具访问 Jenkins 用哪个账户？ | **Jenkins 的 admin 账户**，推荐用 API Token 代替密码 |
| Web 工具读取 K8s 用户列表用哪个账户？ | **K8s ServiceAccount**（自动配置，无需人工选择） |
| 浏览器访问 Web 工具页面用哪个账户？ | 取决于 Ingress 认证配置，可选：无认证 / Basic Auth / KubeSphere OAuth |

---

> **相关文档**
> - [工具使用说明](./README.md)
> - [新建用户 Pipeline 故障排查](../../docs/new-user-pipeline-failure.md)
