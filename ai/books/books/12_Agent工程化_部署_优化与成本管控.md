# 12. Agent工程化：部署、优化与成本管控

> **目标读者**：负责Agent系统工业化落地与持续优化的技术负责人  
> **核心目标**：掌握Agent系统的成本控制、性能优化、持续交付与运维策略

---

## 目录

### 第1章 Agent系统的成本结构（已详细编写）
1.1 LLM调用成本分析  
1.2 基础设施成本  
1.3 隐性成本：延迟、错误、维护  
1.4 成本模型与预算规划

### 第2章 Token优化策略（已详细编写）
2.1 提示词压缩技术  
2.2 上下文裁剪与摘要  
2.3 输出Token控制  
2.4 模型选择与路由优化

### 第3章 缓存策略（已详细编写）
3.1 精确缓存：相同输入复用输出  
3.2 语义缓存：相似输入复用输出  
3.3 嵌入缓存与结果缓存  
3.4 缓存命中率优化

### 第4章 性能优化
4.1 流式响应与首Token延迟  
4.2 连接池与Keep-Alive  
4.3 批量处理与异步化  
4.4 模型推理加速

### 第5章 持续交付与MLOps
5.1 Prompt版本管理  
5.2 A/B测试与灰度发布  
5.3 模型升级策略  
5.4 回滚机制

### 第6章 运维与SRE实践
6.1 SLA定义与监控  
6.2 On-call与事件响应  
6.3 容量规划  
6.4 混沌工程与故障演练

### 第7章 实战：构建成本最优的Agent系统
7.1 成本基线建立  
7.2 优化迭代路径  
7.3  ROI评估  
7.4 完整优化案例

---

## 第1章 Agent系统的成本结构

### 1.1 LLM调用成本分析

```python
# OpenAI GPT-4o 定价（示例，需查最新价格）
PRICING = {
    "gpt-4o": {
        "input": 0.005,   # $/1K tokens
        "output": 0.015,  # $/1K tokens
    },
    "gpt-4o-mini": {
        "input": 0.00015,
        "output": 0.0006,
    },
    "claude-3-5-sonnet": {
        "input": 0.003,
        "output": 0.015,
    }
}

def calculate_call_cost(model: str, input_tokens: int, output_tokens: int) -> float:
    """计算单次LLM调用成本"""
    pricing = PRICING.get(model, PRICING["gpt-4o-mini"])
    input_cost = (input_tokens / 1000) * pricing["input"]
    output_cost = (output_tokens / 1000) * pricing["output"]
    return input_cost + output_cost

# Agent请求的成本分解
class CostBreakdown:
    def __init__(self):
        self.llm_calls: list[dict] = []
        self.embedding_calls: list[dict] = []
        self.tool_calls: list[dict] = []
    
    def add_llm_call(self, model: str, input_tokens: int, output_tokens: int):
        cost = calculate_call_cost(model, input_tokens, output_tokens)
        self.llm_calls.append({
            "model": model,
            "input_tokens": input_tokens,
            "output_tokens": output_tokens,
            "cost": cost
        })
    
    @property
    def total_llm_cost(self) -> float:
        return sum(c["cost"] for c in self.llm_calls)
    
    @property
    def total_tokens(self) -> int:
        return sum(
            c["input_tokens"] + c["output_tokens"] 
            for c in self.llm_calls
        )
    
    def report(self) -> str:
        lines = ["=== Agent调用成本报告 ==="]
        for i, call in enumerate(self.llm_calls, 1):
            lines.append(
                f"  调用{i}: {call['model']} | "
                f"Input: {call['input_tokens']} | "
                f"Output: {call['output_tokens']} | "
                f"${call['cost']:.4f}"
            )
        lines.append(f"\n总LLM成本: ${self.total_llm_cost:.4f}")
        lines.append(f"总Token数: {self.total_tokens}")
        return "\n".join(lines)
```

**典型Agent请求的成本结构：**

```
单次Agent请求（5轮对话，平均3次工具调用）：

├── 系统提示                     ~500 tokens
├── 对话历史（5轮）              ~2000 tokens
├── 工具调用（3次）              
│   ├── 工具选择LLM调用          ~300 tokens in / ~100 tokens out × 3
│   └── 工具结果回传             ~500 tokens × 3
├── 最终回答生成                 ~800 tokens in / ~600 tokens out
│
└── 总计
    ├── Input tokens: ~5000
    ├── Output tokens: ~1500
    ├── 使用GPT-4o: ~$0.0475
    └── 使用GPT-4o-mini: ~$0.0017
```

### 1.2 基础设施成本

| 组件 | 成本因素 | 优化方向 |
|------|----------|----------|
| **计算** | K8s节点、GPU实例 | 自动扩缩容、Spot实例 |
| **存储** | 向量数据库、Redis、对象存储 | 数据生命周期管理 |
| **网络** | 跨区域流量、CDN | 就近部署、压缩传输 |
| **监控** | 日志采集、指标存储 | 采样、聚合、保留策略 |

### 1.3 隐性成本

```python
HIDDEN_COSTS = {
    "latency_cost": {
        "description": "用户等待时间越长，转化率越低",
        "impact": "每增加100ms延迟，转化率下降1%",
        "mitigation": "流式响应、预加载、缓存"
    },
    "error_cost": {
        "description": "Agent失败导致的人工介入",
        "impact": "每次转人工成本$5-20",
        "mitigation": "更好的错误处理、Fallback策略"
    },
    "maintenance_cost": {
        "description": "Prompt调优、模型升级、Bug修复",
        "impact": "每月10-20%的工程时间",
        "mitigation": "自动化测试、配置化、模块化"
    },
    "context_switch_cost": {
        "description": "长对话导致上下文膨胀",
        "impact": "Token成本随对话长度线性增长",
        "mitigation": "摘要压缩、向量检索、会话重置"
    }
}
```

### 1.4 成本模型与预算规划

```python
class CostModel:
    """Agent系统成本预测模型"""
    
    def __init__(
        self,
        daily_requests: int,
        avg_turns_per_session: float,
        avg_tokens_per_turn: int,
        model_mix: dict[str, float]  # 模型使用比例
    ):
        self.daily_requests = daily_requests
        self.avg_turns = avg_turns_per_session
        self.avg_tokens = avg_tokens_per_turn
        self.model_mix = model_mix
    
    def monthly_llm_cost(self) -> dict:
        """估算月度LLM成本"""
        monthly_requests = self.daily_requests * 30
        total_tokens_monthly = (
            monthly_requests * 
            self.avg_turns * 
            self.avg_tokens
        )
        
        costs = {}
        for model, ratio in self.model_mix.items():
            model_tokens = total_tokens_monthly * ratio
            pricing = PRICING.get(model, PRICING["gpt-4o-mini"])
            # 简化为平均input:output = 2:1
            input_tokens = model_tokens * 2/3
            output_tokens = model_tokens * 1/3
            cost = (
                (input_tokens / 1000) * pricing["input"] +
                (output_tokens / 1000) * pricing["output"]
            )
            costs[model] = cost
        
        costs["total"] = sum(costs.values())
        return costs
    
    def estimate_with_optimization(
        self,
        cache_hit_rate: float = 0.2,
        model_downgrade_ratio: float = 0.3
    ) -> dict:
        """估算优化后的成本"""
        base = self.monthly_llm_cost()
        
        # 缓存节省
        cache_savings = base["total"] * cache_hit_rate * 0.8
        
        # 模型降级节省（部分请求用便宜模型）
        # 假设降级的请求成本降低80%
        downgrade_savings = (
            base["total"] * 
            model_downgrade_ratio * 
            0.8
        )
        
        optimized = base["total"] - cache_savings - downgrade_savings
        
        return {
            "baseline": base["total"],
            "cache_savings": cache_savings,
            "downgrade_savings": downgrade_savings,
            "optimized": optimized,
            "savings_percent": (base["total"] - optimized) / base["total"] * 100
        }

# 示例：日活10万的Agent系统
model = CostModel(
    daily_requests=100_000,
    avg_turns_per_session=5,
    avg_tokens_per_turn=2000,
    model_mix={
        "gpt-4o": 0.3,
        "gpt-4o-mini": 0.6,
        "claude-3-5-sonnet": 0.1
    }
)

print(model.monthly_llm_cost())
print(model.estimate_with_optimization(cache_hit_rate=0.25, model_downgrade_ratio=0.4))
```

---

## 第2章 Token优化策略

### 2.1 提示词压缩技术

```python
class PromptCompressor:
    """提示词压缩器"""
    
    def __init__(self, llm_client):
        self.llm = llm_client
    
    def remove_redundancy(self, text: str) -> str:
        """去除冗余表达"""
        # 合并重复空格
        text = " ".join(text.split())
        # 去除无意义的填充词
        fillers = ["实际上", "说实话", "坦白说", "众所周知"]
        for f in fillers:
            text = text.replace(f, "")
        return text
    
    async def summarize_history(
        self, 
        messages: list[dict],
        target_tokens: int = 1000
    ) -> list[dict]:
        """将长对话历史压缩为摘要"""
        if len(messages) <= 4:
            return messages
        
        # 保留最近2轮完整对话
        recent = messages[-4:]
        older = messages[:-4]
        
        # 将早期对话压缩为摘要
        older_text = "\n".join(
            f"{m['role']}: {m['content']}" 
            for m in older
        )
        
        summary_prompt = f"""将以下对话历史压缩为简短摘要（200字以内）：

{older_text}

摘要："""
        
        summary = await self.llm.generate(summary_prompt, max_tokens=200)
        
        return [
            {"role": "system", "content": f"历史对话摘要：{summary}"},
            *recent
        ]
    
    def trim_messages(
        self, 
        messages: list[dict],
        max_tokens: int = 6000
    ) -> list[dict]:
        """按Token限制裁剪消息列表"""
        # 从最早的消息开始删除，保留系统提示和最近消息
        system_msgs = [m for m in messages if m["role"] == "system"]
        other_msgs = [m for m in messages if m["role"] != "system"]
        
        # 估算Token（简化：1 token ≈ 4 chars for English, 1 char for Chinese）
        def estimate_tokens(msg):
            content = msg.get("content", "")
            return len(content)  # 简化估算
        
        # 保留系统消息，从其他消息中裁剪
        result = system_msgs[:]
        current_tokens = sum(estimate_tokens(m) for m in system_msgs)
        
        # 从后往前添加消息
        for msg in reversed(other_msgs):
            msg_tokens = estimate_tokens(msg)
            if current_tokens + msg_tokens > max_tokens:
                break
            result.insert(len(system_msgs), msg)
            current_tokens += msg_tokens
        
        return result
```

### 2.2 模型选择与路由优化

```python
class SmartModelRouter:
    """智能模型路由器：根据任务复杂度选择模型"""
    
    MODELS = {
        "fast": {"name": "gpt-4o-mini", "cost_ratio": 1, "capability": 3},
        "balanced": {"name": "gpt-4o", "cost_ratio": 10, "capability": 5},
        "powerful": {"name": "claude-3-5-sonnet", "cost_ratio": 12, "capability": 5},
    }
    
    TASK_COMPLEXITY = {
        "greeting": 1,
        "faq": 1,
        "entity_extraction": 2,
        "classification": 2,
        "summarization": 3,
        "reasoning": 4,
        "planning": 5,
        "code_generation": 5,
    }
    
    def __init__(self, llm_client):
        self.llm = llm_client
        self.performance_history: dict[str, dict] = {}
    
    async def classify_complexity(self, query: str) -> int:
        """评估查询复杂度（1-5）"""
        # 简单规则分类
        query_lower = query.lower()
        
        if any(w in query_lower for w in ["你好", "hi", "hello", "谢谢"]):
            return 1
        
        if any(w in query_lower for w in ["计算", "code", "编程", "设计", "架构"]):
            return 5
        
        if any(w in query_lower for w in ["分析", "为什么", "比较", "评估"]):
            return 4
        
        # 默认用中等复杂度
        return 3
    
    def select_model(self, complexity: int, quality_required: bool = True) -> str:
        """根据复杂度选择模型"""
        if complexity <= 2 and not quality_required:
            return self.MODELS["fast"]["name"]
        elif complexity <= 3:
            return self.MODELS["balanced"]["name"]
        else:
            return self.MODELS["powerful"]["name"]
    
    async def route_with_fallback(
        self,
        query: str,
        messages: list[dict],
        quality_threshold: float = 0.8
    ) -> dict:
        """路由并支持降级fallback"""
        complexity = await self.classify_complexity(query)
        
        # 先尝试便宜模型
        fast_result = await self.call_model(
            self.MODELS["fast"]["name"],
            messages
        )
        
        # 评估结果质量（简化：用置信度或长度判断）
        quality_score = self.assess_quality(fast_result)
        
        if quality_score >= quality_threshold:
            return {
                "result": fast_result,
                "model_used": "fast",
                "quality_score": quality_score
            }
        
        # 质量不够，升级到强模型
        powerful_result = await self.call_model(
            self.MODELS["powerful"]["name"],
            messages
        )
        
        return {
            "result": powerful_result,
            "model_used": "powerful",
            "quality_score": self.assess_quality(powerful_result),
            "fallback_reason": "fast_model_quality_insufficient"
        }
    
    def assess_quality(self, result: str) -> float:
        """简化版质量评估"""
        # 实际应用中应使用更复杂的评估
        score = 0.5
        
        # 长度适中加分
        if 50 < len(result) < 2000:
            score += 0.2
        
        # 包含结构化内容加分
        if any(c in result for c in ["1.", "- ", "\n\n"]):
            score += 0.15
        
        # 包含不确定性表达减分
        if any(w in result for w in ["不知道", "不确定", "无法", "不清楚"]):
            score -= 0.2
        
        return min(max(score, 0), 1)
```

---

## 第3章 缓存策略

### 3.1 精确缓存

```python
import hashlib
import json
from typing import Any

class ExactCache:
    """精确匹配缓存：相同输入返回相同输出"""
    
    def __init__(self, redis_client, ttl: int = 3600):
        self.redis = redis_client
        self.ttl = ttl
    
    def _make_key(self, model: str, messages: list[dict], temperature: float) -> str:
        """生成缓存键"""
        # 规范化消息格式
        normalized = json.dumps({
            "model": model,
            "messages": messages,
            "temperature": temperature
        }, sort_keys=True, ensure_ascii=False)
        
        return f"llm:exact:{hashlib.sha256(normalized.encode()).hexdigest()}"
    
    async def get(self, model: str, messages: list[dict], temperature: float) -> str | None:
        key = self._make_key(model, messages, temperature)
        result = await self.redis.get(key)
        return result.decode() if result else None
    
    async def set(
        self, 
        model: str, 
        messages: list[dict], 
        temperature: float,
        response: str
    ):
        key = self._make_key(model, messages, temperature)
        await self.redis.setex(key, self.ttl, response)
```

### 3.2 语义缓存

```python
import numpy as np

class SemanticCache:
    """语义缓存：相似问题复用答案"""
    
    def __init__(
        self,
        embedding_model,
        vector_store,
        similarity_threshold: float = 0.95
    ):
        self.embedder = embedding_model
        self.store = vector_store
        self.threshold = similarity_threshold
    
    async def get(self, query: str) -> str | None:
        """检索语义相似的缓存"""
        # 生成查询向量
        query_embedding = await self.embedder.embed(query)
        
        # 在向量库中检索
        results = await self.store.similarity_search_with_score(
            embedding=query_embedding,
            k=1
        )
        
        if not results:
            return None
        
        doc, score = results[0]
        
        # 注意：不同的向量库score定义不同，有的是距离，有的是相似度
        # 这里假设score是相似度（0-1）
        if score >= self.threshold:
            return doc.metadata["response"]
        
        return None
    
    async def set(self, query: str, response: str):
        """存储新的缓存项"""
        embedding = await self.embedder.embed(query)
        
        await self.store.add_texts(
            texts=[query],
            embeddings=[embedding],
            metadatas=[{"response": response, "query": query}]
        )
```

### 3.3 缓存命中率优化

```python
class AdaptiveCache:
    """自适应缓存：动态调整缓存策略"""
    
    def __init__(self):
        self.exact_cache = ExactCache(redis)
        self.semantic_cache = SemanticCache(embedder, vector_store)
        self.hit_stats = {"exact": 0, "semantic": 0, "miss": 0}
    
    async def get(self, query: str, model: str, messages: list, temp: float) -> str | None:
        # 先查精确缓存
        exact = await self.exact_cache.get(model, messages, temp)
        if exact:
            self.hit_stats["exact"] += 1
            return exact
        
        # 再查语义缓存（只对用户输入查，不对完整messages查）
        semantic = await self.semantic_cache.get(query)
        if semantic:
            self.hit_stats["semantic"] += 1
            return semantic
        
        self.hit_stats["miss"] += 1
        return None
    
    @property
    def hit_rate(self) -> float:
        total = sum(self.hit_stats.values())
        if total == 0:
            return 0
        hits = self.hit_stats["exact"] + self.hit_stats["semantic"]
        return hits / total
    
    def should_cache(self, query: str, response: str) -> bool:
        """判断是否应该缓存这个结果"""
        # 不包含敏感信息
        if contains_pii(response):
            return False
        
        # 不是错误响应
        if "error" in response.lower() and len(response) < 200:
            return False
        
        # 响应长度适中
        if len(response) > 10000:
            return False
        
        return True
```

---

## 第4-7章 内容精要

### 第4章 性能优化
- **首Token延迟**：用户最敏感的体验指标，优化方向包括连接预热、模型预热、就近部署
- **Keep-Alive**：HTTP长连接减少TCP握手开销
- **批量处理**：合并多个Embedding请求、批量向量检索
- **模型加速**：vLLM的PagedAttention、TensorRT-LLM、量化（INT8/INT4）

### 第5章 持续交付与MLOps
- **Prompt版本管理**：Git管理 + 语义化版本 + 效果数据关联
- **A/B测试**：流量分割比较不同Prompt/模型的效果
- **灰度发布**：先5%流量 → 20% → 50% → 全量
- **模型升级**：新版本并行部署，逐步切流，保留回滚能力

### 第6章 运维与SRE实践
- **SLA定义**：可用性99.9%、P99延迟<3s、错误率<0.1%
- **On-call**：PagerDuty轮换，分级响应（P0 15分钟，P1 1小时）
- **容量规划**：基于增长率预测，提前2周扩容
- **混沌工程**：随机杀死Pod、模拟网络延迟、注入LLM超时

### 第7章 实战：成本最优Agent系统
- 案例：某客服Agent系统月成本从$50K优化到$12K
- 优化路径：
  1. 引入语义缓存（命中率25%，节省20%）
  2. 模型路由（60%请求用GPT-4o-mini，节省40%）
  3. Prompt压缩（平均减少30%输入Token，节省15%）
  4. 结果缓存（FAQ类查询命中率60%，节省10%）
- ROI：优化投入2人月，年节省$456K

---

## 本章小结

| 知识点 | 成本优化效果 |
|--------|-------------|
| Token压缩 | 减少输入Token 20-40% |
| 模型路由 | 节省60-80%的简单请求成本 |
| 精确缓存 | 重复查询零成本 |
| 语义缓存 | 相似查询节省80-100% |
| 流式响应 | 提升用户体验，降低感知延迟 |
| 批量处理 | 提升吞吐量，降低单位成本 |
| A/B测试 | 数据驱动选择最优方案 |
| 容量规划 | 避免过度配置，优化资源利用率 |
