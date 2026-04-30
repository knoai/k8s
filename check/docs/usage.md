# 脚本使用手册

## 目录

- [快速入门](#快速入门)
- [主控脚本详解](#主控脚本详解)
- [独立使用检查脚本](#独立使用检查脚本)
- [命令行参数](#命令行参数)
- [环境变量覆盖](#环境变量覆盖)
- [配置文件详解](#配置文件详解)
- [典型使用场景](#典型使用场景)
- [故障排查](#故障排查)

---

## 快速入门

```bash
# 1. 进入项目目录
cd k8s-acceptance/

# 2. 确认 kubectl 已配置
kubectl cluster-info

# 3. 执行验收测试
./run-acceptance.sh

# 4. 查看结果
cat report/acceptance-report-*.md
cat report/acceptance-*.log
```

---

## 主控脚本详解

### 执行流程

```
run-acceptance.sh
├── 加载 config.env（全局配置）
├── 加载 lib/common.sh（公共函数）
├── 解析命令行参数
├── 初始化报告和日志
├── 扫描 checks/ 目录收集检查脚本
├── 遍历执行每个检查脚本（子 shell 隔离）
│   ├── 00-env-check.sh      # 环境预检
│   ├── 10-node-check.sh     # 节点健康
│   ├── 20-core-component.sh # 核心组件
│   ├── ...
│   └── 90-performance-check.sh
├── 汇总结果 → 生成 Markdown 报告
└── 退出前自动清理测试资源
```

### 隔离机制

每个检查脚本在**独立的子 shell** 中执行（`bash "${c}"`），这保证了：
- 一个模块的失败不会影响其他模块
- 模块间变量不互相污染
- 模块的 `exit 1` 不会导致主控脚本退出

### 退出码

| 退出码 | 含义 |
|--------|------|
| 0 | 全部通过 |
| 1 | 至少一个模块失败，或环境异常 |

---

## 独立使用检查脚本

每个检查脚本都可以**独立执行**，便于调试单个模块：

```bash
# 单独执行节点检查
bash checks/10-node-check.sh
```

独立执行时，脚本会自行加载公共库，但**不会**自动创建报告和清理资源。所有输出仅打印到终端。

---

## 命令行参数

```
./run-acceptance.sh [options]

Options:
  --cleanup         仅清理所有测试创建的 Namespace/资源
  --dry-run         预览将要执行的检查清单，不实际运行
  -o, --output DIR  指定报告和日志输出目录（默认: ./report）
  -h, --help        显示帮助信息
```

### --cleanup

```bash
# 清理所有以 k8s-acceptance- 为前缀的测试 Namespace
./run-acceptance.sh --cleanup
```

适用场景：
- 测试中断后手动清理残留
- 日常维护时统一清理历史测试资源

### --dry-run

```bash
# 预览检查清单，验证配置是否正确
./run-acceptance.sh --dry-run
```

适用场景：
- 没有 K8s 集群时验证脚本本身
- 确认模块开关配置是否生效
- CI/CD 流水线中做前置验证

### -o, --output

```bash
# 指定输出目录
./run-acceptance.sh --output /var/log/k8s-acceptance

# 或简写
./run-acceptance.sh -o /var/log/k8s-acceptance
```

目录结构：
```
/var/log/k8s-acceptance/
├── acceptance-report-20240115-093042.md
├── acceptance-20240115-093042.log
```

---

## 环境变量覆盖

所有 `config.env` 中的变量都可以通过**环境变量**在执行时覆盖，优先级：`环境变量 > config.env > 脚本默认值`。

### 覆盖规则

```bash
# 方法 1：单行设置（仅本次生效）
CHECK_PERFORMANCE=true ./run-acceptance.sh

# 方法 2：export 后执行（当前 shell 会话有效）
export CHECK_PERFORMANCE=true
export OPERATOR_LABELS="app=my-operator"
./run-acceptance.sh

# 方法 3：同时覆盖多个变量
CHECK_HA=false CHECK_OPERATOR=true OPERATOR_LABELS="app=my-operator" ./run-acceptance.sh
```

### 常用覆盖示例

```bash
# 场景 1：首次交付验收（全量）
./run-acceptance.sh

# 场景 2：仅验证核心功能
CHECK_PERFORMANCE=false CHECK_HA=false ./run-acceptance.sh

# 场景 3：Operator 专项验收
export OPERATOR_LABELS="app=my-operator,component=controller"
export OPERATOR_CR_LIFECYCLE_TEST=true
./run-acceptance.sh

# 场景 4：保留测试资源用于排查
ACCEPTANCE_CLEANUP=false ./run-acceptance.sh
# 排查完成后手动清理
./run-acceptance.sh --cleanup

# 场景 5：提高 apiserver 延迟阈值（网络较差环境）
APISERVER_LATENCY_MS_MAX=2000 ./run-acceptance.sh

# 场景 6：禁用所有模块，仅执行网络检查
CHECK_ENV=false CHECK_NODE=false CHECK_CORE=false CHECK_STORAGE=false \
CHECK_SCHEDULING=false CHECK_SECURITY=false CHECK_HA=false \
CHECK_OPERATOR=false CHECK_PERFORMANCE=false \
CHECK_NETWORK=true ./run-acceptance.sh
```

---

## 配置文件详解

### config.env 结构

```bash
# ==================== 开关配置 ====================
# 各模块是否执行（true/false）
CHECK_ENV=true
CHECK_NODE=true
...

# ==================== 超时配置（秒） ====================
TIMEOUT_POD_READY=120
...

# ==================== 阈值配置 ====================
NODE_READY_MIN_RATIO=1.0
...

# ==================== Operator 配置 ====================
OPERATOR_LABELS=""
...

# ==================== 性能测试配置 ====================
PERF_NETWORK_CONNECTIONS=4
...

# ==================== 其他 ====================
ACCEPTANCE_CLEANUP=true
```

### 配置项对照表

| 配置项 | 类型 | 默认值 | 说明 |
|--------|------|--------|------|
| `CHECK_ENV` | bool | `true` | 环境预检开关 |
| `CHECK_NODE` | bool | `true` | 节点健康检查开关 |
| `CHECK_CORE` | bool | `true` | 核心组件检查开关 |
| `CHECK_NETWORK` | bool | `true` | 网络功能检查开关 |
| `CHECK_STORAGE` | bool | `true` | 存储供给检查开关 |
| `CHECK_SCHEDULING` | bool | `true` | 调度策略检查开关 |
| `CHECK_SECURITY` | bool | `true` | 安全基线检查开关 |
| `CHECK_HA` | bool | `true` | 高可用检查开关 |
| `CHECK_OPERATOR` | bool | `true` | Operator/CRD 检查开关 |
| `CHECK_PERFORMANCE` | bool | `false` | 性能基准测试开关 |
| `TIMEOUT_POD_READY` | int | `120` | Pod 就绪等待超时（秒） |
| `TIMEOUT_DEPLOYMENT_READY` | int | `180` | Deployment 就绪等待超时（秒） |
| `TIMEOUT_JOB_COMPLETE` | int | `180` | Job 完成等待超时（秒） |
| `TIMEOUT_PVC_BIND` | int | `120` | PVC 绑定等待超时（秒） |
| `TIMEOUT_OPERATOR_CR` | int | `300` | Operator CR Ready 等待超时（秒） |
| `NODE_READY_MIN_RATIO` | float | `1.0` | 节点最低 Ready 率（0~1） |
| `APISERVER_LATENCY_MS_MAX` | int | `500` | apiserver 响应延迟阈值（毫秒） |
| `ETCD_HEALTHY_MIN` | int | `1` | etcd 成员最低健康数 |
| `CORE_POD_READY_MIN_RATIO` | float | `1.0` | 核心组件 Pod 最低 Ready 率 |
| `OPERATOR_LABELS` | string | `""` | Operator Pod 标签选择器 |
| `OPERATOR_CR_LIFECYCLE_TEST` | bool | `true` | 是否执行 CR 生命周期测试 |
| `PERF_NETWORK_CONNECTIONS` | int | `4` | iperf3 并发连接数 |
| `PERF_NETWORK_DURATION` | int | `10` | iperf3 测试持续时间（秒） |
| `PERF_STORAGE_FILE_SIZE` | string | `1G` | fio 测试文件大小 |
| `PERF_SCHEDULING_PODS` | int | `50` | 调度压测并发 Pod 数 |
| `ACCEPTANCE_CLEANUP` | bool | `true` | 测试结束后是否自动清理 |
| `TEST_NS_PREFIX` | string | `k8s-acceptance` | 测试 Namespace 前缀 |

---

## 典型使用场景

### 场景一：新集群交付验收

```bash
# 全量检查，启用性能基准
CHECK_PERFORMANCE=true ./run-acceptance.sh --output /data/acceptance/new-cluster-01
```

### 场景二：升级后回归验证

```bash
# 核心功能快速验证，跳过耗时性能测试
CHECK_PERFORMANCE=false ./run-acceptance.sh
```

### 场景三：Operator 发布验收

```bash
# 1. 配置 Operator 标签
cat >> config.env <<EOF
OPERATOR_LABELS="app=my-operator"
OPERATOR_CR_LIFECYCLE_TEST=true
EOF

# 2. 准备示例 CR
cat > manifests/operator-test/sample-cr.yaml <<EOF
apiVersion: myapp.example.com/v1
kind: MyApp
metadata:
  name: test-instance
spec:
  replicas: 1
  image: myapp:v1.0.0
EOF

# 3. 执行验收
./run-acceptance.sh
```

### 场景四：CI/CD 集成

```bash
#!/bin/bash
set -euo pipefail

# 1. 安装 kubectl（如需要）
# 2. 配置 kubeconfig
# 3. 执行验收
if ! ./run-acceptance.sh --output "./artifacts"; then
    echo "验收测试失败"
    cat ./artifacts/acceptance-report-*.md
    exit 1
fi

# 4. 上传报告到存储（如 S3、Artifactory）
# aws s3 cp ./artifacts/ s3://bucket/acceptance/$(date +%Y%m%d)/ --recursive
```

### 场景五：多集群批量验收

```bash
#!/bin/bash
for cluster in cluster-a cluster-b cluster-c; do
    export KUBECONFIG="/path/to/${cluster}.kubeconfig"
    ./run-acceptance.sh --output "./reports/${cluster}" || true
done
```

---

## 故障排查

### 问题 1：`kubectl cluster-info` 失败

```
[FAIL]  无法连接集群
```

排查步骤：
1. 检查 kubeconfig 文件是否存在：`ls ~/.kube/config`
2. 检查当前上下文：`kubectl config current-context`
3. 检查集群可达性：`kubectl cluster-info --v=6`

### 问题 2：权限不足

```
[FAIL]  list nodes: no, list pods: no
```

排查步骤：
1. 确认当前用户有集群管理员权限
2. 检查 RBAC：`kubectl auth can-i '*' '*' --all-namespaces`

### 问题 3：模块执行超时

```
[FAIL]  网络测试 Pod 未就绪
```

排查步骤：
1. 查看 Pod 状态：`kubectl get pod -n k8s-acceptance-xxx`
2. 查看 Pod 事件：`kubectl describe pod <pod> -n k8s-acceptance-xxx`
3. 查看日志：`kubectl logs <pod> -n k8s-acceptance-xxx`
4. 延长超时时间：`TIMEOUT_POD_READY=300 ./run-acceptance.sh`

### 问题 4：测试资源残留

```bash
# 手动查找测试 Namespace
kubectl get ns | grep k8s-acceptance

# 手动删除
kubectl delete ns k8s-acceptance-xxx

# 或使用脚本清理
./run-acceptance.sh --cleanup
```

### 问题 5：日志文件为空

- 确认 `init_report()` 已调用（正常执行时自动调用）
- 检查 `--dry-run` 模式下日志会被自动清理（预期行为）
- 检查 `--output` 指定的目录是否有写权限
