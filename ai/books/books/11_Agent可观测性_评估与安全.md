# 11. Agent可观测性、评估与安全

> **目标读者**：需要保障Agent系统质量、安全与合规性的工程负责人  
> **核心目标**：掌握Agent系统的监控、评估体系、安全护栏与对抗防御

---

## 目录

### 第1章 Agent可观测性体系（已详细编写）
1.1 为什么Agent可观测性比传统系统更难  
1.2 三大支柱：日志、指标、追踪  
1.3 Agent特有的可观测维度  
1.4 可观测性架构设计

### 第2章 Agent评估体系（AgentEval）（已详细编写）
2.1 Agent评估的独特挑战  
2.2 任务完成度评估  
2.3 推理质量评估  
2.4 工具使用准确性评估  
2.5 端到端评估框架  
2.6 人工评估与自动评估

### 第3章 追踪与调试（已详细编写）
3.1 Agent执行轨迹记录  
3.2 LangSmith / Langfuse 使用  
3.3 分布式追踪  
3.4 推理过程可视化  
3.5 根因分析技巧

### 第4章 Agent安全威胁模型
4.1 Prompt Injection攻击  
4.2 工具滥用与权限提升  
4.3 数据泄露风险  
4.4 幻觉与误导性输出  
4.5 供应链攻击

### 第5章 安全护栏与防御
5.1 输入过滤与清洗  
5.2 输出审核与敏感信息检测  
5.3 工具调用权限控制  
5.4 沙箱化代码执行  
5.5 对抗测试与红队演练

### 第6章 合规与治理
6.1 数据隐私保护（PII检测与脱敏）  
6.2 审计日志与合规报告  
6.3 模型使用的伦理边界  
6.4 AIGC标识与内容溯源

### 第7章 实战：构建Agent安全评估平台
7.1 安全测试用例集  
7.2 自动化安全扫描  
7.3 持续监控与告警  
7.4 事件响应流程

---

## 第1章 Agent可观测性体系

### 1.1 为什么Agent可观测性比传统系统更难

```
传统Web服务：                    Agent系统：

请求 ──► 处理 ──► 响应          请求 ──► 推理 ──► 工具? ──► 执行
   │      │        │                │      │        │         │
   │      │        │                │      ▼        ▼         ▼
   │      │        │                │   Thought  Action   Observation
   │      │        │                │      │        │         │
   │      │        │                │      └────┬───┘         │
   │      │        │                │           │             │
   │      │        │                │           ▼             │
   │      │        │                │        循环N次...       │
   │      │        │                │           │             │
   │      │        │                │           ▼             │
   │      │        │                │        最终答案        │

传统系统：确定性的输入-处理-输出
Agent系统：非确定性的多步推理循环，中间状态复杂
```

**Agent可观测性的特殊挑战：**

| 挑战 | 说明 | 解决方案 |
|------|------|----------|
| 非确定性 | 相同输入可能产生不同执行路径 | 记录完整执行轨迹 |
| 长执行链 | 可能包含10+次LLM调用和工具调用 | 分布式追踪 |
| 黑盒推理 | LLM内部推理过程不可见 | 强制输出思考过程 |
| 成本波动 | 不同路径Token消耗差异大 | 逐步骤成本追踪 |
| 幻觉检测 | 输出真假难辨 | 事实核查与引用溯源 |

### 1.2 三大支柱：日志、指标、追踪

```python
from dataclasses import dataclass, field
from datetime import datetime
from typing import Literal
import json

@dataclass
class AgentTrace:
    """Agent执行轨迹"""
    trace_id: str
    session_id: str
    user_id: str
    start_time: datetime
    end_time: datetime | None = None
    steps: list["AgentStepTrace"] = field(default_factory=list)
    total_tokens: int = 0
    total_cost: float = 0.0
    status: Literal["running", "success", "failed", "timeout"] = "running"
    final_output: str = ""

@dataclass
class AgentStepTrace:
    """单步执行轨迹"""
    step_number: int
    step_type: Literal["llm_call", "tool_call", "memory_access", "error"]
    start_time: datetime
    end_time: datetime | None = None
    input_data: dict = field(default_factory=dict)
    output_data: dict = field(default_factory=dict)
    latency_ms: float = 0.0
    tokens_used: int = 0
    cost: float = 0.0
    error: str | None = None

# 日志记录示例
class AgentLogger:
    def __init__(self):
        self.traces: dict[str, AgentTrace] = {}
    
    def start_trace(self, trace_id: str, session_id: str, user_id: str) -> AgentTrace:
        trace = AgentTrace(
            trace_id=trace_id,
            session_id=session_id,
            user_id=user_id,
            start_time=datetime.now()
        )
        self.traces[trace_id] = trace
        return trace
    
    def log_step(self, trace_id: str, step: AgentStepTrace):
        trace = self.traces[trace_id]
        trace.steps.append(step)
        trace.total_tokens += step.tokens_used
        trace.total_cost += step.cost
    
    def end_trace(self, trace_id: str, status: str, output: str):
        trace = self.traces[trace_id]
        trace.end_time = datetime.now()
        trace.status = status
        trace.final_output = output
        
        # 输出结构化日志
        print(json.dumps({
            "event": "agent_trace_complete",
            "trace_id": trace_id,
            "duration_ms": (trace.end_time - trace.start_time).total_seconds() * 1000,
            "total_tokens": trace.total_tokens,
            "total_cost": trace.total_cost,
            "status": status,
            "step_count": len(trace.steps)
        }))
```

### 1.3 Agent特有的可观测维度

```python
AGENT_METRICS = {
    # 性能指标
    "agent.request.latency": "端到端请求延迟（P50/P95/P99）",
    "agent.step.latency": "单步执行延迟",
    "agent.step.count": "每请求的平均步数",
    "agent.token.usage": "Token使用量（Input/Output）",
    "agent.cost.per_request": "单次请求成本",
    
    # 质量指标
    "agent.success.rate": "任务成功率",
    "agent.tool.accuracy": "工具调用准确率",
    "agent.hallucination.rate": "幻觉率（需人工/模型评估）",
    "agent.user.satisfaction": "用户满意度评分",
    
    # 系统指标
    "agent.queue.depth": "等待队列深度",
    "agent.active.sessions": "活跃会话数",
    "agent.memory.usage": "内存使用量",
    "agent.error.rate": "错误率",
    
    # 业务指标
    "agent.conversion.rate": "业务转化率（如购买、注册）",
    "agent.escalation.rate": "转人工率",
    "agent.session.duration": "平均会话时长",
}
```

### 1.4 可观测性架构

```
Agent服务 ──► OpenTelemetry Collector ──► [Prometheus] ──► Grafana
      │                    │
      │                    ▼
      │              [Jaeger/Tempo] ──► 分布式追踪
      │                    │
      │                    ▼
      │              [Loki] ──► 日志聚合
      │
      └──► LangSmith / Langfuse（Agent专用）
```

---

## 第2章 Agent评估体系（AgentEval）

### 2.1 Agent评估的独特挑战

```python
"""
Agent评估 vs 传统ML评估：

传统分类任务：           Agent任务：
────────────────────────────────────────
输入  →  预测  →  对比标签
                          │
                          ▼
                    正确答案可能不唯一！
                    
评估难点：
1. 正确答案不唯一："推荐一本书"有无数正确答案
2. 多步验证：需要验证每一步推理和工具调用的正确性
3. 长周期评估：某些Agent任务需要数分钟才能判断结果
4. 副作用评估：工具调用是否产生了意外的外部影响
5. 用户体验：即使结果正确，体验可能很差（太慢、太啰嗦）
"""
```

### 2.2 任务完成度评估

```python
from enum import Enum
from dataclasses import dataclass

class TaskCompletionLevel(Enum):
    PERFECT = 5      # 完美完成，超出预期
    COMPLETE = 4     # 完成所有要求
    PARTIAL = 3      # 完成部分要求
    MINIMAL = 2      # 仅完成最小要求
    FAILED = 1       # 未完成

@dataclass
class TaskEvaluation:
    task_id: str
    query: str
    expected_outcome: str
    actual_outcome: str
    completion_level: TaskCompletionLevel
    missing_aspects: list[str]
    extra_aspects: list[str]
    
    @property
    def score(self) -> float:
        return self.completion_level.value / 5.0

# LLM-as-Judge：用更强的模型评估Agent输出
def evaluate_with_llm_judge(
    query: str,
    expected: str,
    actual: str,
    judge_model
) -> TaskEvaluation:
    evaluation_prompt = f"""你是一位严格的评估专家。

用户请求：{query}

预期结果：{expected}

Agent实际输出：{actual}

请评估Agent的输出质量：
1. 是否完成了用户的请求？（1-5分）
2. 遗漏了哪些要求？
3. 有哪些不必要的输出？
4. 总体评价（好/中/差）

请以JSON格式输出评估结果。"""
    
    result = judge_model.invoke(evaluation_prompt)
    return parse_evaluation(result)
```

### 2.3 推理质量评估

```python
@dataclass
class ReasoningEvaluation:
    """评估Agent的推理过程质量"""
    trace_id: str
    
    # 逻辑一致性
    logical_consistency: float  # 0-1，推理步骤是否逻辑自洽
    
    # 工具使用恰当性
    tool_appropriateness: float  # 0-1，选择的工具是否合适
    
    # 信息利用度
    information_utilization: float  # 0-1，是否充分利用了获取的信息
    
    # 冗余度
    reasoning_efficiency: float  # 0-1，是否有不必要的推理步骤
    
    # 最终答案与推理的一致性
    conclusion_alignment: float  # 0-1，结论是否由推理支持

# 评估维度示例
REASONING_CRITERIA = {
    "logical_consistency": """
        检查Agent的推理过程是否有逻辑矛盾。
        例如：前面说"需要查询数据库"，后面却说"根据已知信息"...
    """,
    "tool_appropriateness": """
        检查Agent是否选择了正确的工具。
        例如：用户问天气，Agent调用了计算器。
    """,
    "information_utilization": """
        检查Agent是否正确使用了工具返回的数据。
        例如：查询到温度25度，但回答时说"温度未知"。
    """,
    "reasoning_efficiency": """
        检查是否有不必要的推理步骤。
        例如：已经获取了答案，但还在继续调用工具。
    """,
}
```

### 2.4 工具使用准确性评估

```python
@dataclass
class ToolUseEvaluation:
    """评估工具调用的准确性"""
    call_id: str
    tool_name: str
    
    # 工具选择正确性
    correct_tool_selected: bool
    
    # 参数正确性
    parameter_accuracy: float  # 0-1
    missing_required_params: list[str]
    incorrect_param_types: list[str]
    
    # 参数值合理性
    parameter_reasonableness: float  # 0-1
    
    # 执行结果处理
    result_correctly_interpreted: bool

def evaluate_tool_call(
    expected_tool: str,
    expected_params: dict,
    actual_call: dict
) -> ToolUseEvaluation:
    return ToolUseEvaluation(
        call_id=actual_call["id"],
        tool_name=actual_call["name"],
        correct_tool_selected=actual_call["name"] == expected_tool,
        parameter_accuracy=calculate_param_accuracy(expected_params, actual_call["arguments"]),
        missing_required_params=find_missing_params(expected_params, actual_call["arguments"]),
        incorrect_param_types=[],
        parameter_reasonableness=0.8,  # 需要更复杂的评估
        result_correctly_interpreted=True
    )
```

### 2.5 端到端评估框架

```python
import asyncio
from typing import Callable

class AgentBenchmark:
    """Agent基准测试框架"""
    
    def __init__(self):
        self.test_cases: list[TestCase] = []
    
    def add_test_case(self, case: "TestCase"):
        self.test_cases.append(case)
    
    async def run(self, agent_factory: Callable) -> "BenchmarkResult":
        results = []
        
        for case in self.test_cases:
            agent = agent_factory()
            
            # 执行Agent
            try:
                actual_output = await asyncio.wait_for(
                    agent.run(case.input),
                    timeout=case.timeout
                )
                success = case.evaluate(actual_output)
            except asyncio.TimeoutError:
                actual_output = "TIMEOUT"
                success = False
            except Exception as e:
                actual_output = f"ERROR: {e}"
                success = False
            
            results.append({
                "case_id": case.id,
                "input": case.input,
                "expected": case.expected_output,
                "actual": actual_output,
                "success": success,
                "metrics": case.extract_metrics(actual_output)
            })
        
        return BenchmarkResult(results)

@dataclass
class TestCase:
    id: str
    input: str
    expected_output: str
    evaluation_criteria: list[str]
    timeout: float = 60.0
    
    def evaluate(self, actual: str) -> bool:
        # 简化的精确匹配，实际使用LLM-as-Judge或模糊匹配
        return self.expected_output.lower() in actual.lower()
    
    def extract_metrics(self, actual: str) -> dict:
        return {
            "length": len(actual),
            "contains_expected": self.expected_output in actual
        }

# 示例测试集
benchmark = AgentBenchmark()

benchmark.add_test_case(TestCase(
    id="weather_001",
    input="北京今天天气怎么样？",
    expected_output="温度",
    evaluation_criteria=["包含温度信息", "提到北京"]
))

benchmark.add_test_case(TestCase(
    id="math_001",
    input="计算 15 * 23 + 8",
    expected_output="353",
    evaluation_criteria=["计算结果正确"]
))

benchmark.add_test_case(TestCase(
    id="tool_001",
    input="搜索最近的人工智能新闻",
    expected_output="调用了搜索工具",
    evaluation_criteria=["正确调用搜索工具", "返回了新闻结果"]
))
```

---

## 第3章 追踪与调试

### 3.1 Agent执行轨迹记录

```python
class AgentTracer:
    """Agent执行追踪器"""
    
    def __init__(self, exporter: "TraceExporter"):
        self.exporter = exporter
        self.current_trace: AgentTrace | None = None
    
    def start_trace(self, session_id: str, user_id: str) -> str:
        trace_id = generate_trace_id()
        self.current_trace = AgentTrace(
            trace_id=trace_id,
            session_id=session_id,
            user_id=user_id,
            start_time=datetime.now()
        )
        return trace_id
    
    def log_llm_call(
        self,
        prompt: str,
        response: str,
        model: str,
        tokens_in: int,
        tokens_out: int,
        latency_ms: float
    ):
        step = AgentStepTrace(
            step_number=len(self.current_trace.steps) + 1,
            step_type="llm_call",
            start_time=datetime.now(),
            input_data={"prompt": prompt[:1000], "model": model},
            output_data={"response": response[:1000]},
            latency_ms=latency_ms,
            tokens_used=tokens_in + tokens_out,
            cost=calculate_cost(model, tokens_in, tokens_out)
        )
        self.current_trace.steps.append(step)
    
    def log_tool_call(
        self,
        tool_name: str,
        params: dict,
        result: str,
        latency_ms: float,
        error: str | None = None
    ):
        step = AgentStepTrace(
            step_number=len(self.current_trace.steps) + 1,
            step_type="tool_call",
            start_time=datetime.now(),
            input_data={"tool": tool_name, "params": params},
            output_data={"result": str(result)[:500]},
            latency_ms=latency_ms,
            error=error
        )
        self.current_trace.steps.append(step)
    
    def end_trace(self, status: str, final_output: str):
        self.current_trace.end_time = datetime.now()
        self.current_trace.status = status
        self.current_trace.final_output = final_output
        self.exporter.export(self.current_trace)
```

### 3.2 LangSmith / Langfuse 使用

```python
# LangSmith集成（以LangChain为例）
from langchain_openai import ChatOpenAI
from langchain_core.callbacks import LangChainTracer

# 配置LangSmith
import os
os.environ["LANGCHAIN_TRACING_V2"] = "true"
os.environ["LANGCHAIN_API_KEY"] = "your-key"
os.environ["LANGCHAIN_PROJECT"] = "agent-production"

# 自动追踪所有Chain和Agent运行
llm = ChatOpenAI(model="gpt-4o")
# 所有调用自动发送到LangSmith

# Langfuse集成（开源替代）
from langfuse import Langfuse

langfuse = Langfuse(
    public_key="your-public-key",
    secret_key="your-secret-key",
    host="https://cloud.langfuse.com"
)

trace = langfuse.trace(
    name="agent-execution",
    user_id="user_123",
    metadata={"session_id": "sess_456"}
)

# 记录LLM调用
generation = trace.generation(
    name="planning-step",
    model="gpt-4o",
    input=prompt,
    output=response
)

# 记录工具调用
trace.span(
    name="database-query",
    input={"sql": sql_query},
    output=query_result,
    metadata={"execution_time_ms": 150}
)

trace.update(output=final_answer)
```

### 3.3 推理过程可视化

```python
def format_trace_for_display(trace: AgentTrace) -> str:
    """将追踪格式化为可读的文本"""
    lines = [
        f"{'='*60}",
        f"Agent执行追踪: {trace.trace_id}",
        f"状态: {trace.status} | 步数: {trace.step_count} | Token: {trace.total_tokens}",
        f"成本: ${trace.total_cost:.4f} | 耗时: {trace.duration_ms:.0f}ms",
        f"{'='*60}",
    ]
    
    for step in trace.steps:
        lines.append(f"\n[步骤 {step.step_number}] {step.step_type.upper()}")
        lines.append(f"  耗时: {step.latency_ms:.0f}ms | Token: {step.tokens_used}")
        
        if step.step_type == "llm_call":
            lines.append(f"  输入: {step.input_data['prompt'][:200]}...")
            lines.append(f"  输出: {step.output_data['response'][:200]}...")
        
        elif step.step_type == "tool_call":
            lines.append(f"  工具: {step.input_data['tool']}")
            lines.append(f"  参数: {step.input_data['params']}")
            lines.append(f"  结果: {step.output_data['result'][:200]}...")
        
        if step.error:
            lines.append(f"  ⚠️ 错误: {step.error}")
    
    lines.append(f"\n{'='*60}")
    lines.append(f"最终输出: {trace.final_output[:300]}...")
    
    return "\n".join(lines)
```

---

## 第4-7章 内容精要

### 第4章 Agent安全威胁模型
- **Prompt Injection**：用户输入恶意指令覆盖系统提示
- **间接Prompt Injection**：通过外部数据（网页、文档）注入指令
- **工具滥用**：诱导Agent调用危险工具（删除数据、发送邮件）
- **权限提升**：通过社会工程学让Agent执行越权操作
- **数据泄露**：Agent泄露系统提示、训练数据或其他用户信息
- **幻觉利用**：Agent生成虚假信息被恶意利用

### 第5章 安全护栏与防御
- **输入过滤**：检测并阻断已知攻击模式
- **输出审核**：PII检测、毒性检测、事实核查
- **权限最小化**：每个工具只有最小必要权限
- **沙箱执行**：代码执行在隔离环境中
- **人工审核**：高风险操作需要人类确认
- **对抗测试**：定期用攻击Prompt测试系统

### 第6章 合规与治理
- PII检测与脱敏：正则 + NER模型识别敏感信息
- 审计日志：记录所有LLM调用、工具调用、数据访问
- AIGC标识：生成内容添加AI生成标识
- 模型卡片：记录模型能力、限制、风险

### 第7章 实战：安全评估平台
- 构建攻击Prompt数据集（数百个测试用例）
- 自动化安全扫描CI流水线
- 生产环境实时监控异常模式
- 安全事件响应SOP

---

## 本章小结

| 知识点 | 生产级实践 |
|--------|-----------|
| 可观测性 | 日志+指标+追踪三位一体 |
| Agent评估 | LLM-as-Judge + 多维度评分 |
| 执行追踪 | 每一步LLM/工具调用都记录 |
| LangSmith/Langfuse | Agent专用可观测性平台 |
| Prompt Injection | 输入过滤 + 指令与数据分离 |
| 工具安全 | 权限最小化 + 人工确认高风险操作 |
| PII保护 | 自动检测和脱敏敏感信息 |
| 对抗测试 | 定期红队演练发现安全漏洞 |
