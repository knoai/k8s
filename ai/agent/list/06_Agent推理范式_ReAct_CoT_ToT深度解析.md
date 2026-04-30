# 06. Agent推理范式：ReAct、CoT、ToT深度解析

> **目标读者**：已掌握Agent基础开发，希望深入理解Agent决策机制的工程师  
> **核心目标**：掌握主流推理范式的原理、实现与选型策略

---

## 目录

### 第1章 Agent推理的本质（已详细编写）
1.1 为什么LLM需要显式推理  
1.2 推理 = 思考 + 行动 + 观察  
1.3 推理范式的演进路线

### 第2章 Chain-of-Thought（CoT）（已详细编写）
2.1 Zero-Shot CoT："Let's think step by step"  
2.2 Few-Shot CoT：示例驱动的推理  
2.3 Self-Consistency：多路径投票  
2.4 CoT的局限与适用边界

### 第3章 ReAct：推理与行动的协同（已详细编写）
3.1 ReAct的核心思想与循环结构  
3.2 Thought → Action → Observation  
3.3 ReAct Prompt模板设计  
3.4 ReAct的收敛性与终止条件  
3.5 ReAct的代码实现

### 第4章 Tree of Thoughts（ToT）
4.1 从链到树：多路径探索  
4.2 分解、生成、评估、搜索  
4.3 BFS vs DFS搜索策略  
4.4 ToT的成本与效果权衡

### 第5章 ReWOO与Plan-and-Execute
5.1 ReWOO：解耦推理与观察  
5.2 Plan-and-Execute：先规划后执行  
5.3 LLM Compiler：并行计划执行  
5.4 各类范式的对比与选型

### 第6章 高级推理技术
6.1 自我反思（Self-Reflection）  
6.2 辩论与多Agent推理  
6.3 累积推理（Cumulative Reasoning）  
6.4 Program-of-Thoughts：代码作为推理媒介

### 第7章 推理范式在Agent框架中的实现
7.1 LangChain中的ReAct实现  
7.2 自定义推理Agent开发  
7.3 推理轨迹的可视化  
7.4 推理错误的诊断与修正

---

## 第1章 Agent推理的本质

### 1.1 为什么LLM需要显式推理

LLM本质上是一个"下一个token预测器"，其内部推理是隐式的。对于简单问答，这种隐式推理足够；但对于复杂任务，需要显式推理来：

```
隐式推理（直接回答）              显式推理（逐步推理）
    │                               │
    ▼                               ▼
用户：357 × 289 = ?         用户：357 × 289 = ?
LLM：103,173（可能错）       LLM：
                              357 × 289
                              = 357 × (300 - 11)
                              = 357 × 300 - 357 × 11
                              = 107,100 - 3,927
                              = 103,173 ✓
```

**显式推理对Agent的核心价值：**

| 价值 | 说明 |
|------|------|
| **可解释性** | 用户可以追踪Agent的决策过程 |
| **可调试性** | 哪一步错了，一目了然 |
| **可控性** | 在特定步骤注入人工干预 |
| **可靠性** | 分步验证，降低累积错误 |

### 1.2 推理 = 思考 + 行动 + 观察

所有Agent推理范式都可以抽象为三个要素的循环：

```
┌─────────────────────────────────────────────────────┐
│                    Agent 推理循环                     │
│                                                      │
│   ┌─────────┐      ┌─────────┐      ┌─────────┐    │
│   │ Thought │ ───► │ Action  │ ───► │Observation│   │
│   │  思考   │      │  行动   │      │  观察    │    │
│   └────┬────┘      └─────────┘      └────┬────┘    │
│        │                                  │         │
│        └──────────────◄───────────────────┘         │
│                                                      │
│   Thought: "我需要搜索北京的天气"                     │
│   Action: 调用 search(query="北京天气")               │
│   Observation: {"temperature": 25, "condition": "晴"} │
│   Thought: "已经获取天气信息，可以回复用户了"          │
│   Action: 输出最终答案                               │
│                                                      │
└─────────────────────────────────────────────────────┘
```

### 1.3 推理范式的演进路线

```
2022 ──► Chain-of-Thought (CoT)
         └── 让模型"说出"推理过程
         
2022 ──► Self-Consistency CoT
         └── 多条推理路径，多数投票
         
2023 ──► ReAct
         └── 推理 + 行动 + 观察的循环
         
2023 ──► Tree of Thoughts (ToT)
         └── 多路径探索 + 主动评估回溯
         
2023 ──► ReWOO / Plan-and-Execute
         └── 先完整规划，再批量执行
         
2024 ──► Reflexion / LATS / RAP
         └── 自我反思 + 长期记忆优化
```

---

## 第2章 Chain-of-Thought（CoT）

### 2.1 Zero-Shot CoT

最简单有效的推理增强技术：

```python
# 标准Prompt
standard_prompt = "问题：一个农场有鸡和兔，头共35个，脚共94只。鸡兔各几只？\n答案："

# Zero-Shot CoT Prompt
cot_prompt = """问题：一个农场有鸡和兔，头共35个，脚共94只。鸡兔各几只？

让我们逐步思考："""

# 模型输出：
# 设鸡有x只，兔有y只。
# 根据题意：x + y = 35（头的总数）
#          2x + 4y = 94（脚的总数）
# 从第一式得 x = 35 - y
# 代入第二式：2(35-y) + 4y = 94
#            70 - 2y + 4y = 94
#            2y = 24
#            y = 12
# 所以 x = 35 - 12 = 23
# 答案：鸡23只，兔12只。
```

**变体对比：**

| Prompt后缀 | 效果 | 适用场景 |
|-----------|------|----------|
| "让我们逐步思考" | 基准效果 | 通用推理 |
| "让我们一步步解决这个问题" | 类似 | 数学问题 |
| "首先，列出已知条件" | 结构化更好 | 复杂问题 |
| "解释你的推理过程" | 更详细 | 教育场景 |

### 2.2 Few-Shot CoT

```python
few_shot_cot_prompt = """以下是几个推理示例：

示例1：
问题：小明有5个苹果，给了小红2个，又买了3个。现在有几个？
推理：小明开始有5个。给小红2个后，5 - 2 = 3个。又买3个，3 + 3 = 6个。
答案：6个

示例2：
问题：一个水池有两个进水管，A管单独注满需6小时，B管单独注满需4小时。两管齐开，几小时注满？
推理：A管每小时注1/6，B管每小时注1/4。两管每小时共注 1/6 + 1/4 = 5/12。注满需要 12/5 = 2.4小时。
答案：2.4小时

现在请解决：
问题：{question}
推理："""
```

### 2.3 Self-Consistency：多路径投票

```python
import asyncio
from collections import Counter

async def self_consistency_cot(
    llm_client,
    question: str,
    num_paths: int = 5,
    temperature: float = 0.7
) -> str:
    """
    Self-Consistency CoT：生成多条推理路径，取最常见的答案
    """
    # 生成多条推理路径
    tasks = [
        llm_client.generate(
            prompt=f"问题：{question}\n让我们逐步思考：",
            temperature=temperature  # 使用较高温度增加多样性
        )
        for _ in range(num_paths)
    ]
    
    responses = await asyncio.gather(*tasks)
    
    # 提取每条路径的最终答案（简化处理，实际需要更鲁棒的提取逻辑）
    answers = []
    for resp in responses:
        # 假设答案在最后一行，格式为"答案：xxx"
        lines = resp.strip().split('\n')
        for line in reversed(lines):
            if '答案' in line or 'answer' in line.lower():
                answers.append(line.split('：')[-1].strip())
                break
    
    # 多数投票
    vote_result = Counter(answers)
    most_common = vote_result.most_common(1)[0]
    
    return {
        "answer": most_common[0],
        "confidence": most_common[1] / num_paths,
        "all_paths": responses,
        "vote_distribution": dict(vote_result)
    }
```

### 2.4 CoT的局限与适用边界

| 局限 | 说明 | 解决方案 |
|------|------|----------|
| 无法使用外部信息 | 纯文本推理，不能查询实时数据 | 结合ReAct使用工具 |
| 单一路径 | 一旦走错无法回溯 | 使用ToT多路径探索 |
| 无自我修正 | 不会检查中间步骤的正确性 | 添加验证和反思步骤 |
| 长推理易出错 | 步骤越多，累积错误概率越大 | 分解为更短子任务 |

**适用场景：** 数学计算、逻辑推理、文本分析等不需要外部信息的任务。

---

## 第3章 ReAct：推理与行动的协同

### 3.1 ReAct的核心思想

ReAct（Reasoning + Acting）将CoT的推理能力与工具使用结合，形成"思考 → 行动 → 观察"的循环。

```
传统CoT：                    ReAct：
Thought1                    Thought1: 需要搜索信息
Thought2                    Action1: search(query="...")
Thought3                    Observation1: 搜索结果...
Answer                      Thought2: 基于搜索结果...
                            Action2: calculate(...)
                            Observation2: 计算结果...
                            Thought3: 可以得出答案
                            Action3: Finish[答案]
```

### 3.2 Thought → Action → Observation 详解

```python
from dataclasses import dataclass
from typing import Literal

@dataclass
class ReActStep:
    step_number: int
    thought: str          # 思考：当前状态分析 + 下一步计划
    action_type: Literal["tool", "finish", "clarify"]
    action: str           # 行动：工具调用或最终答案
    observation: str | None = None  # 观察：工具返回结果

# ReAct轨迹示例
trajectory = [
    ReActStep(
        step_number=1,
        thought="用户想知道2024年诺贝尔物理学奖得主。我需要搜索这个信息。",
        action_type="tool",
        action="search(query='2024年诺贝尔物理学奖得主')",
        observation="2024年诺贝尔物理学奖授予John Hopfield和Geoffrey Hinton..."
    ),
    ReActStep(
        step_number=2,
        thought="已经获取到信息，可以回答用户了。",
        action_type="finish",
        action="2024年诺贝尔物理学奖授予John J. Hopfield和Geoffrey E. Hinton..."
    )
]
```

### 3.3 ReAct Prompt模板设计

```python
REACT_PROMPT_TEMPLATE = """回答以下问题。你可以使用以下工具：

{tools_description}

请使用以下格式：

思考：你当前应该做什么
行动：工具名称[参数]
观察：工具返回的结果
...（这个思考/行动/观察的循环可以重复多次）
思考：我现在知道最终答案
最终答案：问题的答案

开始！

问题：{question}

思考："""

# 更精细的版本（用于Function Calling模型）
REACT_FUNCTION_CALLING_PROMPT = """你是一个智能助手，需要通过思考和使用工具来解决问题。

可用工具：
{tools_description}

请遵循以下规则：
1. 首先分析当前状态，思考下一步需要什么信息
2. 如果需要外部信息，调用相应工具
3. 获得观察结果后，继续思考下一步
4. 当获得足够信息时，直接回答用户

问题：{question}

当前对话历史：
{history}
"""
```

### 3.4 ReAct的收敛性与终止条件

```python
class ReActExecutor:
    """ReAct执行引擎"""
    
    def __init__(
        self,
        llm_client,
        tools: dict[str, callable],
        max_iterations: int = 10,
        max_think_tokens: int = 500
    ):
        self.llm = llm_client
        self.tools = tools
        self.max_iterations = max_iterations
        self.max_think_tokens = max_think_tokens
    
    async def execute(self, question: str) -> dict:
        history = []
        
        for iteration in range(self.max_iterations):
            # 构建当前上下文
            context = self._build_context(question, history)
            
            # 调用LLM获取下一步
            response = await self.llm.generate_with_tools(
                context,
                tools=self._get_tool_schemas()
            )
            
            # 检查是否是最终答案
            if response.is_final_answer:
                return {
                    "success": True,
                    "answer": response.content,
                    "steps": history,
                    "iterations": iteration + 1
                }
            
            # 执行工具调用
            if response.tool_calls:
                for tool_call in response.tool_calls:
                    try:
                        result = await self._execute_tool(tool_call)
                        observation = str(result)
                    except Exception as e:
                        observation = f"错误：{str(e)}"
                    
                    history.append({
                        "iteration": iteration,
                        "thought": response.thought,
                        "action": tool_call,
                        "observation": observation
                    })
            else:
                # LLM没有调用工具也没有给出答案，可能是困惑了
                history.append({
                    "iteration": iteration,
                    "thought": response.content,
                    "action": None,
                    "observation": "未执行任何操作"
                })
        
        # 达到最大迭代次数
        return {
            "success": False,
            "answer": "无法在限定步数内找到答案",
            "steps": history,
            "iterations": self.max_iterations
        }
    
    def _build_context(self, question: str, history: list) -> str:
        """构建ReAct上下文，包含问题、历史步骤"""
        lines = [f"问题：{question}\n"]
        for step in history:
            lines.append(f"思考：{step['thought']}")
            if step['action']:
                lines.append(f"行动：{step['action']}")
                lines.append(f"观察：{step['observation']}")
        lines.append("思考：")
        return "\n".join(lines)
```

### 3.5 ReAct的代码实现

```python
import json
from typing import AsyncIterator

class StreamingReActAgent:
    """
    流式ReAct Agent：实时展示思考过程
    """
    
    async def run(self, question: str) -> AsyncIterator[dict]:
        """生成ReAct执行过程的事件流"""
        messages = [
            {"role": "system", "content": self.system_prompt},
            {"role": "user", "content": question}
        ]
        
        for i in range(self.max_iterations):
            # 思考阶段
            yield {"type": "thinking", "content": "正在思考...", "step": i}
            
            response = await self.llm.chat.completions.create(
                model=self.model,
                messages=messages,
                tools=self.tools_schema,
                stream=True
            )
            
            content_parts = []
            tool_calls = {}
            
            async for chunk in response:
                delta = chunk.choices[0].delta
                
                if delta.content:
                    content_parts.append(delta.content)
                    yield {"type": "thought_token", "content": delta.content, "step": i}
                
                if delta.tool_calls:
                    for tc in delta.tool_calls:
                        idx = tc.index
                        if idx not in tool_calls:
                            tool_calls[idx] = {"id": "", "name": "", "args": ""}
                        if tc.id:
                            tool_calls[idx]["id"] += tc.id
                        if tc.function.name:
                            tool_calls[idx]["name"] += tc.function.name
                        if tc.function.arguments:
                            tool_calls[idx]["args"] += tc.function.arguments
            
            # 处理工具调用
            if tool_calls:
                for tc in tool_calls.values():
                    yield {
                        "type": "action", 
                        "tool": tc["name"],
                        "args": json.loads(tc["args"]),
                        "step": i
                    }
                    
                    # 执行工具
                    result = await self.execute_tool(tc["name"], json.loads(tc["args"]))
                    yield {"type": "observation", "content": str(result), "step": i}
                    
                    # 将结果加入上下文
                    messages.append({
                        "role": "tool",
                        "tool_call_id": tc["id"],
                        "content": str(result)
                    })
            else:
                # 没有工具调用，认为是最终答案
                final_answer = "".join(content_parts)
                yield {"type": "final_answer", "content": final_answer}
                return
        
        yield {"type": "error", "content": "达到最大迭代次数"}
```

---

## 第4-7章 内容精要

### 第4章 Tree of Thoughts（ToT）
- 将线性推理链扩展为树形搜索
- 四个阶段：问题分解 → 候选生成 → 状态评估 → 搜索（BFS/DFS）
- 适用于：创意写作、数学证明、策略规划等需要探索多种方案的任务
- 成本较高：需要大量LLM调用进行节点生成和评估

### 第5章 ReWOO与Plan-and-Execute
- **ReWOO**：将推理（Reasoning）与观察（Observation）解耦，先制定完整计划再执行
- **Plan-and-Execute**：先由Planner生成步骤计划，再由Executor逐个执行
- **LLM Compiler**：识别计划中的独立步骤，并行执行
- **选型**：简单任务用ReAct，复杂多步任务用Plan-and-Execute，需要探索用ToT

### 第6章 高级推理技术
- **Self-Reflection**：Agent评估自己的输出，发现错误并修正
- **Debate**：多个Agent持不同观点辩论，提升答案质量
- **Program-of-Thoughts**：让模型生成Python代码来解决问题，用代码执行器运行

### 第7章 推理范式在框架中的实现
- LangChain `AgentType.ZERO_SHOT_REACT_DESCRIPTION`
- LangGraph中的循环节点实现ReAct
- 自定义Agent：选择推理范式 → 实现执行循环 → 集成工具调用

---

## 范式对比总结

| 范式 | 核心思想 | 工具使用 | 多路径 | 适用场景 | 成本 |
|------|----------|----------|--------|----------|------|
| **CoT** | 逐步思考 | ❌ | ❌ | 数学/逻辑推理 | 低 |
| **Self-Consistency CoT** | 多路径投票 | ❌ | ✅ | 需要高置信度答案 | 中 |
| **ReAct** | 思考+行动循环 | ✅ | ❌ | 通用Agent任务 | 中 |
| **ToT** | 树形搜索 | ✅ | ✅ | 复杂规划/创意 | 高 |
| **Plan-and-Execute** | 先规划后执行 | ✅ | ❌ | 多步骤复杂任务 | 中 |
| **ReWOO** | 解耦推理与观察 | ✅ | ❌ | 需要减少LLM调用 | 低 |

---

## 本章小结

| 知识点 | Agent开发应用 |
|--------|--------------|
| CoT | 增强Agent的数学和逻辑推理能力 |
| Self-Consistency | 关键决策场景提升答案可靠性 |
| ReAct | 构建通用工具使用Agent的基础范式 |
| ToT | 复杂任务的多路径探索和最优解搜索 |
| Plan-and-Execute | 复杂多步任务的预规划执行 |
| ReWOO | 减少冗余LLM调用，提升执行效率 |
| 流式ReAct | 实时向用户展示Agent思考过程 |
