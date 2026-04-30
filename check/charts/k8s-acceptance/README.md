# k8s-acceptance Helm Chart

将 [K8s 集群一键验收测试工具](../../README.md) 容器化后，以 Helm Chart 形式部署到集群内运行。

## 特性

- **Job / CronJob 双模式**：一次性验收或定时巡检
- **ConfigMap 驱动配置**：所有验收开关、阈值通过 Helm Values 注入，无需重建镜像
- **RBAC 最小化**：自动创建 ServiceAccount + ClusterRole，覆盖测试所需权限
- **报告持久化**：支持 EmptyDir（默认）或 PVC 留存验收报告
- **自定义 CR 支持**：可通过 Values 传入 Operator 专项测试所需的自定义 CR

## 快速开始

### 1. 构建镜像

```bash
cd check/
docker build -t k8s-acceptance:0.1.0 .
```

> 如需推送至私有仓库，请修改 `values.yaml` 中的 `image.repository` 与 `image.tag`。

### 2. 安装 Chart（一次性验收）

```bash
helm install acceptance-test ./charts/k8s-acceptance \
  --namespace k8s-acceptance \
  --create-namespace
```

### 3. 查看验收结果

```bash
# 查看实时日志
kubectl logs -n k8s-acceptance job/acceptance-test-k8s-acceptance -f

# Job 完成后复制报告到本地（若使用 EmptyDir，需在 ttl 内操作）
kubectl cp -n k8s-acceptance \
  acceptance-test-k8s-acceptance-xxxxx:/opt/k8s-acceptance/report \
  ./report
```

### 4. 卸载

```bash
helm uninstall acceptance-test -n k8s-acceptance
```

## 常用场景

### 场景 A：仅执行核心检查（跳过性能与 HA）

```bash
helm install acceptance-test ./charts/k8s-acceptance \
  --namespace k8s-acceptance --create-namespace \
  --set config.checkHa=false \
  --set config.checkPerformance=false
```

### 场景 B：定时巡检（CronJob）

```bash
helm install acceptance-cron ./charts/k8s-acceptance \
  --namespace k8s-acceptance --create-namespace \
  --set job.enabled=false \
  --set cronjob.enabled=true \
  --set cronjob.schedule="0 2 * * 1" \
  --set report.persistence.enabled=true \
  --set report.persistence.storageClass=standard
```

### 场景 C：Operator/CRD 专项验收

```bash
helm install acceptance-test ./charts/k8s-acceptance \
  --namespace k8s-acceptance --create-namespace \
  --set config.operatorLabels="app=my-operator,component=controller" \
  --set customManifests.enabled=true \
  --set-string customManifests.sampleCR=$'apiVersion: example.com/v1\nkind: MyResource\nmetadata:\n  name: test-cr\nspec:\n  replicas: 1'
```

### 场景 D：保留测试资源用于排障

```bash
helm install acceptance-test ./charts/k8s-acceptance \
  --namespace k8s-acceptance --create-namespace \
  --set config.acceptanceCleanup=false
```

## Values 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `image.repository` | 镜像仓库 | `k8s-acceptance` |
| `image.tag` | 镜像标签 | `""`（默认使用 Chart.AppVersion） |
| `job.enabled` | 启用一次性 Job | `true` |
| `cronjob.enabled` | 启用 CronJob（启用后 Job 失效） | `false` |
| `cronjob.schedule` | CronJob 调度表达式 | `0 2 * * *` |
| `config.checkEnv` ~ `config.checkPerformance` | 各检查模块开关 | 详见 [values.yaml](values.yaml) |
| `config.acceptanceCleanup` | 测试后是否自动清理资源 | `true` |
| `customManifests.enabled` | 启用自定义 CR | `false` |
| `customManifests.sampleCR` | 自定义 CR YAML 内容 | 空 |
| `report.persistence.enabled` | 报告使用 PVC 持久化 | `false` |
| `report.persistence.storageClass` | PVC StorageClass | `""` |
| `rbac.extraRules` | 额外 RBAC 规则 | `[]` |

更多参数请参考 [values.yaml](values.yaml)。

## 注意事项

1. **权限范围**：Chart 默认创建 `ClusterRole`，因验收测试需要读取 Nodes、跨 Namespace 操作 Pod 等资源。如仅需 Namespace 级别测试，可手动修改 `templates/rbac.yaml`。
2. **报告获取**：默认使用 `EmptyDir`，Job Pod 在 `ttlSecondsAfterFinished`（默认 24h）后会被删除，请及时通过 `kubectl cp` 或日志获取报告。
3. **并发安全**：若启用 CronJob，建议保持 `concurrencyPolicy: Forbid`，避免多次验收测试的资源冲突。
