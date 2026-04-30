# 智能告警与异常检测

> 市场 JD 高频要求："构建智能告警系统，基于动态基线与异常检测算法，大幅减少误报/漏报"、"AIOps 增强可观测能力"

---

## 1. 传统告警的痛点

| 痛点 | 说明 |
|------|------|
| **静态阈值误报** | CPU > 80% 在业务高峰期持续触发，但系统正常 |
| **缺乏上下文** | 告警只告诉"CPU 高"，不告诉"为什么高" |
| **告警风暴** | 级联故障导致数百条重复告警 |
| **无法预测** | 只能事后告警，不能提前预警 |
| **季节性问题** | 周末/节假日流量模式不同，固定阈值不适用 |

---

## 2. 智能告警体系

### 2.1 分层告警架构

```
┌─────────────────────────────────────────────────────────────┐
│                    智能告警平台                                │
│                                                               │
│  ┌───────────────────────────────────────────────────────┐   │
│  │              异常检测引擎                               │   │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐    │   │
│  │  │ 统计模型 │ │ 机器学习 │ │ 动态阈值 │ │ 模式识别 │    │   │
│  │  │ Z-Score │ │ Isolation│ │ Prophet │ │ 周期性  │    │   │
│  │  │ 3-Sigma │ │  Forest │ │         │ │ 检测    │    │   │
│  │  └─────────┘ └─────────┘ └─────────┘ └─────────┘    │   │
│  └───────────────────────────────────────────────────────┘   │
│                           │                                   │
│  ┌────────────────────────▼────────────────────────────┐     │
│  │              根因分析引擎 (RCA)                        │     │
│  │  - 拓扑关联分析                                          │     │
│  │  - 事件时序关联                                          │     │
│  │  - 日志异常模式匹配                                       │     │
│  └────────────────────────────────────────────────────────┘     │
│                           │                                   │
│  ┌────────────────────────▼────────────────────────────┐     │
│  │              告警降噪与路由                            │     │
│  │  - 聚类合并                                              │     │
│  │  - 抑制与静默                                            │     │
│  │  - 智能分级                                              │     │
│  └────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

---

## 3. 异常检测算法

### 3.1 统计模型（简单有效）

#### Z-Score / 3-Sigma

```python
import numpy as np

def z_score_detect(values, threshold=3):
    """
    Z-Score 异常检测
    适用于：数据近似正态分布
    """
    mean = np.mean(values)
    std = np.std(values)
    
    z_scores = [(v - mean) / std for v in values]
    anomalies = [i for i, z in enumerate(z_scores) if abs(z) > threshold]
    
    return anomalies

# PromQL 实现（近似）
# 检测偏离过去 1 小时均值 3 个标准差的点
abs(
  rate(http_requests_total[5m])
  -
  avg_over_time(rate(http_requests_total[5m])[1h:5m])
) > 3 * stddev_over_time(rate(http_requests_total[5m])[1h:5m])
```

#### MAD（Median Absolute Deviation）

```python
def mad_detect(values, threshold=3.5):
    """
    MAD 异常检测
    对异常值不敏感，比 Z-Score 更稳健
    """
    median = np.median(values)
    deviations = [abs(v - median) for v in values]
    mad = np.median(deviations)
    
    modified_z_scores = [0.6745 * (v - median) / mad for v in values]
    anomalies = [i for i, z in enumerate(modified_z_scores) if abs(z) > threshold]
    
    return anomalies
```

### 3.2 动态阈值（处理季节性）

#### Prophet（Facebook 开源）

```python
from prophet import Prophet
import pandas as pd

# 准备训练数据
df = pd.DataFrame({
    'ds': timestamps,
    'y': metric_values
})

# 训练模型
model = Prophet(
    yearly_seasonality=True,
    weekly_seasonality=True,
    daily_seasonality=True,
    changepoint_prior_scale=0.05
)
model.fit(df)

# 预测未来 + 异常区间
future = model.make_future_dataframe(periods=60, freq='min')
forecast = model.predict(future)

# 使用预测区间的上下界作为动态阈值
lower_bound = forecast['yhat_lower']
upper_bound = forecast['yhat_upper']
```

**Prophet 在告警中的应用**：
```python
def prophet_alert(current_value, forecast_lower, forecast_upper):
    """
    如果当前值超出预测区间，则触发告警
    """
    if current_value < forecast_lower:
        return "LOW_ANOMALY", current_value / forecast_lower
    elif current_value > forecast_upper:
        return "HIGH_ANOMALY", current_value / forecast_upper
    return "NORMAL", 0
```

### 3.3 机器学习模型

#### Isolation Forest（孤立森林）

```python
from sklearn.ensemble import IsolationForest

# 训练模型
model = IsolationForest(
    contamination=0.01,  # 期望的异常比例
    random_state=42
)
model.fit(training_data)

# 预测
predictions = model.predict(new_data)
# -1 = 异常, 1 = 正常

# 异常分数
scores = model.decision_function(new_data)
```

#### LSTM Autoencoder（深度学习）

```python
import tensorflow as tf

# 构建 LSTM Autoencoder
model = tf.keras.Sequential([
    tf.keras.layers.LSTM(64, activation='relu', input_shape=(timesteps, features), return_sequences=True),
    tf.keras.layers.LSTM(32, activation='relu', return_sequences=False),
    tf.keras.layers.RepeatVector(timesteps),
    tf.keras.layers.LSTM(32, activation='relu', return_sequences=True),
    tf.keras.layers.LSTM(64, activation='relu', return_sequences=True),
    tf.keras.layers.TimeDistributed(tf.keras.layers.Dense(features))
])

model.compile(optimizer='adam', loss='mse')

# 训练（只用正常数据训练）
model.fit(normal_data, normal_data, epochs=50)

# 检测：重构误差大的为异常
reconstructions = model.predict(test_data)
mse = np.mean(np.power(test_data - reconstructions, 2), axis=1)
anomalies = mse > threshold
```

---

## 4. 根因分析（RCA）

### 4.1 拓扑关联分析

```python
# 服务依赖拓扑
service_graph = {
    'frontend': ['gateway'],
    'gateway': ['user-service', 'order-service'],
    'order-service': ['payment-service', 'inventory-service'],
    'payment-service': ['mysql'],
    'inventory-service': ['redis', 'mysql']
}

def find_root_cause(alerted_service, metrics):
    """
    从下往上遍历拓扑，找到最先异常的依赖
    """
    visited = set()
    queue = [alerted_service]
    
    while queue:
        service = queue.pop(0)
        if service in visited:
            continue
        visited.add(service)
        
        # 检查该服务是否异常
        if is_anomalous(metrics[service]):
            # 检查其依赖是否更早异常
            for dep in service_graph.get(service, []):
                if is_anomalous(metrics[dep]) and metrics[dep]['timestamp'] < metrics[service]['timestamp']:
                    queue.append(dep)
            
            if service not in queue:
                return service  # 找到根因
    
    return alerted_service
```

### 4.2 日志异常模式匹配

```python
import re

# 定义已知故障模式
failure_patterns = {
    'oom': r'OutOfMemoryError|Killed process \d+ \(oom_score_adj',
    'connection_pool_exhausted': r'Cannot get a connection|pool is exhausted',
    'deadlock': r'Deadlock found|Lock wait timeout exceeded',
    'disk_full': r'No space left on device',
}

def analyze_logs(logs, timeframe=300):
    """
    分析时间窗口内的日志，匹配故障模式
    """
    results = {}
    for pattern_name, pattern in failure_patterns.items():
        matches = [log for log in logs if re.search(pattern, log)]
        if matches:
            results[pattern_name] = len(matches)
    
    return results
```

---

## 5. 告警降噪实践

### 5.1 时间窗口聚合

```yaml
# 将同一服务的多个相似告警合并为一条
group_by: ['service', 'alertname']
group_wait: 30s
group_interval: 5m
repeat_interval: 4h
```

### 5.2 智能分级

```python
def classify_alert(metric, context):
    """
    基于多维上下文自动分级
    """
    score = 0
    
    # 指标严重程度
    if metric['error_rate'] > 0.1:
        score += 50
    elif metric['error_rate'] > 0.05:
        score += 30
    
    # 影响范围
    if context['affected_pods'] > 10:
        score += 30
    elif context['affected_pods'] > 3:
        score += 15
    
    # 是否为核心业务
    if context['is_critical_service']:
        score += 20
    
    # 是否在维护窗口
    if context['in_maintenance_window']:
        score -= 50
    
    # 分级
    if score >= 80:
        return 'P0'
    elif score >= 50:
        return 'P1'
    elif score >= 20:
        return 'P2'
    else:
        return 'P3'
```

### 5.3 告警疲劳检测

```python
def detect_alert_fatigue(alerts, window=3600):
    """
    检测频繁触发但无实际问题的告警
    """
    alert_stats = {}
    
    for alert in alerts:
        key = alert['alertname'] + alert['service']
        if key not in alert_stats:
            alert_stats[key] = {'count': 0, 'resolved_count': 0}
        alert_stats[key]['count'] += 1
        if alert['status'] == 'resolved':
            alert_stats[key]['resolved_count'] += 1
    
    # 如果告警频繁触发且快速恢复，可能是阈值设置不当
    fatigue_alerts = []
    for key, stats in alert_stats.items():
        if stats['count'] > 10 and stats['resolved_count'] / stats['count'] > 0.9:
            fatigue_alerts.append(key)
    
    return fatigue_alerts
```

---

## 6. 开源工具推荐

| 工具 | 功能 | 集成方式 |
|------|------|----------|
| **Prophet** | 时间序列预测 | Python 库，自定义脚本 |
| **Nightingale** | 国产智能告警平台 | 替代 Alertmanager |
| **Causely** | AI 根因分析 | SaaS 平台 |
| **Moogsoft** | AIOps 平台 | 企业级 |
| **Datadog Watchdog** | 自动异常检测 | 商业 SaaS |
| **Grafana ML** | Grafana 内置异常检测 | Grafana Cloud |

---

## 7. 面试高频题

1. **如何处理业务高峰期的告警误报？**
   - 答：使用动态阈值（Prophet）替代静态阈值，结合业务日历（节假日/促销活动）调整基线。

2. **如何实现告警的自动收敛？**
   - 答：拓扑关联分析 → 找到根因服务 → 抑制非根因告警 → 合并同类告警。

3. **Prometheus 告警和 Grafana 告警有什么区别？**
   - 答：Prometheus 基于指标数据告警，适合基础设施；Grafana Unified Alerting 支持多数据源（Metrics/Logs/Traces），适合复杂场景。

---

## 参考资源

- [Prophet 文档](https://facebook.github.io/prophet/)
- [Isolation Forest Paper](https://cs.nju.edu.cn/zhouzh/zhouzh.files/publication/icdm08b.pdf)
- [Google SRE - Alerting](https://sre.google/workbook/alerting/)
- [Nightingale 文档](https://n9e.github.io/)
