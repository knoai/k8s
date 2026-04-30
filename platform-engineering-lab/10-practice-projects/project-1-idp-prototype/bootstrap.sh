#!/bin/bash
# IDP 原型构建 - Bootstrap 脚本
# 一键部署 Backstage + ArgoCD + K8s 集成环境
# 用于 platform-engineering-lab 项目 1
#
# 目标: 构建最小可用的 Internal Developer Platform 原型
# 包含: 开发者门户、GitOps 持续交付、K8s 集群管理

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "  IDP 原型构建 - Bootstrap"
echo "  预计时间: 10-15 分钟"
echo "=============================================="
echo ""
echo "本脚本将部署以下组件:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  基础设施层                              │"
echo "  │    Kind 集群（3 节点）                  │"
echo "  │    Ingress Nginx Controller             │"
echo "  └─────────────────────────────────────────┘"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  GitOps 层                               │"
echo "  │    ArgoCD（声明式持续交付）             │"
echo "  │    - Application 管理                   │"
echo "  │    - 自动同步                           │"
echo "  │    - 多集群支持                         │"
echo "  └─────────────────────────────────────────┘"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  开发者门户层                            │"
echo "  │    Backstage（服务目录、软件模板）      │"
echo "  │    - 服务目录（Catalog）                │"
echo "  │    - 软件模板（Scaffolder）             │"
echo "  │    - TechDocs 文档                      │"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  访问地址:"
echo "    Backstage: http://localhost:30030"
echo "    ArgoCD:    https://localhost:<nodeport>"
echo ""

# 检查前置条件
check_prerequisites() {
  echo "=== 检查前置条件 ==="
  local missing=()
  
  for cmd in docker kind kubectl helm; do
    if command -v "$cmd" &> /dev/null; then
      local version=$($cmd version --short 2>/dev/null | head -1 || $cmd version 2>/dev/null | head -1 || echo "unknown")
      echo "  ✓ $cmd ($version)"
    else
      echo "  ✗ $cmd 未安装"
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "错误: 以下必需工具未安装: ${missing[*]}"
    echo ""
    echo "安装指南:"
    echo "  Docker:  https://docs.docker.com/get-docker/"
    echo "  Kind:    https://kind.sigs.k8s.io/docs/user/quick-start/"
    echo "  Kubectl: https://kubernetes.io/docs/tasks/tools/"
    echo "  Helm:    https://helm.sh/docs/intro/install/"
    exit 1
  fi
  
  # 检查 Docker 内存
  local docker_mem=$(docker info --format '{{.MemTotal}}' 2>/dev/null || echo "0")
  if [ "$docker_mem" -lt 8000000000 ]; then
    echo ""
    echo "警告: Docker 可用内存 < 8GB (${docker_mem} bytes)"
    echo "建议: 增加 Docker Desktop 内存限制到 8GB+"
    echo "      (Docker Desktop → Settings → Resources → Memory)"
    read -p "是否继续? [y/N] " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit 1
    fi
  fi
  
  echo ""
}

# 创建 Kind 集群
create_cluster() {
  echo "=== 创建 Kind 集群 ==="
  if kind get clusters | grep -q "^idp-lab$"; then
    echo "集群 idp-lab 已存在，跳过创建"
    echo "  如需重建，请先运行: kind delete cluster --name idp-lab"
    kubectl config use-context kind-idp-lab 2>/dev/null || true
    return
  fi
  
  cat > /tmp/kind-idp.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: idp-lab
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
  extraPortMappings:
  - containerPort: 80
    hostPort: 80
    protocol: TCP
  - containerPort: 443
    hostPort: 443
    protocol: TCP
  - containerPort: 30030
    hostPort: 30030
    protocol: TCP
  - containerPort: 30080
    hostPort: 30080
    protocol: TCP
- role: worker
  extraPortMappings:
  - containerPort: 30031
    hostPort: 30031
    protocol: TCP
- role: worker
  extraPortMappings:
  - containerPort: 30032
    hostPort: 30032
    protocol: TCP
EOF

  echo "  创建 Kind 集群 idp-lab（3 节点）..."
  kind create cluster --config /tmp/kind-idp.yaml
  echo "  ✓ 集群创建完成"
  echo ""
}

# 安装 Ingress Nginx
install_ingress() {
  echo "=== 安装 Ingress Nginx ==="
  
  if kubectl get pods -n ingress-nginx -l app.kubernetes.io/component=controller 2>/dev/null | grep -q Running; then
    echo "Ingress Nginx 已安装，跳过"
    return
  fi
  
  echo "  部署 Ingress Nginx Controller..."
  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
  
  echo "  等待 Ingress Controller 就绪..."
  kubectl wait --namespace ingress-nginx \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s
  
  echo "  ✓ Ingress Nginx 安装完成"
  echo ""
}

# 安装 ArgoCD
install_argocd() {
  echo "=== 安装 ArgoCD ==="
  
  kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
  
  if kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>/dev/null | grep -q Running; then
    echo "ArgoCD 已安装，跳过"
    return
  fi
  
  echo "  部署 ArgoCD（稳定版）..."
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  
  echo "  等待 ArgoCD 组件就绪（约 2-3 分钟）..."
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
  kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n argocd --timeout=120s
  
  # 暴露为 NodePort
  kubectl patch svc argocd-server -n argocd -p '{"spec": {"type": "NodePort"}}'
  
  echo "  ✓ ArgoCD 安装完成"
  echo ""
}

# 获取 ArgoCD 访问信息
show_argocd_info() {
  echo "=== ArgoCD 访问信息 ==="
  
  local argo_password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath="{.data.password}" | base64 -d 2>/dev/null || echo "未知")
  local argo_nodeport=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[?(@.name=="https")].nodePort}' 2>/dev/null || echo "未知")
  
  echo "  URL:      https://localhost:$argo_nodeport"
  echo "  用户名:   admin"
  echo "  密码:     $argo_password"
  echo ""
  echo "  CLI 登录:"
  echo "    argocd login localhost:$argo_nodeport --username admin --password $argo_password --insecure"
  echo ""
  echo "  首次使用步骤:"
  echo "    1. 浏览器打开 https://localhost:$argo_nodeport"
  echo "    2. 接受自签名证书警告（Chrome: 点击高级 → 继续前往）"
  echo "    3. 使用 admin / $argo_password 登录"
  echo "    4. 创建 Application:"
  echo "       - Source: Git 仓库 URL"
  echo "       - Path: k8s manifests 目录"
  echo "       - Destination: https://kubernetes.default.svc"
  echo "    5. 开启自动同步（Auto-Sync）"
  echo ""
}

# 安装 Backstage
install_backstage() {
  echo "=== 安装 Backstage ==="
  
  kubectl create namespace backstage --dry-run=client -o yaml | kubectl apply -f -
  
  if kubectl get pods -n backstage -l app=backstage 2>/dev/null | grep -q Running; then
    echo "Backstage 已安装，跳过"
    return
  fi
  
  echo "  部署 Backstage（使用官方示例镜像）..."
  echo "  注意: 首次启动需要下载镜像，可能需要 3-5 分钟"
  
  cat > /tmp/backstage-deploy.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: backstage
  namespace: backstage
spec:
  replicas: 1
  selector:
    matchLabels:
      app: backstage
  template:
    metadata:
      labels:
        app: backstage
    spec:
      containers:
      - name: backstage
        image: ghcr.io/backstage/backstage:latest
        ports:
        - containerPort: 7007
        env:
        - name: APP_CONFIG_app_baseUrl
          value: "http://localhost:30030"
        - name: APP_CONFIG_backend_baseUrl
          value: "http://localhost:30030"
        - name: APP_CONFIG_backend_listen_port
          value: "7007"
        - name: NODE_ENV
          value: "production"
        resources:
          limits:
            memory: "1Gi"
            cpu: "1"
          requests:
            memory: "512Mi"
            cpu: "500m"
        readinessProbe:
          httpGet:
            path: /healthcheck
            port: 7007
          initialDelaySeconds: 30
          periodSeconds: 10
          failureThreshold: 6
        livenessProbe:
          httpGet:
            path: /healthcheck
            port: 7007
          initialDelaySeconds: 60
          periodSeconds: 30
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: backstage
  namespace: backstage
spec:
  selector:
    app: backstage
  ports:
  - port: 7007
    targetPort: 7007
    nodePort: 30030
  type: NodePort
EOF

  kubectl apply -f /tmp/backstage-deploy.yaml
  
  echo "  等待 Backstage 就绪（可能需要 3-5 分钟，镜像较大）..."
  kubectl wait --for=condition=ready pod -l app=backstage -n backstage --timeout=300s
  
  echo "  ✓ Backstage 安装完成"
  echo "  访问: http://localhost:30030"
  echo ""
}

# 验证安装
verify() {
  echo "=============================================="
  echo "  验证安装"
  echo "=============================================="
  echo ""
  echo "K8s 节点:"
  kubectl get nodes
  echo ""
  echo "ArgoCD Pod:"
  kubectl get pods -n argocd
  echo ""
  echo "Backstage Pod:"
  kubectl get pods -n backstage
  echo ""
  echo "Ingress Controller:"
  kubectl get pods -n ingress-nginx
  echo ""
  echo "=============================================="
  echo "  IDP 原型构建完成"
  echo ""
  echo "  访问地址:"
  echo "    Backstage:     http://localhost:30030"
  echo "    ArgoCD:        https://localhost:<nodeport>"
  echo ""
  echo "  实验步骤:"
  echo ""
  echo "    步骤 1: 登录 ArgoCD，创建 Application"
  echo "      1) 浏览器打开 ArgoCD URL"
  echo "      2) 点击 'NEW APP'"
  echo "      3) 填写:"
  echo "         - Application Name: demo-app"
  echo "         - Project: default"
  echo "         - Sync Policy: Automatic"
  echo "         - Repository URL: 你的 Git 仓库"
  echo "         - Path: k8s/ 或 manifests/"
  echo "         - Cluster: https://kubernetes.default.svc"
  echo "         - Namespace: demo"
  echo "      4) 点击 CREATE"
  echo "      5) 观察自动同步状态"
  echo ""
  echo "    步骤 2: 登录 Backstage，注册组件"
  echo "      1) 浏览器打开 http://localhost:30030"
  echo "      2) 点击 'Create' → 'Register Existing Component'"
  echo "      3) 输入 catalog-info.yaml 的 URL"
  echo "      4) 查看组件详情和依赖关系"
  echo ""
  echo "    步骤 3: 创建 Software Template"
  echo "      1) 定义 template.yaml（参数 + 步骤）"
  echo "      2) 用户填写参数，触发模板执行"
  echo "      3) 执行 Actions:"
  echo "         fetch:template → publish:github → register"
  echo "      4) 自动生成代码仓库、CI 配置、K8s manifests"
  echo ""
  echo "    步骤 4: 配置 Backstage K8s 插件"
  echo "      1) 创建 ServiceAccount 和 RBAC"
  echo "      2) 配置 app-config.yaml 中的 kubernetes.clusterLocatorMethods"
  echo "      3) 在实体页面查看 Pod 状态和资源使用"
  echo ""
  echo "  面试知识点:"
  echo "    Q: IDP（内部开发者平台）的核心价值？"
  echo "    A: 1) 自助服务: 开发者自助创建服务、申请资源"
  echo "       2) 标准化: 统一技术栈、CI/CD 流程、监控规范"
  echo "       3) 黄金路径: 提供经过验证的最佳实践模板"
  echo "       4) 认知减负: 开发者只需关注业务逻辑"
  echo "       5) 规模化: 让 100 个团队以同样高标准交付"
  echo ""
  echo "    Q: Backstage 的软件模板(Scaffolder)工作原理？"
  echo "    A: 1) 定义 template.yaml（参数定义 + 步骤序列）"
  echo "       2) 用户在 UI 填写参数（服务名、语言、端口等）"
  echo "       3) 触发模板执行，按顺序运行 Actions"
  echo "       4) 常见 Actions:"
  echo "          - fetch:template: 从模板仓库拉取模板文件"
  echo "          - publish:github: 创建 GitHub 仓库并推送代码"
  echo "          - register: 将新组件注册到 Backstage Catalog"
  echo "       5) 结果: 新的代码仓库 + CI 配置 + 部署配置"
  echo ""
  echo "    Q: GitOps 的核心原则？"
  echo "    A: 1) 声明式: 系统的期望状态存储在 Git 中"
  echo "       2) 版本化: 所有变更都有 Git 历史记录"
  echo "       3) 自动同步: 代理（如 ArgoCD）自动将 Git 状态同步到集群"
  echo "       4) 一致性: Git 是唯一的真理来源"
  echo "       优势: 回滚简单（git revert）、审计完整、协作友好"
  echo "=============================================="
}

# 主流程
main() {
  check_prerequisites
  create_cluster
  install_ingress
  install_argocd
  show_argocd_info
  install_backstage
  verify
}

main "$@"
