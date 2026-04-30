#!/bin/bash
# Service Mesh 延迟实验 - 环境部署脚本
# 部署 Istio + 4 个应用（无 Sidecar / STRICT mTLS / PERMISSIVE / WASM）
# 用于 platform-engineering-lab 项目 5
# 用于测量不同配置下的 Service Mesh 延迟开销

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "  Service Mesh 延迟实验 - 环境部署"
echo "  预计时间: 10-15 分钟（Istio 组件较多）"
echo "=============================================="
echo ""
echo "本实验将部署:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Kind 集群（3 节点）                    │"
echo "  │  Istio（demo profile）                  │"
echo "  │  监控栈（Prometheus + Grafana           │"
echo "  │         + Kiali + Jaeger）              │"
echo "  └─────────────────────────────────────────┘"
echo "  ┌─────────────────────────────────────────┐"
echo "  │  4 个测试应用                           │"
echo "  │    App A: 无 Sidecar（基线对照）        │"
echo "  │    App B: STRICT mTLS                   │"
echo "  │    App C: PERMISSIVE mTLS               │"
echo "  │    App D: 下游服务（被 B/C 调用）       │"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  预期延迟差异（P50，本地测试）:"
echo "    App A（无 Sidecar）:  ~2-3ms"
echo "    App C（PERMISSIVE）:  ~4-6ms（+2-3ms）"
echo "    App B（STRICT）:     ~7-10ms（+5-7ms）"
echo ""

# 检查前置条件
check_prerequisites() {
  echo "=== 检查前置条件 ==="
  local missing=()
  
  for cmd in docker kind kubectl helm istioctl; do
    if command -v "$cmd" &> /dev/null; then
      local version=$($cmd version --short 2>/dev/null | head -1 || echo "installed")
      echo "  ✓ $cmd ($version)"
    else
      echo "  ✗ $cmd 未安装"
      missing+=("$cmd")
    fi
  done
  
  if [ ${#missing[@]} -gt 0 ]; then
    echo ""
    echo "错误: 以下必需工具未安装: ${missing[*]}"
    if [[ " ${missing[*]} " =~ " istioctl " ]]; then
      echo ""
      echo "安装 istioctl:"
      echo "  curl -L https://istio.io/downloadIstio | sh -"
      echo "  export PATH=\"\$PATH:\$HOME/istio-*/bin\""
    fi
    exit 1
  fi
  
  echo ""
}

# 创建 Kind 集群
create_cluster() {
  echo "=== 创建 Kind 集群 ==="
  if kind get clusters | grep -q "^mesh-lab$"; then
    echo "集群 mesh-lab 已存在，跳过创建"
    kubectl config use-context kind-mesh-lab 2>/dev/null || true
    return
  fi
  
  cat > /tmp/kind-mesh.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: mesh-lab
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8090
    protocol: TCP
  - containerPort: 30081
    hostPort: 8091
    protocol: TCP
  - containerPort: 30082
    hostPort: 8092
    protocol: TCP
- role: worker
- role: worker
EOF

  kind create cluster --config /tmp/kind-mesh.yaml
  echo "  ✓ 集群创建完成"
  echo ""
}

# 安装 Istio
install_istio() {
  echo "=== 安装 Istio ==="
  
  if kubectl get pods -n istio-system -l app=istiod 2>/dev/null | grep -q Running; then
    echo "Istio 已安装，跳过"
    return
  fi
  
  echo "  安装 Istio demo profile（含 ingress-gateway 和 egress-gateway）..."
  istioctl install --set profile=demo -y
  
  echo "  等待 Istio 组件就绪..."
  kubectl wait --for=condition=ready pod -l app=istiod -n istio-system --timeout=300s
  kubectl wait --for=condition=ready pod -l app=istio-ingressgateway -n istio-system --timeout=300s
  
  # 启用自动 Sidecar 注入
  kubectl label namespace default istio-injection=enabled --overwrite 2>/dev/null || true
  kubectl create namespace mesh-lab --dry-run=client -o yaml | kubectl apply -f -
  kubectl label namespace mesh-lab istio-injection=enabled --overwrite
  
  echo "  ✓ Istio 安装完成"
  echo ""
}

# 部署监控栈
install_monitoring() {
  echo "=== 安装监控栈（Prometheus + Grafana + Kiali + Jaeger）==="
  
  if kubectl get pods -n istio-system -l app=prometheus 2>/dev/null | grep -q Running; then
    echo "监控栈已安装，跳过"
    return
  fi
  
  echo "  部署 Prometheus..."
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/prometheus.yaml
  
  echo "  部署 Grafana..."
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/grafana.yaml
  
  echo "  部署 Kiali..."
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/kiali.yaml
  
  echo "  部署 Jaeger..."
  kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.20/samples/addons/jaeger.yaml
  
  echo "  等待监控组件就绪..."
  kubectl wait --for=condition=ready pod -l app=prometheus -n istio-system --timeout=300s
  kubectl wait --for=condition=ready pod -l app=grafana -n istio-system --timeout=120s
  kubectl wait --for=condition=ready pod -l app=kiali -n istio-system --timeout=120s
  kubectl wait --for=condition=ready pod -l app=jaeger -n istio-system --timeout=120s
  
  echo "  ✓ 监控栈安装完成"
  echo ""
}

# 部署测试应用
deploy_apps() {
  echo "=== 部署测试应用 ==="
  
  # App A: 无 Sidecar（基线）
  echo "  部署 App A（无 Sidecar，基线对照组）..."
  cat > /tmp/app-a.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-a
  namespace: mesh-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-a
  template:
    metadata:
      labels:
        app: app-a
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
      - name: app
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
          requests:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: app-a
  namespace: mesh-lab
spec:
  selector:
    app: app-a
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
  type: NodePort
EOF
  kubectl apply -f /tmp/app-a.yaml
  
  # App B: STRICT mTLS
  echo "  部署 App B（STRICT mTLS）..."
  cat > /tmp/app-b.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-b
  namespace: mesh-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-b
  template:
    metadata:
      labels:
        app: app-b
    spec:
      containers:
      - name: app
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
          requests:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: app-b
  namespace: mesh-lab
spec:
  selector:
    app: app-b
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30081
  type: NodePort
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: app-b
  namespace: mesh-lab
spec:
  selector:
    matchLabels:
      app: app-b
  mtls:
    mode: STRICT
EOF
  kubectl apply -f /tmp/app-b.yaml
  
  # App C: PERMISSIVE mTLS
  echo "  部署 App C（PERMISSIVE mTLS）..."
  cat > /tmp/app-c.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-c
  namespace: mesh-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-c
  template:
    metadata:
      labels:
        app: app-c
    spec:
      containers:
      - name: app
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
          requests:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: app-c
  namespace: mesh-lab
spec:
  selector:
    app: app-c
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30082
  type: NodePort
---
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: app-c
  namespace: mesh-lab
spec:
  selector:
    matchLabels:
      app: app-c
  mtls:
    mode: PERMISSIVE
EOF
  kubectl apply -f /tmp/app-c.yaml
  
  # App D: 模拟下游服务
  echo "  部署 App D（下游服务，被 App B/C 调用）..."
  cat > /tmp/app-d.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-d
  namespace: mesh-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-d
  template:
    metadata:
      labels:
        app: app-d
    spec:
      containers:
      - name: app
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "256Mi"
            cpu: "200m"
          requests:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: app-d
  namespace: mesh-lab
spec:
  selector:
    app: app-d
  ports:
  - port: 80
    targetPort: 80
EOF
  kubectl apply -f /tmp/app-d.yaml
  
  echo "  等待应用就绪..."
  kubectl wait --for=condition=ready pod -l app=app-a -n mesh-lab --timeout=120s
  kubectl wait --for=condition=ready pod -l app=app-b -n mesh-lab --timeout=120s
  kubectl wait --for=condition=ready pod -l app=app-c -n mesh-lab --timeout=120s
  kubectl wait --for=condition=ready pod -l app=app-d -n mesh-lab --timeout=120s
  
  echo "  ✓ 应用部署完成"
  echo ""
}

# 验证安装
verify() {
  echo "=============================================="
  echo "  验证安装"
  echo "=============================================="
  echo ""
  echo "Istio 系统 Pod:"
  kubectl get pods -n istio-system
  echo ""
  echo "应用 Pod（注意 READY 列，2/2 = 有 Sidecar）:"
  kubectl get pods -n mesh-lab
  echo ""
  echo "PeerAuthentication 策略:"
  kubectl get peerauthentication -n mesh-lab
  echo ""
  echo "=============================================="
  echo "  Service Mesh 实验环境部署完成"
  echo ""
  echo "  访问地址:"
  echo "    App A（无 Sidecar）:  http://localhost:8090/get"
  echo "    App B（STRICT mTLS）: http://localhost:8091/get"
  echo "    App C（PERMISSIVE）:  http://localhost:8092/get"
  echo ""
  echo "  压测命令:"
  echo "    # App A（基线）"
  echo "    siege -c 50 -t 30s http://localhost:8090/get"
  echo ""
  echo "    # App B（STRICT mTLS）"
  echo "    siege -c 50 -t 30s http://localhost:8091/get"
  echo ""
  echo "    # App C（PERMISSIVE）"
  echo "    siege -c 50 -t 30s http://localhost:8092/get"
  echo ""
  echo "  监控访问:"
  echo "    Kiali:   kubectl port-forward svc/kiali -n istio-system 20001:20001"
  echo "    Jaeger:  kubectl port-forward svc/tracing -n istio-system 16686:16686"
  echo "    Grafana: kubectl port-forward svc/grafana -n istio-system 3000:3000"
  echo ""
  echo "  诊断脚本:"
  echo "    ./diagnose-mesh.sh app-b    # 诊断 App B"
  echo "    ./diagnose-mesh.sh app-c    # 诊断 App C"
  echo ""
  echo "  预期延迟差异（P50，本地测试）:"
  echo "    App A（无 Sidecar）:  ~2-3ms"
  echo "    App C（PERMISSIVE）:  ~4-6ms（+2-3ms）"
  echo "    App B（STRICT）:     ~7-10ms（+5-7ms）"
  echo ""
  echo "  面试知识点:"
  echo "    Q: mTLS 为什么增加延迟？"
  echo "    A: 1) TLS 握手（X.509 证书验证，双向认证）"
  echo "       2) 每个新连接需要完整的握手流程"
  echo "       3: 证书吊销检查（CRL/OCSP，如有启用）"
  echo "       优化: 连接复用（keepalive）、会话恢复（session resumption）"
  echo ""
  echo "    Q: PERMISSIVE vs STRICT 如何选择？"
  echo "    A: 渐进式迁移策略:"
  echo "       Phase 1: 全局 PERMISSIVE（允许明文，兼容旧服务）"
  echo "       Phase 2: 核心服务 STRICT（敏感服务优先）"
  echo "       Phase 3: 全局 STRICT（所有服务强制 mTLS）"
  echo "       关键: 确保所有客户端都配置了 mTLS 再切换 STRICT"
  echo ""
  echo "    Q: Sidecar 模式 vs Sidecar-less 模式？"
  echo "    A: Sidecar 模式（Istio 传统）:"
  echo "       优点: 功能丰富，与业务解耦"
  echo "       缺点: 资源开销大，延迟增加"
  echo ""
  echo "       Sidecar-less 模式（Cilium Ambient Mesh）:"
  echo "       优点: 更低延迟，更少资源"
  echo "       缺点: 功能受限，与 CNI 强绑定"
  echo "=============================================="
}

# 主流程
main() {
  check_prerequisites
  create_cluster
  install_istio
  install_monitoring
  deploy_apps
  verify
}

main "$@"
