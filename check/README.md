# K8s 集群一键测试验收方案

📖 [脚本使用手册](docs/usage.md) | 🔧 [功能说明文档](docs/features.md) | 📚 [学习指南](docs/learning.md)

## 快速开始

```bash
# 1. 确保已配置 kubeconfig 且 kubectl 可正常访问目标集群
kubectl cluster-info

# 2. 执行验收测试
./run-acceptance.sh

# 3. 查看生成的报告与日志
cat report/acceptance-report-*.md
cat report/acceptance-*.log
```

## 目录结构

```
.
├── run-acceptance.sh          # 一键执行入口
├── config.env                 # 配置参数（开关、阈值、超时）
├── lib/
│   ├── common.sh              # 公共函数库（日志、报告、清理）
│   └── k8s-utils.sh           # K8s 操作封装
├── checks/
│   ├── 00-env-check.sh        # 环境预检
│   ├── 10-node-check.sh       # 节点健康
│   ├── 20-core-component.sh   # 核心组件
│   ├── 30-network-check.sh    # 网络功能
│   ├── 40-storage-check.sh    # 存储供给
│   ├── 50-scheduling-check.sh # 调度策略
│   ├── 60-security-check.sh   # 安全基线
│   ├── 70-ha-check.sh         # 高可用
│   ├── 80-operator-crd.sh     # Operator/CRD 专项
│   └── 90-performance-check.sh# 性能基准
├── manifests/                 # 测试用 K8s 资源
│   ├── network-test/
│   ├── storage-test/
│   ├── scheduling-test/
│   ├── security-test/
│   └── operator-test/
└── report/                    # 验收报告与日志输出目录
```

## 命令行选项

```bash
./run-acceptance.sh [options]

选项:
  --cleanup         仅清理所有测试创建的 Namespace/资源
  --dry-run         预览将要执行的检查清单，不实际运行
  -o, --output DIR  指定报告和日志输出目录（默认: ./report）
  -h, --help        显示帮助
```

## 使用场景示例

### 场景 1：首次验收（全量检查）

```bash
./run-acceptance.sh
```

执行全部 10 个检查模块，输出报告到 `report/` 目录。

### 场景 2：仅验证核心功能（跳过性能与 HA）

```bash
CHECK_PERFORMANCE=false CHECK_HA=false ./run-acceptance.sh
```

### 场景 3：指定报告输出目录

```bash
./run-acceptance.sh --output /var/log/k8s-acceptance
```

### 场景 4：预览检查清单（不实际操作集群）

```bash
./run-acceptance.sh --dry-run
```

输出示例：
```
[INFO]  [DRY-RUN] 将执行以下检查:
  [执行] 00-env-check
  [执行] 10-node-check
  [执行] 20-core-component
  [跳过] 90-performance-check (已禁用)
```

### 场景 5：仅清理历史测试资源

```bash
./run-acceptance.sh --cleanup
```

清理所有以 `k8s-acceptance-` 为前缀的测试 Namespace。

### 场景 6：Operator/CRD 专项验收

```bash
# 配置 Operator 标签选择器
export OPERATOR_LABELS="app=my-operator,component=controller"

# 在 manifests/operator-test/sample-cr.yaml 中填写实际 CR
vim manifests/operator-test/sample-cr.yaml

# 执行验收
./run-acceptance.sh
```

## 配置说明

编辑 `config.env` 或在执行前通过环境变量覆盖：

| 变量 | 说明 | 默认值 |
|------|------|--------|
| `CHECK_ENV` | 环境预检 | `true` |
| `CHECK_NODE` | 节点健康检查 | `true` |
| `CHECK_CORE` | 核心组件检查 | `true` |
| `CHECK_NETWORK` | 网络功能检查 | `true` |
| `CHECK_STORAGE` | 存储供给检查 | `true` |
| `CHECK_SCHEDULING` | 调度策略检查 | `true` |
| `CHECK_SECURITY` | 安全基线检查 | `true` |
| `CHECK_HA` | 高可用检查 | `true` |
| `CHECK_OPERATOR` | Operator/CRD 检查 | `true` |
| `CHECK_PERFORMANCE` | 性能基准测试 | `false` |
| `OPERATOR_LABELS` | Operator Pod 标签选择器 | `""` |
| `OPERATOR_CR_LIFECYCLE_TEST` | 是否执行 CR 生命周期测试 | `true` |
| `TIMEOUT_POD_READY` | Pod 就绪超时（秒） | `120` |
| `TIMEOUT_PVC_BIND` | PVC 绑定超时（秒） | `120` |
| `NODE_READY_MIN_RATIO` | 节点最低 Ready 率 | `1.0` |
| `APISERVER_LATENCY_MS_MAX` | apiserver 延迟阈值（毫秒） | `500` |
| `ACCEPTANCE_CLEANUP` | 测试结束后是否自动清理 | `true` |

## 日志输出

脚本同时输出到**终端**（带颜色）和**日志文件**（带时间戳）：

- **终端**：彩色实时输出，便于快速定位问题
- **日志文件**：`report/acceptance-YYYYMMDD-HHMMSS.log`，格式如下：

```
[2024-01-15 09:30:01] [INFO] K8s 集群一键验收测试启动
[2024-01-15 09:30:02] [INFO] 共发现 10 个检查模块
[2024-01-15 09:30:05] [PASS] 环境检查通过: kubectl v1.28.0, 权限正常
[2024-01-15 09:30:08] [FAIL] 节点检查未通过: 存在压力节点
```

## 报告输出

测试完成后在 `report/` 目录生成 Markdown 格式报告，包含：
- 汇总统计（总计/通过/失败/跳过）
- 各模块详细结果表格
- 失败项的关键详情与建议复核命令

报告示例：

```markdown
# K8s 集群验收报告

生成时间: 2024-01-15 09:35:42

## 汇总统计

| 指标 | 数值 |
|------|------|
| 总计 | 10 |
| 通过 | 9 |
| 失败 | 1 |
| 跳过 | 0 |

## 详细结果

| 模块 | 状态 | 耗时 | 关键结论 | 失败详情 |
|------|------|------|----------|----------|
| 节点检查 | FAIL | 3s | 存在压力节点 | node-02 |
```

## Operator/CRD 专项验收

1. **CRD 状态检查**：自动枚举所有 CRD，验证 `Established` 条件。
2. **Operator Pod 检查**：配置 `OPERATOR_LABELS`（如 `app=my-operator`）后，脚本会检查匹配 Pod 是否全部 Ready。
3. **CR 生命周期测试**：在 `manifests/operator-test/sample-cr.yaml` 放置您的示例 CR，脚本会执行 `apply → wait Ready → delete` 验证完整生命周期。

## 常见问题

**Q: 没有 Kubernetes 集群可以测试脚本吗？**  
A: 可以执行 `./run-acceptance.sh --dry-run` 预览检查清单，验证脚本本身是否正常。

**Q: 如何保留测试资源用于问题排查？**  
A: 设置 `ACCEPTANCE_CLEANUP=false ./run-acceptance.sh`，测试 Namespace 将不会被自动删除。

**Q: 性能测试需要额外依赖吗？**  
A: 性能测试依赖 `networkstatic/iperf3` 镜像，需集群能访问公网或提前导入该镜像。默认关闭，需显式启用 `CHECK_PERFORMANCE=true`。
