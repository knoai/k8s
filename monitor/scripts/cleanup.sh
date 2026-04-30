#!/bin/bash
# 清理监控环境（谨慎使用！）

set -e

echo "=========================================="
echo "  ⚠️  清理监控环境"
echo "=========================================="
echo "此脚本将删除以下资源:"
echo "  - namespace: monitoring, observability-demo, jvm-demo, microservices"
echo "  - Helm releases: prometheus, grafana, loki, tempo, victoria-metrics"
echo ""
read -p "确认删除? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
    echo "已取消"
    exit 0
fi

echo "开始清理..."

# 删除 Helm releases
helm uninstall prometheus -n monitoring 2>/dev/null || true
helm uninstall grafana -n monitoring 2>/dev/null || true
helm uninstall loki -n monitoring 2>/dev/null || true
helm uninstall tempo -n monitoring 2>/dev/null || true
helm uninstall victoria-metrics -n monitoring 2>/dev/null || true
helm uninstall pyroscope -n monitoring 2>/dev/null || true
helm uninstall grafana-operator -n monitoring 2>/dev/null || true

# 删除 namespaces
kubectl delete namespace monitoring --ignore-not-found=true
kubectl delete namespace observability --ignore-not-found=true
kubectl delete namespace observability-demo --ignore-not-found=true
kubectl delete namespace jvm-demo --ignore-not-found=true
kubectl delete namespace correlation-demo --ignore-not-found=true
kubectl delete namespace microservices --ignore-not-found=true
kubectl delete namespace hubble --ignore-not-found=true

# 删除 CRDs（可选，谨慎！）
# kubectl delete crd alertmanagerconfigs.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd alertmanagers.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd podmonitors.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd probes.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd prometheusagents.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd prometheuses.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd prometheusrules.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd scrapeconfigs.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd servicemonitors.monitoring.coreos.com 2>/dev/null || true
# kubectl delete crd thanosrulers.monitoring.coreos.com 2>/dev/null || true

echo ""
echo "=========================================="
echo "  ✅ 清理完成"
echo "=========================================="
