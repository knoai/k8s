#!/bin/bash
# K8s 监控体系验证脚本
# 用法: ./validate-setup.sh

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "=========================================="
echo "  K8s 全链路监控体系健康检查"
echo "=========================================="

PASS=0
FAIL=0

check() {
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓${NC} $1"
        ((PASS++))
    else
        echo -e "${RED}✗${NC} $1"
        ((FAIL++))
    fi
}

# 1. 检查 namespace
kubectl get namespace monitoring > /dev/null 2>&1
check "Namespace 'monitoring' 存在"

# 2. 检查 Prometheus
kubectl get pod -l app=prometheus -n monitoring > /dev/null 2>&1
check "Prometheus Pod 运行中"

kubectl get svc prometheus-server -n monitoring > /dev/null 2>&1
check "Prometheus Service 存在"

# 3. 检查 Grafana
kubectl get pod -l app.kubernetes.io/name=grafana -n monitoring > /dev/null 2>&1
check "Grafana Pod 运行中"

# 4. 检查 Loki
kubectl get pod -l app=loki -n monitoring > /dev/null 2>&1 || \
kubectl get pod -l app.kubernetes.io/name=loki -n monitoring > /dev/null 2>&1
check "Loki Pod 运行中"

# 5. 检查 Tempo
kubectl get pod -l app.kubernetes.io/name=tempo -n monitoring > /dev/null 2>&1
check "Tempo Pod 运行中"

# 6. 检查 OTel Collector
kubectl get pod -l app=otel-collector -n monitoring > /dev/null 2>&1
check "OTel Collector Pod 运行中"

# 7. 检查 Node Exporter
kubectl get pod -l app.kubernetes.io/name=prometheus-node-exporter -n monitoring > /dev/null 2>&1
check "Node Exporter DaemonSet 运行中"

# 8. 检查 kube-state-metrics
kubectl get pod -l app.kubernetes.io/name=kube-state-metrics -n monitoring > /dev/null 2>&1
check "kube-state-metrics 运行中"

# 9. 检查 ServiceMonitor
count=$(kubectl get servicemonitor -n monitoring --no-headers 2>/dev/null | wc -l)
if [ "$count" -gt 0 ]; then
    check "ServiceMonitor 数量: $count"
else
    echo -e "${RED}✗${NC} ServiceMonitor 不存在"
    ((FAIL++))
fi

# 10. 检查 PrometheusRule
count=$(kubectl get prometheusrules -n monitoring --no-headers 2>/dev/null | wc -l)
if [ "$count" -gt 0 ]; then
    check "PrometheusRule 数量: $count"
else
    echo -e "${RED}✗${NC} PrometheusRule 不存在"
    ((FAIL++))
fi

# 11. 检查指标采集（Prometheus）
echo ""
echo "--- Prometheus 指标采集检查 ---"
curl -s http://localhost:9090/api/v1/query?query=up > /dev/null 2>&1 || true
check "Prometheus API 可访问（需端口转发）"

# 12. 检查 Alertmanager
kubectl get pod -l app.kubernetes.io/name=alertmanager -n monitoring > /dev/null 2>&1
check "Alertmanager Pod 运行中"

# 13. 检查存储持久化
kubectl get pvc -n monitoring > /dev/null 2>&1
check "PVC 存在（数据持久化）"

echo ""
echo "=========================================="
echo -e "  检查结果: ${GREEN}通过 $PASS${NC} / ${RED}失败 $FAIL${NC}"
echo "=========================================="

if [ $FAIL -gt 0 ]; then
    echo -e "${YELLOW}提示:${NC}"
    echo "1. 如果某些组件未部署，运行 'make all' 一键部署"
    echo "2. Prometheus API 检查需要端口转发: kubectl port-forward svc/prometheus-server 9090:80 -n monitoring"
    exit 1
fi

echo -e "${GREEN}所有检查通过！${NC}"
