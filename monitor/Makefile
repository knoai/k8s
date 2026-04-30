# Kubernetes 全链路监控部署脚本
# 一键部署核心监控组件

.PHONY: all namespace prometheus loki tempo otel grafana hubble clean status

NAMESPACE := monitoring
HELM_TIMEOUT := 600s

all: namespace prometheus loki tempo otel grafana

# 创建命名空间
namespace:
	@echo "=== 创建监控命名空间 ==="
	kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -

# 添加 Helm Charts
add-repos:
	@echo "=== 添加 Helm 仓库 ==="
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo add grafana https://grafana.github.io/helm-charts
	helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
	helm repo add cilium https://helm.cilium.io/
	helm repo update

# 部署 Prometheus + Alertmanager + kube-state-metrics + node-exporter
prometheus: namespace add-repos
	@echo "=== 部署 Prometheus Stack ==="
	helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
		--namespace $(NAMESPACE) \
		--set prometheus.prometheusSpec.retention=15d \
		--set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=50Gi \
		--set alertmanager.alertmanagerSpec.retention=120h \
		--set grafana.enabled=false \
		--timeout $(HELM_TIMEOUT)

# 部署 Loki
loki: namespace add-repos
	@echo "=== 部署 Loki ==="
	helm upgrade --install loki grafana/loki \
		--namespace $(NAMESPACE) \
		--set persistence.enabled=true \
		--set persistence.size=50Gi \
		--set resources.limits.memory=4Gi \
		--timeout $(HELM_TIMEOUT)

# 部署 Tempo
tempo: namespace add-repos
	@echo "=== 部署 Tempo ==="
	helm upgrade --install tempo grafana/tempo \
		--namespace $(NAMESPACE) \
		--set tempo.storage.trace.backend=local \
		--set persistence.enabled=true \
		--set persistence.size=20Gi \
		--timeout $(HELM_TIMEOUT)

# 部署 OpenTelemetry Collector
otel: namespace
	@echo "=== 部署 OpenTelemetry Collector ==="
	kubectl apply -f manifests/otel-collector.yaml

# 部署 Grafana（独立的，与 kube-prometheus-stack 分开）
grafana: namespace add-repos
	@echo "=== 部署 Grafana ==="
	helm upgrade --install grafana grafana/grafana \
		--namespace $(NAMESPACE) \
		--set datasources.\"datasources.yaml\".apiVersion=1 \
		--set datasources.\"datasources.yaml\".datasources[0].name=Prometheus \
		--set datasources.\"datasources.yaml\".datasources[0].type=prometheus \
		--set datasources.\"datasources.yaml\".datasources[0].url=http://prometheus-kube-p-prometheus:9090 \
		--set datasources.\"datasources.yaml\".datasources[1].name=Loki \
		--set datasources.\"datasources.yaml\".datasources[1].type=loki \
		--set datasources.\"datasources.yaml\".datasources[1].url=http://loki:3100 \
		--set datasources.\"datasources.yaml\".datasources[2].name=Tempo \
		--set datasources.\"datasources.yaml\".datasources[2].type=tempo \
		--set datasources.\"datasources.yaml\".datasources[2].url=http://tempo:3100 \
		--timeout $(HELM_TIMEOUT)

# 部署 Hubble eBPF（需要已安装 Cilium）
hubble:
	@echo "=== 启用 Cilium Hubble ==="
	helm upgrade cilium cilium/cilium \
		--namespace kube-system \
		--reuse-values \
		--set hubble.relay.enabled=true \
		--set hubble.ui.enabled=true \
		--set hubble.metrics.enabled="{dns:query,drop,tcp,flow,icmp,http}" \
		--set prometheus.enabled=true

# 应用告警规则
apply-rules:
	@echo "=== 应用 Prometheus 告警规则 ==="
	kubectl apply -f rules/prometheus-alerts.yaml

# 查看部署状态
status:
	@echo "=== 监控组件状态 ==="
	@echo "\nPods:"
	kubectl get pods -n $(NAMESPACE)
	@echo "\nServices:"
	kubectl get svc -n $(NAMESPACE)

# 获取 Grafana 密码
grafana-password:
	@echo "=== Grafana admin 密码 ==="
	kubectl get secret --namespace $(NAMESPACE) grafana -o jsonpath="{.data.admin-password}" | base64 --decode ; echo

# 端口转发 Grafana
port-forward-grafana:
	@echo "=== 转发 Grafana 到 localhost:3000 ==="
	kubectl port-forward svc/grafana 3000:80 -n $(NAMESPACE)

# 端口转发 Prometheus
port-forward-prometheus:
	@echo "=== 转发 Prometheus 到 localhost:9090 ==="
	kubectl port-forward svc/prometheus-kube-p-prometheus 9090:9090 -n $(NAMESPACE)

# 清理
clean:
	@echo "=== 清理监控组件 ==="
	helm uninstall prometheus -n $(NAMESPACE) || true
	helm uninstall loki -n $(NAMESPACE) || true
	helm uninstall tempo -n $(NAMESPACE) || true
	helm uninstall grafana -n $(NAMESPACE) || true
	kubectl delete -f manifests/ -n $(NAMESPACE) || true
	kubectl delete namespace $(NAMESPACE) || true

# 帮助
help:
	@echo "Kubernetes 全链路监控部署"
	@echo ""
	@echo "可用目标:"
	@echo "  make all          - 部署全部核心组件"
	@echo "  make namespace    - 创建监控命名空间"
	@echo "  make prometheus   - 部署 Prometheus + Alertmanager"
	@echo "  make loki         - 部署 Loki 日志系统"
	@echo "  make tempo        - 部署 Tempo 链路追踪"
	@echo "  make otel         - 部署 OpenTelemetry Collector"
	@echo "  make grafana      - 部署 Grafana 可视化"
	@echo "  make hubble       - 启用 Cilium Hubble eBPF"
	@echo "  make apply-rules  - 应用告警规则"
	@echo "  make status       - 查看组件状态"
	@echo "  make grafana-password - 获取 Grafana 密码"
	@echo "  make clean        - 清理所有组件"
