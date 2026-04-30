#!/bin/bash
# 多集群延迟差异实验 - 集群部署脚本
# 部署两个 Kind 集群: Cluster A（健康基线）和 Cluster B（问题配置）
# 用于 platform-engineering-lab 项目 2
# 
# 问题注入说明:
#   Cluster B 模拟了生产环境中常见的配置错误:
#   1. CoreDNS 单副本（节点扩容后未同步扩容）
#   2. 节点数量少（单 worker 节点，无高可用）
#   3. 资源竞争（control-plane 和 worker 共享节点资源）
#
# 预期学习效果:
#   通过对比两个集群的诊断输出，理解 DNS、CNI、节点资源
#   对延迟的影响，掌握分层排查法。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================="
echo "  多集群延迟差异实验 - 集群部署"
echo "  预计时间: 5-8 分钟"
echo "=============================================="
echo ""
echo "本脚本将创建两个 Kind 集群用于对比实验:"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Cluster A: 健康基线（正确配置）         │"
echo "  │    - 3 节点: 1 control-plane + 2 worker │"
echo "  │    - CoreDNS: 2 副本（高可用）          │"
echo "  │    - CNI: kind 默认 kindnetd            │"
echo "  │    - 应用: httpbin 作为测试服务         │"
echo "  │    - 访问: http://localhost:8080        │"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  ┌─────────────────────────────────────────┐"
echo "  │  Cluster B: 问题集群（配置错误）         │"
echo "  │    - 2 节点: 1 control-plane + 1 worker │"
echo "  │    - CoreDNS: 1 副本（单点瓶颈）        │"
echo "  │    - CNI: kind 默认 kindnetd            │"
echo "  │    - 应用: httpbin 作为测试服务         │"
echo "  │    - 访问: http://localhost:8082        │"
echo "  └─────────────────────────────────────────┘"
echo ""
echo "  预期差异:"
echo "    DNS 层: Cluster B 解析延迟更高（CoreDNS 单点）"
echo "    节点层: Cluster B 资源更紧张（节点少）"
echo "    应用层: 两者应用相同，用于隔离变量"
echo ""

# 检查前置条件
check_prerequisites() {
  echo "=== 检查前置条件 ==="
  local missing=()
  
  for cmd in docker kind kubectl; do
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
    echo ""
    echo "安装指南:"
    echo "  Docker:  https://docs.docker.com/get-docker/"
    echo "  Kind:    curl -Lo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64"
    echo "  Kubectl: https://kubernetes.io/docs/tasks/tools/"
    exit 1
  fi
  
  # 检查 Docker 运行状态
  if ! docker info &>/dev/null; then
    echo ""
    echo "错误: Docker 守护进程未运行"
    exit 1
  fi
  
  echo ""
}

# 创建 Cluster A（健康基线）
create_cluster_a() {
  echo "=== 创建 Cluster A（健康基线）==="
  if kind get clusters | grep -q "^cluster-a$"; then
    echo "集群 cluster-a 已存在，跳过创建"
    echo "  如需重建，请先运行: kind delete cluster --name cluster-a"
    kubectl config use-context kind-cluster-a 2>/dev/null || true
    return
  fi
  
  cat > /tmp/kind-cluster-a.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cluster-a
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8080
    protocol: TCP
  - containerPort: 30081
    hostPort: 8081
    protocol: TCP
- role: worker
- role: worker
EOF

  echo "  创建 3 节点集群..."
  kind create cluster --config /tmp/kind-cluster-a.yaml
  
  # 部署示例应用
  echo "  在 Cluster A 部署 httpbin 测试应用..."
  kubectl create namespace latency-lab --dry-run=client -o yaml | kubectl apply -f -
  
  cat > /tmp/app-a.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-a
  namespace: latency-lab
spec:
  replicas: 2
  selector:
    matchLabels:
      app: app-a
  template:
    metadata:
      labels:
        app: app-a
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: app-a
  namespace: latency-lab
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
  
  echo "  等待应用就绪..."
  kubectl wait --for=condition=ready pod -l app=app-a -n latency-lab --timeout=120s
  
  echo "  ✓ Cluster A 创建完成"
  echo "    访问地址: http://localhost:8080/get"
  echo ""
}

# 创建 Cluster B（问题配置）
create_cluster_b() {
  echo "=== 创建 Cluster B（问题配置）==="
  if kind get clusters | grep -q "^cluster-b$"; then
    echo "集群 cluster-b 已存在，跳过创建"
    echo "  如需重建，请先运行: kind delete cluster --name cluster-b"
    kubectl config use-context kind-cluster-b 2>/dev/null || true
    return
  fi
  
  cat > /tmp/kind-cluster-b.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: cluster-b
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 8082
    protocol: TCP
  - containerPort: 30081
    hostPort: 8083
    protocol: TCP
- role: worker
EOF

  echo "  创建 2 节点集群..."
  kind create cluster --config /tmp/kind-cluster-b.yaml
  
  # 部署示例应用
  echo "  在 Cluster B 部署 httpbin 测试应用..."
  kubectl create namespace latency-lab --dry-run=client -o yaml | kubectl apply -f -
  
  cat > /tmp/app-b.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app-b
  namespace: latency-lab
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
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        resources:
          limits:
            memory: "128Mi"
            cpu: "100m"
---
apiVersion: v1
kind: Service
metadata:
  name: app-b
  namespace: latency-lab
spec:
  selector:
    app: app-b
  ports:
  - port: 80
    targetPort: 80
    nodePort: 30080
  type: NodePort
EOF
  kubectl apply -f /tmp/app-b.yaml
  
  # 模拟问题: 缩减 CoreDNS 到 1 副本
  echo ""
  echo "  ┌──────────────────────────────────────────┐"
  echo "  │  注入问题: CoreDNS 缩减到 1 副本         │"
  echo "  │                                          │"
  echo "  │  生产场景: 集群从 3 节点扩展到 10 节点   │"
  echo "  │  运维忘记同步扩容 CoreDNS，仍为 2 副本   │"
  echo "  │  在 10 节点集群中，2 副本成为瓶颈        │"
  echo "  │                                          │"
  echo "  │  本实验模拟更极端情况: 2 节点只有 1 副本 │"
  echo "  │  预期: DNS 查询排队，解析延迟增加        │"
  echo "  └──────────────────────────────────────────┘"
  echo ""
  
  kubectl scale deployment coredns -n kube-system --replicas=1
  
  echo "  等待应用就绪..."
  kubectl wait --for=condition=ready pod -l app=app-b -n latency-lab --timeout=120s
  
  echo "  ✓ Cluster B 创建完成（含问题配置）"
  echo "    访问地址: http://localhost:8082/get"
  echo ""
}

# 安装 metrics-server
install_metrics() {
  echo "=== 安装 metrics-server ==="
  
  for ctx in kind-cluster-a kind-cluster-b; do
    if kubectl config get-contexts "$ctx" &>/dev/null; then
      kubectl config use-context "$ctx"
      if ! kubectl top nodes &>/dev/null; then
        echo "  在 $ctx 上安装 metrics-server..."
        kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
        kubectl patch deployment metrics-server -n kube-system --type='json' \
          -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
        echo "  等待 metrics-server 就绪..."
        sleep 15
        kubectl wait --for=condition=ready pod -l k8s-app=metrics-server -n kube-system --timeout=120s 2>/dev/null || true
      else
        echo "  $ctx metrics-server 已安装"
      fi
    fi
  done
  
  echo "  ✓ metrics-server 安装完成"
  echo ""
}

# 验证部署
verify() {
  echo "=============================================="
  echo "  验证部署"
  echo "=============================================="
  echo ""
  
  echo "--- Cluster A ---"
  kubectl config use-context kind-cluster-a
  echo "节点状态:"
  kubectl get nodes -o wide
  echo ""
  echo "系统 Pod:"
  kubectl get pods -n kube-system
  echo ""
  echo "CoreDNS 副本数:"
  kubectl get deployment coredns -n kube-system -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'
  echo ""
  echo ""
  echo "应用 Pod:"
  kubectl get pods -n latency-lab -o wide
  echo ""
  echo "应用服务:"
  kubectl get svc -n latency-lab
  echo ""
  
  echo "--- Cluster B ---"
  kubectl config use-context kind-cluster-b
  echo "节点状态:"
  kubectl get nodes -o wide
  echo ""
  echo "系统 Pod:"
  kubectl get pods -n kube-system
  echo ""
  echo "CoreDNS 副本数:"
  kubectl get deployment coredns -n kube-system -o jsonpath='{.status.readyReplicas}/{.spec.replicas}'
  echo ""
  echo ""
  echo "应用 Pod:"
  kubectl get pods -n latency-lab -o wide
  echo ""
  echo "应用服务:"
  kubectl get svc -n latency-lab
  echo ""
  
  echo "=============================================="
  echo "  集群部署完成"
  echo ""
  echo "  访问地址:"
  echo "    Cluster A: http://localhost:8080/get"
  echo "    Cluster B: http://localhost:8082/get"
  echo ""
  echo "  快速测试:"
  echo "    # Cluster A - 多次请求观察延迟"
  echo "    for i in {1..5}; do"
  echo "      curl -w \"Time: %{time_total}s\\n\" -o /dev/null -s http://localhost:8080/get"
  echo "    done"
  echo ""
  echo "    # Cluster B - 对比延迟"
  echo "    for i in {1..5}; do"
  echo "      curl -w \"Time: %{time_total}s\\n\" -o /dev/null -s http://localhost:8082/get"
  echo "    done"
  echo ""
  echo "  运行诊断:"
  echo "    ./diagnose-cluster.sh    # 全面对比诊断"
  echo ""
  echo "  面试知识点:"
  echo "    Q: CoreDNS 副本数如何计算？"
  echo "    A: 建议公式: max(2, ceil(节点数 / 10))"
  echo "       例如: 5 节点 → 2 副本, 20 节点 → 2 副本, 50 节点 → 5 副本"
  echo ""
  echo "    Q: DNS 解析慢的排查步骤？"
  echo "    A: 1) 检查 /etc/resolv.conf 的 ndots 配置"
  echo "       2) 测试 CoreDNS 直接解析: nslookup <svc>.<ns>.svc.cluster.local"
  echo "       3) 检查 CoreDNS 资源使用（CPU/内存是否饱和）"
  echo "       4) 检查 CoreDNS 日志是否有大量 upstream 超时"
  echo "       5) 检查节点上的 iptables 规则是否导致 DNS 包丢失"
  echo ""
  echo "    Q: Kind 集群的局限性？"
  echo "    A: 1) 节点是 Docker 容器，非真实 VM"
  echo "       2) 网络性能不代表生产环境（共享宿主机内核）"
  echo "       3) 适合功能验证，不适合性能基准"
  echo "       4) 生产环境建议在云实例或裸机上复现"
  echo "=============================================="
}

# 清理函数（可通过 --cleanup 调用）
cleanup() {
  echo "=== 清理集群 ==="
  kind delete cluster --name cluster-a 2>/dev/null || true
  kind delete cluster --name cluster-b 2>/dev/null || true
  echo "✓ 清理完成"
}

# 主流程
main() {
  # 支持 --cleanup 参数
  if [ "${1:-}" = "--cleanup" ]; then
    cleanup
    exit 0
  fi
  
  check_prerequisites
  create_cluster_a
  create_cluster_b
  install_metrics
  verify
}

main "$@"
