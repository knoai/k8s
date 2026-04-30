# 新建用户无法运行 Pipeline 问题诊断与修复

> **问题现象**：新建用户在 KubeSphere 中可以看到 DevOps 项目和 Pipeline，但点击"运行"无响应或报权限错误；老用户正常  
> **适用版本**：KubeSphere v3.1.x / v3.2

---

## 目录

1. [问题根因](#一问题根因)
2. [代码层面的关键证据](#二代码层面的关键证据)
3. [快速排查](#三快速排查)
4. [修复方案](#四修复方案)
5. [根本解决方案](#五根本解决方案)
6. [验证修复](#六验证修复)

---

## 一、问题根因

### 1.1 根本原因：Jenkins 角色分配失败 + 无重试机制

KubeSphere 新建用户时，**用户控制器** (`user-controller`) 会尝试将新用户同步到 Jenkins，为其分配 `admin` 全局角色。但这个同步过程存在以下设计缺陷：

```
新建用户
    │
    ├──→ 用户控制器 Reconcile
    │       │
    │       ├──→ 添加 Finalizer ✓
    │       ├──→ LDAP 同步（如启用）✓
    │       ├──→ 密码加密 ✓
    │       ├──→ 状态同步 ✓
    │       ├──→ Kubeconfig 创建 ✓
    │       └──→ Jenkins 角色分配（waitForAssignDevOpsAdminRole）
    │               │
    │               ├──→ 调用 AssignGlobalRole("admin", username)
    │               │       轮询 1秒/次，最多15秒
    │               │
    │               ├──→ 成功 ✓ → 继续
    │               │
    │               └──→ 失败/超时 ✗ → 错误被忽略 ⚠️
    │                       用户仍标记为 "Synced" 成功
    │                       该用户再也不会自动重试同步
    │
    └──→ 用户可以在 KubeSphere 中看到 Pipeline
            │
            └──→ 但点击运行时，Jenkins 不认识这个用户 → 403/401
```

### 1.2 为什么老用户正常

| 老用户 | 新用户 |
|--------|--------|
| 创建时 Jenkins 可能处于健康状态，同步成功 | 创建时 Jenkins 可能响应慢/超时 |
| 可能曾经通过某种方式触发过 Jenkins 首次登录，安全 realm 已创建内部记录 | 从未在 Jenkins 中触发过首次登录 |
| Jenkins Role Strategy 中已存在该 SID 的角色绑定 | Jenkins 中无该用户的角色绑定或 SID 记录 |

### 1.3 可能的触发条件

| 触发条件 | 说明 |
|---------|------|
| **Jenkins 刚启动/重启** | 用户创建时 Jenkins 还在初始化，15秒超时不够 |
| **Role Strategy 插件响应慢** | Jenkins 负载高，角色分配 API 响应延迟 |
| **网络抖动** | KubeSphere controller-manager → Jenkins 之间网络瞬断 |
| **Jenkins 安全 realm 未就绪** | LDAP/OAuth 连接延迟，用户无法在 realm 中注册 |
| **大量用户同时创建** | 连接池耗尽（maxConnections 限制） |

---

## 二、代码层面的关键证据

### 2.1 用户控制器：错误被忽略

**文件**：`pkg/controller/user/user_controller.go`（第 222-229 行）

```go
if r.DevopsClient != nil {
    // assign jenkins role after user create, assign multiple times is allowed
    // used as logged-in users can do anything
    if err = r.waitForAssignDevOpsAdminRole(user); err != nil {
        // ignore timeout error          ←── ⚠️ 关键：错误被忽略！
        r.Recorder.Event(user, corev1.EventTypeWarning, failedSynced, fmt.Sprintf(syncFailMessage, err))
    }
}
```

**结论**：即使 Jenkins 角色分配失败，用户控制器也不会阻止用户创建，也不会在后续自动重试。错误仅以 Event 形式记录，用户对象的状态仍然被标记为同步成功。

### 2.2 角色分配：15 秒超时

**文件**：`pkg/controller/user/user_controller.go`（第 344-353 行）

```go
func (r *Reconciler) waitForAssignDevOpsAdminRole(user *iamv1alpha2.User) error {
    err := utilwait.PollImmediate(interval, timeout, func() (done bool, err error) {
        if err := r.DevopsClient.AssignGlobalRole(modelsdevops.JenkinsAdminRoleName, user.Name); err != nil {
            klog.Error(err)
            return false, err
        }
        return true, nil
    })
    return err
}
```

**常量定义**（第 69-70 行）：
```go
interval = time.Second        // 1秒重试间隔
timeout  = 15 * time.Second   // 15秒超时
```

**结论**：只有 15 秒的重试窗口。如果 Jenkins 在这 15 秒内一直不可用，同步永久失败。

### 2.3 角色分配 API 调用

**文件**：`pkg/simple/client/devops/jenkins/jenkins.go`（第 267-286 行）

```go
func (j *Jenkins) AssignGlobalRole(roleName string, sid string) error {
    globalRole, err := j.GetGlobalRoleHandler(roleName)
    if err != nil {
        return err
    }
    param := map[string]string{
        "type":     GLOBAL_ROLE,
        "roleName": globalRole.Raw.RoleName,
        "sid":      sid,
    }
    responseString := ""
    response, err := j.Requester.Post("/role-strategy/strategy/assignRole", nil, &responseString, param)
    if err != nil {
        return err
    }
    if response.StatusCode != http.StatusOK {
        return errors.New(strconv.Itoa(response.StatusCode))
    }
    return nil
}
```

**结论**：调用 Jenkins Role Strategy 插件的 `assignRole` API。此 API 仅将 SID（用户名）关联到角色，**不验证该 SID 是否已在 Jenkins 安全 realm 中存在**。

### 2.4 Jenkins 中的 "Lazy User Creation"

KubeSphere 采用 **"Lazy User Provisioning"** 策略：
- 不在 Jenkins 中显式预创建用户账号
- 依赖 Jenkins 安全 realm（LDAP / OAuth / KubeSphere OAuth）在用户首次登录时自动创建
- `assignRole` 将 SID 关联到角色，但如果 realm 中没有该用户的内部记录，该 SID 实际上是无效占位符

```
正常流程：
用户登录 KubeSphere → realm 验证 Token → Jenkins 自动创建内部用户记录
                      → assignRole 的 SID 生效 → 用户可以操作 Pipeline

异常流程：
assignRole 在 realm 创建用户之前执行 → SID 被绑定到角色但用户记录不存在
                      → 用户登录 KubeSphere → realm 创建用户记录
                      → 但角色绑定可能不关联到新创建的用户 → 403
```

---

## 三、快速排查

### Step 1：确认新建用户是否有 Jenkins admin 角色

```bash
# 进入 Jenkins Pod
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- /bin/bash

# 查看 admin 全局角色的所有 SID
JENKINS_ADMIN_USER="admin"
JENKINS_ADMIN_PASS="<password或API Token>"

curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" | python3 -m json.tool
```

**预期结果**（正常用户）：
```json
{
    "sids": [
        "admin",
        "existing-user-1",
        "existing-user-2"
    ],
    "permissionIds": [...]
}
```

**异常结果**：
- `"sids": ["admin"]` → 只有 admin，没有其他用户
- 列表中没有新建用户的 username → **确认问题：角色未同步**

### Step 2：对比老用户和新用户的 SID 状态

```bash
# 获取所有 KubeSphere 用户
kubectl get users -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'

# 对每个用户检查是否在 Jenkins admin 角色中
for USER in $(kubectl get users -o jsonpath='{.items[*].metadata.name}'); do
  HAS_ROLE=$(curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
    "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
    | grep -c "\"$USER\"")
  if [ "$HAS_ROLE" -eq 0 ]; then
    echo "❌ 缺失: $USER"
  else
    echo "✅ 正常: $USER"
  fi
done
```

### Step 3：检查用户控制器日志

```bash
# 查看 controller-manager 日志，搜索新建用户的同步记录
NEW_USER="<新建用户的username>"

kubectl logs -n kubesphere-system -l app=ks-controller-manager --tail=1000 | grep -i "$NEW_USER"

# 搜索 Jenkins 角色分配相关的错误
kubectl logs -n kubesphere-system -l app=ks-controller-manager --tail=1000 | grep -iE "AssignGlobalRole|waitForAssignDevOpsAdminRole|failedSynced"
```

**关键错误模式**：
```
401  ←── Jenkins 管理员凭证失效
403  ←── Role Strategy 插件异常或权限不足
404  ←── Role Strategy 插件未安装或路径变更
timeout  ←── Jenkins 不可达或响应超时
connection refused  ←── Jenkins 服务未就绪
```

### Step 4：检查 Jenkins 安全 realm 中的用户

```bash
# 查看 Jenkins 中的用户列表
# 注意：不同 realm 的存储方式不同

# 方法 A：通过 Jenkins API（需要管理员权限）
curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
  "http://localhost:8080/asynchPeople/api/json?depth=1" | python3 -m json.tool

# 方法 B：如果 Jenkins 使用文件型用户数据库
ls -la /var/jenkins_home/users/
```

**对比检查**：
- 老用户是否在 Jenkins 用户目录中有记录？
- 新用户是否**没有**对应记录？

---

## 四、修复方案

### 方案 A：手动为缺失用户分配 Jenkins 角色（推荐，最快）

```bash
# 进入 Jenkins Pod
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- /bin/bash

JENKINS_ADMIN_USER="admin"
JENKINS_ADMIN_PASS="<password或API Token>"

# 为单个新建用户分配 admin 角色
curl -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" -X POST \
  "http://localhost:8080/role-strategy/strategy/assignRole" \
  -d "type=globalRoles" \
  -d "roleName=admin" \
  -d "sid=<新建用户的username>"

# 验证
curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
  | grep "<新建用户的username>"
```

**批量修复所有缺失用户**：
```bash
# 在 Jenkins Pod 内执行
for USER in $(kubectl get users -o jsonpath='{.items[*].metadata.name}'); do
  HAS_ROLE=$(curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
    "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
    | grep -c "\"$USER\"")
  if [ "$HAS_ROLE" -eq 0 ]; then
    echo "修复: $USER"
    curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" -X POST \
      "http://localhost:8080/role-strategy/strategy/assignRole" \
      -d "type=globalRoles" -d "roleName=admin" -d "sid=$USER"
  fi
done
```

### 方案 B：触发用户控制器重新同步

给用户对象添加 Annotation 或修改字段，触发 Reconcile：

```bash
# 方法 A：添加 Annotation
NEW_USER="<username>"
kubectl annotate user "$NEW_USER" kubesphere.io/resync="$(date +%s)"

# 方法 B：修改一个无害字段（如 label）
kubectl label user "$NEW_USER" kubesphere.io/debug-sync="true"

# 方法 C：如果用户密码是明文，触发密码加密流程（会触发完整 Reconcile）
# 注意：此方法会修改用户密码状态，请谨慎使用
```

**然后观察 controller-manager 日志**：
```bash
kubectl logs -n kubesphere-system -l app=ks-controller-manager -f | grep -i "$NEW_USER"
```

### 方案 C：重启 controller-manager（全量重试）

如果大量用户缺失角色，可以重启 controller-manager，它会重新 Reconcile 所有 User 对象：

```bash
kubectl rollout restart deploy -n kubesphere-system ks-controller-manager
kubectl rollout status deploy -n kubesphere-system ks-controller-manager

# 观察日志
kubectl logs -n kubesphere-system -l app=ks-controller-manager -f | grep -iE "AssignGlobalRole|waitForAssignDevOpsAdminRole|failedSynced"
```

**注意**：此方法会触发所有用户的重新同步，可能产生大量 Jenkins API 调用，请在低峰期执行。

### 方案 D：确保 Jenkins 安全 realm 中用户已创建

如果 Jenkins 使用 LDAP / OAuth / KubeSphere OAuth，需要确保用户在 realm 中有记录：

```bash
# 以新建用户身份触发一次 Jenkins API 调用
# 这会强制 realm 创建用户内部记录

# 方法：通过 KubeSphere 前端登录后，刷新 DevOps Pipeline 页面
# 或者在浏览器中直接访问 Jenkins URL（如果可访问）

# 如果 Jenkins 使用 KubeSphere OAuth，可以尝试：
curl -u "<新建用户username>:<用户密码或Token>" \
  "http://jenkins.kubesphere-devops-system:8080/api/json"
```

---

## 五、根本解决方案

### 5.1 代码修复建议

当前代码存在以下问题，建议通过以下方式修复：

| 问题 | 修复建议 |
|------|---------|
| 错误被忽略 | 将 `waitForAssignDevOpsAdminRole` 的错误改为**非忽略**，失败时重试 Reconcile |
| 无后续重试 | 添加条件：如果用户没有 Jenkins 角色，在每次 Reconcile 时重新尝试分配 |
| 15秒超时过短 | 增加超时时间，或根据错误类型决定是否重试 |
| 无状态标记 | 在用户 Status 中添加 `JenkinsRoleSynced` 字段，便于排查 |

**示例修复代码**（概念）：
```go
// 在用户 Status 中添加角色同步状态
type UserStatus struct {
    // ... 现有字段
    JenkinsRoleSynced *bool `json:"jenkinsRoleSynced,omitempty"`
}

// Reconcile 中修改逻辑
if r.DevopsClient != nil {
    if user.Status.JenkinsRoleSynced == nil || !*user.Status.JenkinsRoleSynced {
        if err = r.waitForAssignDevOpsAdminRole(user); err != nil {
            // 不忽略错误，返回重试
            return ctrl.Result{Requeue: true, RequeueAfter: 30 * time.Second}, err
        }
        synced := true
        user.Status.JenkinsRoleSynced = &synced
        if err = r.Status().Update(ctx, user); err != nil {
            return ctrl.Result{}, err
        }
    }
}
```

### 5.2 运维层面预防

```bash
# 1. 创建监控告警：检测 Jenkins 角色缺失的用户

# 2. 创建定期修复 CronJob
cat << 'EOF' | kubectl apply -f -
apiVersion: batch/v1
kind: CronJob
metadata:
  name: jenkins-role-sync-fix
  namespace: kubesphere-devops-system
spec:
  schedule: "0 */6 * * *"  # 每6小时执行一次
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: sync
            image: curlimages/curl:latest
            command:
            - /bin/sh
            - -c
            - |
              JENKINS_ADMIN_USER="admin"
              JENKINS_ADMIN_PASS="${JENKINS_PASSWORD}"
              
              # 获取 KubeSphere 所有用户
              # 注意：此 CronJob 需要访问 K8s API，建议用 ServiceAccount
              for USER in $(kubectl get users -o jsonpath='{.items[*].metadata.name}'); do
                HAS_ROLE=$(curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
                  "http://jenkins:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
                  | grep -c "\"$USER\"")
                if [ "$HAS_ROLE" -eq 0 ]; then
                  echo "$(date): 修复用户 $USER"
                  curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" -X POST \
                    "http://jenkins:8080/role-strategy/strategy/assignRole" \
                    -d "type=globalRoles" -d "roleName=admin" -d "sid=$USER"
                fi
              done
            env:
            - name: JENKINS_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: jenkins-admin-credentials
                  key: password
          serviceAccountName: jenkins-role-sync-sa
          restartPolicy: OnFailure
EOF
```

### 5.3 升级建议

KubeSphere 3.3+ 版本对 DevOps 模块进行了重构（引入 `ks-devops` 独立组件），可能已修复此问题。建议：
- 评估升级到 KubeSphere 3.3 或更高版本
- 关注 `ks-devops` 项目的 Issue 和 Release Note

---

## 六、验证修复

### 6.1 验证 Jenkins 角色已分配

```bash
NEW_USER="<username>"

curl -s -u "$JENKINS_ADMIN_USER:$JENKINS_ADMIN_PASS" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin" \
  | grep "$NEW_USER"
```

### 6.2 验证用户可操作 Pipeline

1. 以新建用户身份登录 KubeSphere UI
2. 进入 DevOps 项目
3. 点击 Pipeline → 运行
4. 观察是否能正常触发构建

### 6.3 验证 API 调用

```bash
# 获取新建用户的 JWT Token（通过登录 API 或从浏览器复制）
TOKEN="<新建用户的 JWT Token>"

# 测试 Pipeline 列表 API
curl -H "Authorization: Bearer $TOKEN" \
  "http://<kubesphere-api>/kapis/devops.kubesphere.io/v1alpha3/devops/<project>/pipelines"

# 测试运行 Pipeline API
curl -X POST -H "Authorization: Bearer $TOKEN" \
  "http://<kubesphere-api>/kapis/devops.kubesphere.io/v1alpha3/devops/<project>/pipelines/<pipeline>/run"
```

### 6.4 查看 ks-apiserver 日志确认无 403/401

```bash
kubectl logs -n kubesphere-system -l app=ks-apiserver --tail=100 | grep -iE "401|403|forbidden|unauthorized"
# 应该没有与新建用户相关的错误
```

---

## 附录：快速诊断命令汇总

```bash
# ===== 1. 查看所有用户 =====
kubectl get users

# ===== 2. 查看单个用户详情 =====
kubectl get user <username> -o yaml

# ===== 3. 查看 Jenkins admin 角色的 SID 列表 =====
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -s -u "admin:<password>" \
  "http://localhost:8080/role-strategy/strategy/getRole?type=globalRoles&roleName=admin"

# ===== 4. 查看 controller-manager 日志 =====
kubectl logs -n kubesphere-system -l app=ks-controller-manager --tail=500 | grep -iE "AssignGlobalRole|failedSynced|timeout"

# ===== 5. 手动为用户分配 admin 角色 =====
kubectl exec -it -n kubesphere-devops-system deploy/jenkins -- \
  curl -u "admin:<password>" -X POST \
  "http://localhost:8080/role-strategy/strategy/assignRole" \
  -d "type=globalRoles" -d "roleName=admin" -d "sid=<username>"

# ===== 6. 触发用户重新同步 =====
kubectl annotate user <username> kubesphere.io/resync="$(date +%s)"

# ===== 7. 重启 controller-manager =====
kubectl rollout restart deploy -n kubesphere-system ks-controller-manager
```

---

> **相关文档**
> - [Jenkins 对接及授权机制详解](./jenkins-integration-auth.md)
> - [Jenkins 授权失效排查与修复指南](./jenkins-auth-troubleshooting.md)
