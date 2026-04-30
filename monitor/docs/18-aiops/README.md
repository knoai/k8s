# AIOps 智能运维与异常检测

> 从静态阈值到动态基线，从规则驱动到数据驱动。AIOps 将机器学习引入运维领域，解决传统告警的"漏报、误报、风暴"三大难题。

---

## 1. 传统告警的三大痛点

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                    传统静态阈值告警的问题                                     │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  痛点 1: 误报 (False Positive)                                              │
│  ─────────────────────────────                                              │
│  CPU > 80% 告警，但业务正常                                                  │
│  白天高峰期正常高负载，晚上低峰期相同阈值也告警                               │
│  业务发布时流量突增触发大量告警                                               │
│                                                                             │
│  痛点 2: 漏报 (False Negative)                                              │
│  ─────────────────────────────                                              │
│  阈值设太高: 缓慢增长的内存泄漏未被检测                                       │
│  阈值设太低: 业务低峰期正常波动也告警，团队麻木后忽略                         │
│  复合故障: 单个指标正常，但组合异常                                          │
│                                                                             │
│  痛点 3: 告警风暴 (Alert Fatigue)                                           │
│  ────────────────────────────────                                           │
│  单故障触发数十条相关告警                                                    │
│  级联故障时告警量指数级增长                                                   │
│  On-call 工程师被海量告警淹没，找不到根因                                     │
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                      传统告警的恶性循环                               │   │
│  │                                                                      │   │
│  │   阈值不合理 ──► 大量误报 ──► 调高阈值 ──► 漏报增加 ──► 故障发现延迟   │   │
│  │       ▲                                              │               │   │
│  │       └──────────────────────────────────────────────┘               │   │
│  │                                                                      │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. AIOps 核心能力

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                        AIOps 能力金字塔                                      │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│                    ┌─────────────────┐                                      │
│                    │   智能决策        │  自动修复、容量预测、变更风险评估      │
│                    │  (决策层)        │                                      │
│                    └────────┬────────┘                                      │
│                             │                                               │
│                    ┌────────▼────────┐                                      │
│                    │   根因分析        │  拓扑关联、异常传播链、日志模式识别    │
│                    │  (分析层)        │                                      │
│                    └────────┬────────┘                                      │
│                             │                                               │
│                    ┌────────▼────────┐                                      │
│                    │   异常检测        │  动态阈值、多维异常、时序预测          │
│                    │  (检测层)        │                                      │
│                    └────────┬────────┘                                      │
│                             │                                               │
│                    ┌────────▼────────┐                                      │
│                    │   数据处理        │  指标聚合、降噪、特征提取              │
│                    │  (数据层)        │                                      │
│                    └─────────────────┘                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. 异常检测算法

### 3.1 基于统计的方法

```python
# 3-sigma 原则（正态分布假设）
# 超过均值 ± 3 倍标准差的值为异常

import numpy as np

def three_sigma(data):
    mean = np.mean(data)
    std = np.std(data)
    lower = mean - 3 * std
    upper = mean + 3 * std
    return [(x < lower or x > upper) for x in data]

# 问题: 真实指标通常不是正态分布（有趋势、周期）
# 解决: 先分解趋势和季节，再对残差应用 3-sigma
```

### 3.2 基于时间序列分解

```python
# STL 分解: 将时间序列分解为 Trend + Seasonal + Residual

from statsmodels.tsa.seasonal import STL

def stl_anomaly_detection(series, period=1440):  # 周期: 1440 = 1天(分钟粒度)
    # 分解
    stl = STL(series, period=period, robust=True)
    result = stl.fit()
    
    # 对残差应用 3-sigma
    residual = result.resid
    mean = residual.mean()
    std = residual.std()
    
    anomalies = np.abs(residual - mean) > 3 * std
    return anomalies, result

# 优势:
#   • 自动适应趋势变化
#   • 自动适应周期性（白天/黑夜、工作日/周末）
#   • 只对"意外"部分检测异常
```

### 3.3 Prophet（Facebook 开源）

```python
# Prophet: 基于加性回归模型的时间序列预测
# 特别适合有强周期性的业务指标

from prophet import Prophet
import pandas as pd

def prophet_anomaly(df, threshold=0.99):
    """
    df: DataFrame with 'ds' (datetime) and 'y' (value) columns
    """
    model = Prophet(
        yearly_seasonality=True,
        weekly_seasonality=True,
        daily_seasonality=True,
        interval_width=threshold  # 预测区间宽度
    )
    model.fit(df)
    
    # 预测未来（包含历史拟合）
    future = model.make_future_dataframe(periods=0, freq='1min')
    forecast = model.predict(future)
    
    # 合并实际值和预测值
    result = pd.merge(df, forecast[['ds', 'yhat', 'yhat_lower', 'yhat_upper']], on='ds')
    
    # 异常: 实际值超出预测区间
    result['anomaly'] = (result['y'] < result['yhat_lower']) | (result['y'] > result['yhat_upper'])
    result['severity'] = np.abs(result['y'] - result['yhat']) / (result['yhat_upper'] - result['yhat_lower'])
    
    return result

# Prophet 特点:
#   ✓ 自动处理缺失值、趋势变化、节假日
#   ✓ 可配置节假日（如双十一、春节）
#   ✓ 提供不确定性区间
#   ✗ 训练较慢，不适合实时场景

# 在 Prometheus 中的实践:
#   1. 定期（如每小时）从历史数据训练 Prophet 模型
#   2. 生成预测基线和上下界
#   3. 实时查询时与预测值比较
#   4. 超出边界则触发告警
```

### 3.4 孤立森林（Isolation Forest）

```python
# 孤立森林: 基于随机划分的异常检测
# 异常点更容易被孤立（树深度更浅）

from sklearn.ensemble import IsolationForest

def isolation_forest_anomaly(X, contamination=0.01):
    """
    X: 特征矩阵 (n_samples, n_features)
       例如: [cpu_usage, memory_usage, request_rate, error_rate]
    """
    model = IsolationForest(
        contamination=contamination,  # 预期的异常比例
        random_state=42,
        n_estimators=100
    )
    model.fit(X)
    
    # -1 表示异常, 1 表示正常
    predictions = model.predict(X)
    scores = model.decision_function(X)  # 异常分数（越低越异常）
    
    return predictions == -1, scores

# 多维异常检测优势:
#   • CPU 正常 + 内存正常，但两者同时升高 = 异常
#   • 单维度看不出的模式，多维可以发现
```

### 3.5 算法对比

| 算法 | 适用场景 | 优点 | 缺点 | 实时性 |
|------|---------|------|------|--------|
| 3-sigma | 平稳序列 | 简单快速 | 对趋势/周期敏感 | 好 |
| STL + 3-sigma | 有周期性的序列 | 自动去趋势 | 需要足够历史数据 | 中 |
| Prophet | 业务指标（有明显周期） | 精准、可解释 | 训练慢、资源占用高 | 差 |
| 孤立森林 | 多维特征 | 发现复杂模式 | 需要特征工程 | 好 |
| LSTM/深度 | 复杂模式 | 精度高 | 训练成本高、黑盒 | 差 |

---

## 4. 告警降噪与聚合

### 4.1 告警抑制（Inhibition）

```yaml
# Alertmanager 抑制规则
# 父告警触发时，抑制子告警

inhibit_rules:
  # 节点宕机时，抑制该节点上所有 Pod 的告警
  - source_match:
      alertname: NodeDown
    target_match_re:
      alertname: PodNotReady|HighPodRestart|ContainerOOM
    equal:
      - node

  # 数据库主库宕机时，抑制从库的只读告警
  - source_match:
      alertname: DatabasePrimaryDown
    target_match:
      alertname: DatabaseReadOnly
    equal:
      - cluster
```

### 4.2 告警分组（Grouping）

```yaml
# Alertmanager 路由配置
route:
  group_by: ['alertname', 'cluster', 'namespace']
  group_wait: 30s       # 初始等待时间
  group_interval: 5m    # 同一组后续发送间隔
  repeat_interval: 4h   # 重复告警间隔
  receiver: default

  routes:
    # 同 namespace 的告警聚合为一条通知
    - match:
        severity: warning
      group_by: ['namespace']
      group_wait: 1m
      receiver: slack-warning

    # 严重告警立即发送，但按服务分组
    - match:
        severity: critical
      group_by: ['service']
      group_wait: 0s
      receiver: pagerduty-critical
```

### 4.3 拓扑聚合（基于服务依赖图）

```python
# 基于服务拓扑的告警聚合
# 如果 api-gateway 故障导致下游所有服务告警
# 只发送 api-gateway 的根因告警

SERVICE_GRAPH = {
    'api-gateway': ['user-service', 'order-service', 'payment-service'],
    'user-service': ['user-db'],
    'order-service': ['order-db', 'inventory-service'],
    'payment-service': ['payment-db', 'third-party-gateway']
}

def find_root_cause(alerts):
    """
    从告警集合中找到根因告警
    """
    alert_services = {a['service'] for a in alerts}
    
    # 找上游服务（如果有上游服务也在告警集合中，当前服务是结果不是原因）
    root_causes = []
    for service in alert_services:
        is_downstream = False
        for upstream, downstreams in SERVICE_GRAPH.items():
            if service in downstreams and upstream in alert_services:
                is_downstream = True
                break
        if not is_downstream:
            root_causes.append(service)
    
    return root_causes

# 实践: 结合 Cilium Hubble 自动发现服务拓扑
```

---

## 5. 根因分析（RCA）

### 5.1 基于时间关联

```python
# 找出与异常指标时间最接近的变更/事件

def correlate_events(metric_anomaly_time, events, window_minutes=30):
    """
    events: [{"time": datetime, "type": "deployment", "service": "api", "description": "..."}, ...]
    """
    correlated = []
    for event in events:
        time_diff = abs((event['time'] - metric_anomaly_time).total_seconds())
        if time_diff <= window_minutes * 60:
            correlated.append({
                **event,
                'time_diff_seconds': time_diff
            })
    
    # 按时间差排序
    return sorted(correlated, key=lambda x: x['time_diff_seconds'])

# 事件来源:
#   • K8s Events (Deployment, Pod 重启)
#   • CI/CD Pipeline (发布记录)
#   • 变更管理系统
#   • 配置变更 (ConfigMap/Secret 更新)
```

### 5.2 基于日志模式识别

```python
# 异常发生时，识别日志中的新模式

from collections import Counter
import re

def extract_log_patterns(logs, n=10):
    """
    从日志中提取常见模式
    """
    # 将变量替换为占位符
    patterns = []
    for log in logs:
        # 替换数字
        pattern = re.sub(r'\d+', '<NUM>', log)
        # 替换 IP
        pattern = re.sub(r'\d+\.\d+\.\d+\.\d+', '<IP>', pattern)
        # 替换 UUID
        pattern = re.sub(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}', '<UUID>', pattern)
        patterns.append(pattern)
    
    return Counter(patterns).most_common(n)

# 异常前后的日志模式对比
# 如果发现新的 ERROR 模式出现，很可能是根因
```

---

## 6. 实践：动态阈值告警脚本

```python
#!/usr/bin/env python3
"""
dynamic_threshold.py - 基于 Prophet 的动态阈值告警

部署方式:
1. 作为 CronJob 每小时运行，生成预测基线
2. 或作为 sidecar 持续运行
"""

import os
import json
import requests
import pandas as pd
from prophet import Prophet
from datetime import datetime, timedelta

PROMETHEUS_URL = os.environ.get('PROMETHEUS_URL', 'http://prometheus:9090')
ALERTMANAGER_URL = os.environ.get('ALERTMANAGER_URL', 'http://alertmanager:9093')

METRICS = [
    {
        'name': 'api_latency_p95',
        'query': 'histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le))',
        'threshold_multiplier': 1.5,  # 预测值的 1.5 倍触发告警
        'direction': 'upper'  # 只关注上升
    },
    {
        'name': 'error_rate',
        'query': 'sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m]))',
        'threshold_multiplier': 3.0,
        'direction': 'upper'
    }
]

def query_prometheus(query, start, end, step='1m'):
    """从 Prometheus 查询历史数据"""
    url = f"{PROMETHEUS_URL}/api/v1/query_range"
    params = {
        'query': query,
        'start': start.timestamp(),
        'end': end.timestamp(),
        'step': step
    }
    resp = requests.get(url, params=params, timeout=30)
    data = resp.json()['data']['result']
    
    if not data:
        return None
    
    # 转换为 DataFrame
    values = data[0]['values']
    df = pd.DataFrame(values, columns=['ds', 'y'])
    df['ds'] = pd.to_datetime(df['ds'], unit='s')
    df['y'] = pd.to_numeric(df['y'], errors='coerce')
    return df

def train_and_predict(df, periods=60, freq='1min'):
    """训练 Prophet 并预测"""
    model = Prophet(
        yearly_seasonality=False,
        weekly_seasonality=True,
        daily_seasonality=True,
        interval_width=0.95,
        changepoint_prior_scale=0.05
    )
    model.fit(df)
    
    future = model.make_future_dataframe(periods=periods, freq=freq)
    forecast = model.predict(future)
    
    return forecast

def check_anomalies(current_value, forecast_row, threshold_multiplier, direction):
    """检查当前值是否异常"""
    yhat = forecast_row['yhat']
    yhat_upper = forecast_row['yhat_upper']
    yhat_lower = forecast_row['yhat_lower']
    
    if direction == 'upper':
        threshold = yhat + (yhat_upper - yhat) * threshold_multiplier
        if current_value > threshold:
            severity = (current_value - yhat) / (yhat_upper - yhat)
            return True, severity
    else:
        threshold = yhat - (yhat - yhat_lower) * threshold_multiplier
        if current_value < threshold:
            severity = (yhat - current_value) / (yhat - yhat_lower)
            return True, severity
    
    return False, 0

def send_alert(alert_name, severity, description, value, expected):
    """发送告警到 Alertmanager"""
    alerts = [{
        'labels': {
            'alertname': alert_name,
            'severity': 'warning' if severity < 2 else 'critical',
            'source': 'dynamic-threshold'
        },
        'annotations': {
            'summary': f'{alert_name} 异常',
            'description': description,
            'value': str(value),
            'expected': str(expected)
        },
        'startsAt': datetime.utcnow().isoformat() + 'Z'
    }]
    
    resp = requests.post(
        f"{ALERTMANAGER_URL}/api/v1/alerts",
        json=alerts,
        timeout=10
    )
    return resp.status_code == 200

def main():
    end = datetime.now()
    start = end - timedelta(days=7)  # 使用 7 天历史数据训练
    
    for metric in METRICS:
        print(f"Processing: {metric['name']}")
        
        # 1. 获取历史数据
        df = query_prometheus(metric['query'], start, end)
        if df is None or len(df) < 100:
            print(f"  Insufficient data for {metric['name']}")
            continue
        
        # 2. 训练模型并预测
        forecast = train_and_predict(df)
        
        # 3. 获取当前值
        current_df = query_prometheus(metric['query'], end - timedelta(minutes=5), end, step='1m')
        if current_df is None or len(current_df) == 0:
            continue
        current_value = current_df['y'].iloc[-1]
        
        # 4. 找到对应的预测值
        current_time = current_df['ds'].iloc[-1]
        forecast_row = forecast[forecast['ds'] >= current_time].iloc[0]
        
        # 5. 检查异常
        is_anomaly, severity = check_anomalies(
            current_value, forecast_row,
            metric['threshold_multiplier'], metric['direction']
        )
        
        if is_anomaly:
            desc = (f"{metric['name']} 当前值 {current_value:.4f} "
                   f"超出动态阈值 (预期 {forecast_row['yhat']:.4f}, "
                   f"严重程度: {severity:.2f}x)")
            print(f"  ALERT: {desc}")
            send_alert(
                f"DynamicThreshold_{metric['name']}",
                severity, desc, current_value, forecast_row['yhat']
            )
        else:
            print(f"  OK: {current_value:.4f} (expected: {forecast_row['yhat']:.4f})")

if __name__ == '__main__':
    main()
```

---

## 7. 开源 AIOps 工具

| 工具 | 功能 | 场景 |
|------|------|------|
| **Prophet** | 时序预测 | 动态基线 |
| **Prometheus Anomaly Detector** | 异常检测 | K8s 指标 |
| **LinkedIn ThirdEye** | 多维异常检测 | 业务指标 |
| **Netflix Atlas** | 实时分析 | 大规模指标 |
| **Elastic ML** | 异常检测 | 日志分析 |
| **Grafana Machine Learning** | 预测 + 异常 | Grafana 集成 |
| **Numenta HTM** | 流式异常检测 | 实时场景 |

---

## 参考资源

- [Google SRE - Alerting on SLOs](https://sre.google/workbook/alerting-on-slos/)
- [Prophet 文档](https://facebook.github.io/prophet/)
- [Prometheus Anomaly Detector](https://github.com/prometheus-community/prometheus-anomaly-detector)
- [Awesome AIOps](https://github.com/topics/aiops)
