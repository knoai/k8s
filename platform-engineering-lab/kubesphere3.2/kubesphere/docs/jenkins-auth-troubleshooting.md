# KubeSphere + Jenkins 用户授权失效排查与修复指南

> **适用版本**：KubeSphere v3.1.x / v3.2  
> **问题场景**：用户在 KubeSphere 中操作 DevOps Pipeline 时提示权限不足、认证失败、无法查看/运行 Pipeline

---

## 目录

1. [授权失效的典型表现](#一授权失效的典型表现)
2. [失效根因分析](#二失效根因分析)
3. [排查步骤](#三排查步骤)
4. [修复方案](#四修复方案)
5. [预防措施](#五预防措施)
6. [原理补充：为什么 Token 不会自动刷新](#六原理补充为什么-token-不会自动刷新)

---

## 一、授权失效的典型表现

| 现象 | 可能的根因 |
|------|-----------|
| 前端提示 "Unauthorized" / "401 Unauthorized" | KubeSphere JWT Token 过期、Jenkins 管理员凭证失效 |
| 前端提示 "Forbidden" / "403 Forbidden" | Jenkins 中用户角色被移除、Role Strategy 配置变更 |
| Pipeline 列表为空或加载失败 | Jenkins 服务不可达、管理员 Basic Auth 失效 |
| 能查看 Pipeline 但无法运行 | Jenkins Project Role 权限不足、Token 透传失败 |
| 日志出现 "please check if Jenkins is running well" | Jenkins 服务异常、管理员账号认证失败 |
| 日志出现 "please check if there're any Jenkins plugins issues exist" | Jenkins 插件异常（如 Blue Ocean、Role Strategy） |

---

## 二、失效根因分析

### 2.1 根因分类图

```
授权失效
├── 用户层问题
│   ├── KubeSphere JWT Token 过期
│   ├── KubeSphere 用户被禁用/锁定
│   └── 用户从 KubeSphere 中被删除
│
├── KubeSphere → Jenkins 管理员通道问题
│   ├── Jenkins 管理员密码被修改
│   ├── KubeSphere 配置中的 Jenkins 凭证错误
│   └── Jenkins 服务地址不可达
│
├── Jenkins 用户层问题
│   ├── 用户在 Jenkins 中被手动删除
│   ├── 用户的 Global Role (admin) 被手动撤销
│   ├── Role Strategy 插件配置被覆盖/重置
│   └── Jenkins 安全 realm 变更（LDAP/OAuth 配置变化）
│
└── Jenkins 插件/服务问题
    ├── Role Strategy 插件未启用或异常
    ├── Blue Ocean 插件异常
    ├── Jenkins 重启后配置丢失
    └── Jenkins 容器/Pod 重建后数据未持久化
```

### 2.2 代码层面的关键发现

根据源码分析，`kubesphere/kubesphere` 后端存在以下**设计特点**和**限制**：

| 发现 | 影响 |
|------|------|
| **Token 不做过期检测** | `SetBasicBearTokenHeader` 使用 `jwt.ParseUnverified` 仅提取用户名，**不验证 Token 签名和过期时间** |
| **无自动刷新机制** | 代码中没有任何 Re-auth 或 Token Refresh 逻辑 |
| **固定管理员账号** | KubeSphere → Jenkins 的管理操作使用配置文件中的固定 Basic Auth |
| **统一授予 admin 角色** | 所有 KubeSphere 用户在 Jenkins 中被同步为全局 `admin` 角色 |
| **项目角色接口预留但未使用** | `AssignProjectRole` / `DeleteUserInProject` 等方法已实现，但无业务调用方 |

---

## 三、排查步骤

### Step 1：确认 KubeSphere 用户状态

```bash
# 查看用户状态
kubectl get users <username> -o yaml

# 检查关键字段
# - spec.email
# - status.state (Active / Disabled / AuthLimitExceeded)
# - metadata.deletionTimestamp (是否正在被删除)
```

**正常状态**：
```yaml
status:
  state: Active
```

**异常状态**：
- `Disabled`：用户被管理员禁用
- `AuthLimitExceeded`：登录失败次数过多被锁定
- `deletionTimestamp` 非空：用户正在被删除

**修复**：
```bash
# 解锁用户（如有管理员权限）
kubectl patch user <username> --type='merge' -p '{"status":{"state":"Active"}}'
```

---

### Step 2：检查 KubeSphere JWT Token

```bash
# 获取当前登录 Token（从前端浏览器开发者工具或 API 调用中获取）
# 解析 Token 内容（仅查看 Payload，不验证签名）
echo "<JWT_TOKEN>" | awk -F'.' '{print $2}' | base64 -d 2>/dev/null | python3 -m json.tool

# 检查字段
# - username: 是否正确
# - exp: 是否已过期（Unix 时间戳）
# - iat: 签发时间
```

**判断 Token 是否过期**：
```bash
# 获取 Token 中的 exp 值
EXP=$(echo "<JWT_TOKEN>" | awk -F'.' '{print $2}' | base64 -d 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['exp'])")
NOW=$(date +%s)

if [ "$NOW" -gt "$EXP" ]; then
  echo "Token 已过期"
else
  echo "Token 有效，剩余 $((EXP - NOW)) 秒"
fi
```

**修复**：重新登录 KubeSphere 获取新 Token。

---

### Step 3：验证 Jenkins 管理员凭证

KubeSphere 使用配置中的 Jenkins 管理员账号执行管理操作。如果此凭证失效，所有 DevOps 功能都会异常。

```bash
# 查看 KubeSphere 配置中的 Jenkins 配置
kubectl get cm -n kubesphere-system kubesphere-config -o yaml | grep -A 5 "devops:"

# 或直接查看 ks-apiserver 启动参数
kubectl get deploy -n kubesphere-system ks-apiserver -o yaml | grep jenkins
```

**预期输出**：
```yaml
devops:
  host: http://jenkins.kubesphere-devops-system:8080
  username: admin
  password: <加密或明文密码>
  maxConnections: 100
```

**测试 Jenkins 管理员账号**：
```bash
# 进入 Jenkins Pod
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- /bin/bash

# 测试管理员登录
curl -u "admin:<password>" http://localhost:8080/api/json

# 或使用 API Token 替代密码
curl -u "admin:<api_token>" http://localhost:8080/api/json
```

**如果返回 401/403**：
1. Jenkins 管理员密码已被修改
2. 需要更新 KubeSphere 配置中的密码

---

### Step 4：检查 Jenkins 中用户角色

```bash
# 进入 Jenkins Pod
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- /bin/bash

# 查看 Role Strategy 配置（需要管理员权限）
curl -u "admin:<password>" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin"

# 查看 admin 角色下分配的 SID（用户）
curl -u "admin:<password>" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" | python3 -m json.tool
```

**检查特定用户是否在 admin 角色中**：
```bash
# 获取所有分配到 admin 角色的 SID
curl -u "admin:<password>" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
  | grep -o '"sids":"[^"]*"' | grep "<username>"
```

**如果用户不在 admin 角色中**：
- 原因：Jenkins 中手动移除了用户角色，或 Role Strategy 配置被重置
- 修复：见 [4.2 重新同步用户角色](#42-重新同步用户角色)

---

### Step 5：检查 Jenkins 安全 realm

```bash
# 查看 Jenkins 安全配置
curl -u "admin:<password>" http://localhost:8080/api/json?depth=1 | python3 -c "
import sys, json
data = json.load(sys.stdin)
print('Security Realm:', data.get('securityRealm', {}).get('staplerClass', 'N/A'))
print('Authorization Strategy:', data.get('authorizationStrategy', {}).get('staplerClass', 'N/A'))
"
```

**预期配置**：
```
Security Realm: <LDAP/OAuth/KubeSphere 等>
Authorization Strategy: com.michelin.cio.hudson.plugins.rolestrategy.RoleBasedAuthorizationStrategy
```

**异常配置**：
- `Authorization Strategy` 不是 `RoleBasedAuthorizationStrategy` → Role Strategy 插件未启用
- `Security Realm` 被修改 → 用户认证方式变更，原有用户可能失效

---

### Step 6：查看 KubeSphere 后端日志

```bash
# 查看 ks-apiserver 日志
kubectl logs -n kubesphere-system -l app=ks-apiserver --tail=500 | grep -i "jenkins\|devops\|401\|403\|unauthorized\|forbidden"

# 查看 controller-manager 日志（用户同步相关）
kubectl logs -n kubesphere-system -l app=ks-controller-manager --tail=500 | grep -i "user\|jenkins\|role"
```

**关键错误模式**：

| 日志 | 含义 | 处理 |
|------|------|------|
| `401 Unauthorized` | Jenkins 管理员凭证失效 | 更新配置中的密码 |
| `403 Forbidden` | Jenkins 中用户无权限 | 重新同步用户角色 |
| `404 Not Found` | Jenkins 插件或资源不存在 | 检查插件状态 |
| `connection refused` / `timeout` | Jenkins 服务不可达 | 检查 Jenkins Pod 状态 |
| `please check if Jenkins is running well` | Jenkins 返回非预期状态码 | 检查 Jenkins 健康状态 |

---

## 四、修复方案

### 4.1 更新 Jenkins 管理员密码

**场景**：Jenkins 管理员密码被修改，导致 KubeSphere 管理操作失败。

**步骤**：

```bash
# 1. 获取 Jenkins 当前有效密码或重置密码
# 方法 A：如果知道新密码，直接更新 ConfigMap
# 方法 B：重置 Jenkins 密码

# 方法 B：重置 Jenkins admin 密码
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- /bin/bash
# 在 Jenkins 容器内执行：
cd /var/jenkins_home
# 修改 config.xml 中的 passwordHash（需要重启 Jenkins）
# 或使用 Jenkins CLI 重置

# 2. 更新 KubeSphere ConfigMap
kubectl patch cm -n kubesphere-system kubesphere-config --type='merge' -p '{
  "data": {
    "kubesphere.yaml": "<完整配置内容>"
  }
}'

# 更简单的做法：直接编辑 ConfigMap
kubectl edit cm -n kubesphere-system kubesphere-config
# 找到 devops.password 字段，更新为正确的密码或 API Token

# 3. 重启 ks-apiserver 使配置生效
kubectl rollout restart deploy -n kubesphere-system ks-apiserver
kubectl rollout status deploy -n kubesphere-system ks-apiserver
```

**使用 API Token 替代密码（推荐）**：
```bash
# 在 Jenkins UI 中：用户 → admin → Configure → API Token → Add new Token → Generate
# 将生成的 Token 填入 KubeSphere 配置的 password 字段
```

---

### 4.2 重新同步用户角色

**场景**：Jenkins 中用户角色被手动移除，或 Role Strategy 配置被重置。

**步骤 1：手动通过 API 重新分配角色**

```bash
# 进入 Jenkins Pod
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- /bin/bash

# 为指定用户分配 admin 全局角色
# 注意：多次分配同一角色是安全的（幂等）
curl -u "admin:<password>" -X POST \
  "http://localhost:8080/role-strategy/strategy/assignRole" \
  -d "type=globalRoles" \
  -d "roleName=admin" \
  -d "sid=<username>"

# 验证分配是否成功
curl -u "admin:<password>" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
  | grep "<username>"
```

**步骤 2：触发 KubeSphere 用户控制器重新同步**

```bash
# 方法 A：给 User 对象添加一个 Annotation，触发 Reconcile
kubectl annotate user <username> kubesphere.io/reconcile-trigger="$(date +%s)"

# 方法 B：重启 controller-manager，触发全量同步
kubectl rollout restart deploy -n kubesphere-system ks-controller-manager

# 方法 C：如果用户不存在，重新创建
# 在 KubeSphere UI 中邀请用户，或通过 API 创建
```

**步骤 3：验证用户控制器日志**

```bash
kubectl logs -n kubesphere-system -l app=ks-controller-manager --tail=100 | grep -i "assignDevOpsAdminRole\|unassignDevOpsAdminRole\|<username>"
```

预期看到：
```
AssignGlobalRole admin <username> success
```

---

### 4.3 重新初始化 Jenkins Role Strategy

**场景**：Role Strategy 插件配置被完全重置或损坏。

**步骤**：

```bash
# 1. 确保 Role Strategy 插件已安装并启用
# 在 Jenkins UI: Manage Jenkins → Manage Plugins → Installed → 搜索 "Role-based Authorization Strategy"

# 2. 设置授权策略为 Role-Based Strategy
# 在 Jenkins UI: Manage Jenkins → Configure Global Security → Authorization → Role-Based Strategy

# 3. 重新创建必要的全局角色
# 通过 Jenkins UI 或 API 创建 admin 角色

# 4. 批量同步所有 KubeSphere 用户到 Jenkins admin 角色
# 获取所有 KubeSphere 用户
USERS=$(kubectl get users -o jsonpath='{.items[*].metadata.name}')

for USER in $USERS; do
  echo "Syncing user: $USER"
  curl -u "admin:<password>" -X POST \
    "http://localhost:8080/role-strategy/strategy/assignRole" \
    -d "type=globalRoles" \
    -d "roleName=admin" \
    -d "sid=$USER"
done
```

---

### 4.4 处理用户被删除后的残留

**场景**：用户在 KubeSphere 中被删除，但在 Jenkins 中仍有残留配置。

**步骤**：

```bash
# 1. 从所有项目角色中移除用户 SID
curl -u "admin:<password>" -X POST \
  "http://localhost:8080/role-strategy/strategy/deleteSid" \
  -d "type=projectRoles" \
  -d "sid=<username>"

# 2. 撤销全局 admin 角色（如果存在）
curl -u "admin:<password>" -X POST \
  "http://localhost:8080/role-strategy/strategy/unassignRole" \
  -d "type=globalRoles" \
  -d "roleName=admin" \
  -d "sid=<username>"

# 3. 清理 Jenkins 中的用户（如果安全 realm 支持）
# 注意：如果 Jenkins 使用 LDAP 或 OAuth，用户可能由外部系统管理，无法直接删除
```

---

### 4.5 Jenkins Pod 重建后数据恢复

**场景**：Jenkins Pod 被删除重建后，配置和数据丢失。

**排查**：
```bash
# 检查 Jenkins PVC 状态
kubectl get pvc -n kubesphere-devops-system

# 检查 Jenkins Pod 是否使用了正确的 PVC
kubectl get pod -n kubesphere-devops-system -l app=jenkins -o yaml | grep -A 5 "volumeMounts\|persistentVolumeClaim"
```

**修复**：
- 如果 PVC 丢失，需要从备份恢复 `/var/jenkins_home`
- 如果无备份，需要重新配置 Jenkins 并同步所有用户角色

---

## 五、预防措施

### 5.1 配置管理

| 措施 | 操作 |
|------|------|
| **使用 API Token 替代密码** | Jenkins admin 使用 API Token，避免密码策略强制修改导致失效 |
| **定期备份 Jenkins 配置** | 备份 `/var/jenkins_home` 和 Role Strategy 配置 |
| **监控 Jenkins 健康** | 设置 Prometheus 告警监控 Jenkins Pod 状态 |

### 5.2 用户管理规范

| 措施 | 操作 |
|------|------|
| **不在 Jenkins 中直接管理用户** | 所有用户操作通过 KubeSphere UI/API 进行 |
| **不手动修改 Role Strategy 配置** | 避免直接修改 Jenkins 中的角色分配 |
| **禁用 Jenkins 安全 realm 变更** | 保持使用 KubeSphere OAuth 或 LDAP，不随意切换 |

### 5.3 监控告警

```bash
# 监控 KubeSphere → Jenkins 的连通性
# 可以创建一个简单的 CronJob 定期检查

cat << 'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: jenkins-health-check
  namespace: kubesphere-devops-system
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: check
            image: curlimages/curl:latest
            command:
            - /bin/sh
            - -c
            - |
              HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
                -u "admin:${JENKINS_PASSWORD}" \
                http://jenkins:8080/api/json)
              if [ "$HTTP_CODE" != "200" ]; then
                echo "Jenkins health check failed: HTTP $HTTP_CODE"
                exit 1
              fi
              echo "Jenkins is healthy"
            env:
            - name: JENKINS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jenkins-admin-credentials  # 根据实际情况调整
                  key: password
          restartPolicy: OnFailure
EOF
```

---

## 六、原理补充：为什么 Token 不会自动刷新

### 6.1 代码层面的解释

在 `pkg/simple/client/devops/jenkins/request.go` 中：

```go
func SetBasicBearTokenHeader(header *http.Header) error {
    bearTokenArray := strings.Split(header.Get("Authorization"), " ")
    bearFlag := bearTokenArray[0]
    if strings.ToLower(bearFlag) == "bearer" {
        bearToken := bearTokenArray[1]
        claim := authtoken.Claims{}
        parser := jwt.Parser{}
        // ⚠️ 仅解析 Token Payload，不验证签名和过期时间！
        _, _, err = parser.ParseUnverified(bearToken, &claim)
        if err != nil {
            return err
        }
        creds := base64.StdEncoding.EncodeToString(
            []byte(fmt.Sprintf("%s:%s", claim.Username, bearToken)),
        )
        header.Set("Authorization", fmt.Sprintf("Basic %s", creds))
    }
    return nil
}
```

**关键行为**：
1. `ParseUnverified` 只提取 Token 中的 `username` 字段
2. **不检查 `exp`（过期时间）**
3. **不检查 `iat`（签发时间）**
4. **不验证签名**
5. 原始 Token 作为 Basic Auth 的 Password 直接透传给 Jenkins

### 6.2 实际的 Token 校验在哪里发生

```
用户请求 KubeSphere API
    │
    ├──→ KubeSphere API Gateway 验证 JWT 签名和过期时间
    │      └── 如果 Token 过期，前端直接收到 401，请求不会到达 Jenkins
    │
    └──→ Token 有效，请求转发到 Jenkins
           │
           └──→ Jenkins 认证插件验证 Token
                  └── 如果 Jenkins 端认证失败，返回 401/403
```

**结论**：
- **KubeSphere 层面**：JWT Token 过期由 `ks-apiserver` 的认证中间件处理，用户需要重新登录
- **Jenkins 层面**：Token 透传后由 Jenkins 认证插件校验，KubeSphere 后端不做额外处理
- **没有自动刷新**：因为 KubeSphere 使用的是无状态 JWT，没有 Refresh Token 机制

### 6.3 用户的正确操作

当遇到授权失效时：

1. **刷新页面或重新登录 KubeSphere** → 获取新的 JWT Token
2. **如果问题持续** → 按 [三、排查步骤](#三排查步骤) 检查 Jenkins 端状态
3. **如果 Jenkins 管理员凭证失效** → 按 [4.1 更新密码](#41-更新-jenkins-管理员密码) 修复
4. **如果用户角色丢失** → 按 [4.2 重新同步](#42-重新同步用户角色) 修复

---

## 七、快速命令速查

```bash
# ===== 查看用户状态 =====
kubectl get user <username> -o yaml

# ===== 查看 KubeSphere Jenkins 配置 =====
kubectl get cm -n kubesphere-system kubesphere-config -o yaml | grep -A 5 "devops:"

# ===== 测试 Jenkins 连通性 =====
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -s -o /dev/null -w "%{http_code}" -u "admin:<password>" http://localhost:8080/api/json

# ===== 查看 Jenkins admin 角色的 SID 列表 =====
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -s -u "admin:<password>" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin"

# ===== 为用户分配 admin 角色 =====
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -u "admin:<password>" -X POST \
  "http://localhost:8080/role-strategy/strategy/assignRole" \
  -d "type=globalRoles" -d "roleName=admin" -d "sid=<username>"

# ===== 撤销用户 admin 角色 =====
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -u "admin:<password>" -X POST \
  "http://localhost:8080/role-strategy/strategy/unassignRole" \
  -d "type=globalRoles" -d "roleName=admin" -d "sid=<username>"

# ===== 查看后端日志 =====
kubectl logs -n kubesphere-system -l app=ks-apiserver --tail=200 | grep -iE "jenkins|devops|401|403"
kubectl logs -n kubesphere-system -l app=ks-controller-manager --tail=200 | grep -iE "user|jenkins|role"

# ===== 重启相关服务 =====
kubectl rollout restart deploy -n kubesphere-system ks-apiserver
kubectl rollout restart deploy -n kubesphere-system ks-controller-manager
kubectl rollout restart deploy -n kubesphere-devops-system jenkins
```

---

> **相关文档**
> - [Jenkins 对接及授权机制详解](./jenkins-integration-auth.md)
