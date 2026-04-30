# 03. Prompt Engineering实战：与AI高效对话

> **目标读者**：已了解LLM基础，希望系统掌握提示工程技术的开发者  
> **核心目标**：掌握Prompt设计模式、结构化输出、少样本学习及系统提示优化策略  
> **预计阅读时间**：30小时

---

## 目录

- [第1章 Prompt Engineering的Agent价值](#第1章-prompt-engineering的agent价值)
- [第2章 Prompt核心设计原则](#第2章-prompt核心设计原则)
- [第3章 结构化Prompt设计](#第3章-结构化prompt设计)
- [第4章 Agent专用Prompt模式](#第4章-agent专用prompt模式)
- [第5章 输出控制与格式约束](#第5章-输出控制与格式约束)
- [第6章 Prompt优化与评估](#第6章-prompt优化与评估)
- [第7章 实战：为Agent设计工业级Prompt系统](#第7章-实战为agent设计工业级prompt系统)

---

## 第1章 Prompt Engineering的Agent价值

### 1.1 为什么Agent开发必须精通Prompt Engineering

在Agent系统中，Prompt不是"和AI对话的方式"，而是**系统的核心控制逻辑**。理解这一点至关重要：

```
传统软件：控制流 = 代码（if/else, for, function call）
Agent系统：控制流 = Prompt + LLM推理

用户输入 ──► [系统提示] + [历史记忆] + [当前任务] ──► LLM
                                                  │
                                                  ▼
                                          Thought / Action
                                                  │
                              ┌───────────────────┼───────────────────┐
                              ▼                   ▼                   ▼
                         [直接回答]          [工具调用]          [请求澄清]
```

**Prompt在Agent中的角色：**

| 角色 | 说明 | 示例 |
|------|------|------|
| **行为控制器** | 定义Agent能做什么、不能做什么 | "你只能使用以下工具..." |
| **格式化器** | 强制输出符合特定结构 | "你必须输出JSON格式..." |
| **推理引导器** | 引导模型按特定方式思考 | "让我们逐步思考..." |
| **知识注入器** | 提供任务所需的背景知识 | "你是某领域的专家..." |
| **安全护栏** | 防止有害输出 | "如果用户请求违法内容，拒绝..." |

### 1.2 Prompt质量对Agent性能的影响

```python
"""
研究表明，在Agent任务中，Prompt工程的影响权重分布：

Agent任务成功率影响因素：
├── Prompt设计质量        ████████████████ 35%
├── 模型基础能力          ████████████     25%
├── 工具设计质量          ████████         18%
├── 记忆/上下文管理       ██████           12%
├── 错误处理机制          ████              7%
└── 其他因素              ██                3%

Prompt设计是Agent系统中最大的可控变量。
"""
```

**反例分析：一个糟糕的Agent Prompt**

```
❌ 你是一个Agent，请帮我解决问题。你可以使用工具。
```

**问题诊断：**
1. **没有定义角色边界** → Agent可能越权操作（如删除数据）
2. **没有说明可用工具** → 模型不知道能做什么
3. **没有指定输出格式** → 程序无法解析响应
4. **没有错误处理指导** → 遇到异常会混乱输出
5. **没有终止条件** → 可能无限循环

### 1.3 提示工程的常见误区与反模式

| 反模式 | 表现 | 正确做法 |
|--------|------|----------|
| **提示词堆砌** | 把20条规则塞在一个Prompt里 | 分层设计：系统提示 + 动态上下文 |
| **过度假设** | 假设模型知道业务规则 | 显式声明所有约束条件 |
| **否定指令** | "不要做这个" | 改为正面指令："请只执行..." |
| **模糊目标** | "请分析一下" | "请输出3个要点，每个不超过50字" |
| **静态提示** | 所有场景用同一Prompt | 根据任务类型动态选择提示模板 |
| **忽视边界情况** | 只测试正常流程 | 明确告诉模型异常时如何处理 |
| **Prompt漂移** | 生产环境Prompt与测试不同 | 版本管理、A/B测试 |

---

## 第2章 Prompt核心设计原则

### 2.1 清晰性、具体性与可验证性

**清晰性原则**：消除歧义，让意图明确无误。

```
❌ 模糊：请处理这个请求
✅ 清晰：请判断用户意图属于以下之一：[查询余额, 转账, 修改密码, 其他]
       如果是转账，请提取收款人姓名和金额；
       如果是查询余额，请直接回复余额；
       如果是其他，请礼貌地告知用户当前支持的功能。
```

**具体性原则**：给出明确的输入、处理和输出规范。

```python
SYSTEM_PROMPT_TEMPLATE = """你是一个智能客服Agent。你的任务是帮助用户处理银行业务。

## 可用工具
{tools_description}

## 处理规则
1. 首先判断用户意图，意图必须是以下之一：{allowed_intents}
2. 如果意图需要工具支持，输出工具调用格式
3. 如果信息不完整，向用户询问缺失的必填字段
4. 每次回复前，先说明你的思考过程
5. 如果用户请求超出业务范围，礼貌拒绝并说明原因

## 输出格式
你必须严格按以下格式回复：

思考：[你的推理过程，说明为什么做出这个选择]

意图：[识别的意图，必须是allowed_intents之一]

行动：[tool_call:工具名(参数) / direct_reply:直接回复内容 / ask_info:询问的信息]

回复：[给用户的最终回复，友好且专业]
"""
```

**可验证性原则**：输出应可被程序验证。

```python
from pydantic import BaseModel, Field, validator
from typing import Literal

class AgentDecision(BaseModel):
    """Agent决策的结构化输出"""
    thought: str = Field(..., min_length=10, description="思考过程")
    intent: Literal["query_balance", "transfer", "change_password", "other"]
    confidence: float = Field(..., ge=0.0, le=1.0)
    action_type: Literal["tool_call", "direct_reply", "ask_info"]
    action_detail: dict = Field(default_factory=dict)
    user_response: str = Field(..., min_length=1)
    
    @validator("action_detail")
    def validate_action_detail(cls, v, values):
        action_type = values.get("action_type")
        if action_type == "tool_call" and "tool_name" not in v:
            raise ValueError("tool_call action must have tool_name")
        return v
```

### 2.2 角色设定与上下文构建

```python
from dataclasses import dataclass
from typing import List

@dataclass
class AgentPersona:
    """
    Agent角色设定模板。
    
    为什么角色设定如此重要？
    - 约束行为边界：什么能做、什么不能做
    - 影响语气风格：专业严谨 vs 轻松友好
    - 注入领域知识：让模型"变成"领域专家
    - 提升一致性：相同问题得到相似回答
    """
    role: str
    expertise: List[str]
    tone: str
    constraints: List[str]
    workflow: List[str]
    examples: List[dict] = None
    
    def to_system_prompt(self) -> str:
        lines = [
            f"# 角色设定",
            f"你是{self.role}。",
            f"",
            f"## 专长领域",
        ]
        for e in self.expertise:
            lines.append(f"- {e}")
        
        lines.extend([
            f"",
            f"## 沟通风格",
            self.tone,
            f"",
            f"## 行为约束（严格遵循）",
        ])
        for i, c in enumerate(self.constraints, 1):
            lines.append(f"{i}. {c}")
        
        lines.extend([
            f"",
            f"## 标准工作流程",
        ])
        for i, s in enumerate(self.workflow, 1):
            lines.append(f"{i}. {s}")
        
        if self.examples:
            lines.extend([f"", f"## 示例"])
            for ex in self.examples:
                lines.append(f"输入：{ex['input']}")
                lines.append(f"输出：{ex['output']}")
                lines.append("")
        
        return "\n".join(lines)

# 创建数据分析师Agent
analyst = AgentPersona(
    role="资深数据分析师Agent",
    expertise=[
        "SQL查询优化",
        "数据可视化设计",
        "统计分析与假设检验",
        "业务指标解读与洞察提取"
    ],
    tone="专业、严谨、简洁。使用数据支撑结论，不臆测。对不确定的数据明确标注。",
    constraints=[
        "绝不执行任何修改数据库的操作（INSERT/UPDATE/DELETE/DROP）",
        "所有数据查询必须附带明确的时间范围",
        "不确定时明确说明'数据不足，无法得出结论'，绝不编造数据",
        "涉及敏感数据时提醒'以下为脱敏数据，仅供分析参考'",
        "复杂查询前先说明查询逻辑和预期结果"
    ],
    workflow=[
        "理解用户的分析需求，确认指标定义和时间维度",
        "评估数据可用性和质量，识别潜在的数据偏差",
        "设计最优查询方案，考虑性能和准确性",
        "执行查询并验证结果合理性（数量级、异常值检查）",
        "输出分析结论，区分事实和推断，给出可执行建议"
    ],
    examples=[
        {
            "input": "最近一周销售额下降了吗？",
            "output": "思考：需要查询最近7天的销售额并与前7天对比...\n查询：SELECT...\n结论：下降15%，主要由于..."
        }
    ]
)

print(analyst.to_system_prompt())
```

### 2.3 任务分解与指令链

复杂任务应分解为多个子任务，每个子任务使用专门的Prompt：

```python
from typing import Callable, Any, Coroutine
import asyncio

class PromptChain:
    """
    提示链：将复杂任务分解为连续的Prompt调用。
    
    设计模式：
    每个步骤接收前一步的输出，进行特定处理，传递给下一步。
    步骤间通过强类型接口通信，确保数据质量。
    """
    
    def __init__(self, llm_client):
        self.llm = llm_client
        self.steps: List[Callable] = []
    
    def add_step(self, step: Callable):
        self.steps.append(step)
        return self
    
    async def execute(self, initial_input: str) -> Any:
        current = initial_input
        step_outputs = []
        
        for i, step in enumerate(self.steps):
            print(f"[Step {i+1}/{len(self.steps)}] 执行中...")
            current = await step(self.llm, current, step_outputs)
            step_outputs.append(current)
        
        return current

# 定义各个步骤的Prompt模板

STEP1_INTENT_ANALYSIS = """分析以下用户请求，提取关键信息。

用户输入：{input}

请输出JSON格式：
{{
    "primary_intent": "主要意图（20字以内）",
    "secondary_intents": ["次要意图"],
    "entities": {{"实体名": "实体值"}},
    "urgency": "high/medium/low",
    "ambiguity_score": "0.0-1.0（越高越模糊）",
    "missing_info": ["完成任务还缺失的信息"]
}}
"""

STEP2_PLAN_GENERATION = """基于以下分析结果，制定执行计划。

分析结果：{analysis}

可用工具：{tools}

请输出执行步骤列表（JSON数组），每个步骤包含：
{{
    "step_id": 1,
    "description": "步骤描述",
    "tool": "使用的工具名或'direct_reply'",
    "input": {{参数}},
    "expected_output": "预期输出",
    "fallback": "如果该步骤失败的替代方案"
}}

注意事项：
- 尽量并行化独立的步骤
- 每个步骤的输出应明确可验证
- 如果不需要工具，直接给出回答
"""

STEP3_EXECUTION_REVIEW = """审查以下执行计划。

原始请求：{original_request}
执行计划：{plan}

请评估：
1. 计划是否完整覆盖了用户需求？
2. 是否有冗余步骤可以删除？
3. 是否存在潜在风险？
4. 给出优化后的计划。

输出格式：
{{
    "is_complete": true/false,
    "issues": ["发现的问题"],
    "optimized_plan": [优化后的步骤],
    "risk_level": "low/medium/high"
}}
"""

# 使用示例
async def step1_analyze(llm, user_input: str, history: list) -> dict:
    prompt = STEP1_INTENT_ANALYSIS.format(input=user_input)
    response = await llm.generate_json(prompt)
    return response

async def step2_plan(llm, analysis: dict, history: list) -> dict:
    prompt = STEP2_PLAN_GENERATION.format(
        analysis=analysis,
        tools="[search, calculate, query_db]"
    )
    response = await llm.generate_json(prompt)
    return response

async def step3_review(llm, plan: dict, history: list) -> dict:
    original = history[0] if history else ""
    prompt = STEP3_EXECUTION_REVIEW.format(
        original_request=original,
        plan=plan
    )
    response = await llm.generate_json(prompt)
    return response
```

### 2.4 少样本学习（Few-Shot Learning）

```python
class FewShotPromptBuilder:
    """
    少样本提示构建器。
    
    核心洞察：
    - 0-shot：直接提问，模型用预训练知识回答
    - 1-shot：给一个示例，模型模仿格式
    - 3-5 shot：给多个示例，模型学习模式
    - 太多示例：超出上下文窗口，效果反而下降
    
    示例选择策略：
    1. 覆盖不同场景（边缘案例）
    2. 与当前查询相似（语义检索）
    3. 从简单到复杂（渐进学习）
    """
    
    def __init__(self):
        self.examples: List[tuple] = []
        self.max_examples = 5
    
    def add_example(self, input_text: str, output_text: str, reasoning: str = ""):
        self.examples.append({
            "input": input_text,
            "output": output_text,
            "reasoning": reasoning
        })
        return self
    
    def build(self, task_description: str, test_input: str, include_reasoning: bool = True) -> str:
        lines = [
            task_description,
            "",
            "以下是一些示例：",
            ""
        ]
        
        for i, ex in enumerate(self.examples[-self.max_examples:], 1):
            lines.extend([
                f"### 示例 {i}",
                f"输入：{ex['input']}",
            ])
            if include_reasoning and ex["reasoning"]:
                lines.append(f"推理：{ex['reasoning']}")
            lines.extend([
                f"输出：{ex['output']}",
                ""
            ])
        
        lines.extend([
            "现在请处理以下输入：",
            f"输入：{test_input}",
        ])
        if include_reasoning:
            lines.append("推理：")
        lines.append("输出：")
        
        return "\n".join(lines)
    
    def build_with_embedding_selection(
        self,
        task_description: str,
        test_input: str,
        embedder,  # 嵌入模型
        top_k: int = 3
    ) -> str:
        """
        基于语义相似度选择最相关的示例。
        比随机选择效果更好。
        """
        import numpy as np
        
        test_embedding = embedder.embed(test_input)
        
        similarities = []
        for ex in self.examples:
            ex_embedding = embedder.embed(ex["input"])
            sim = np.dot(test_embedding, ex_embedding)
            similarities.append((sim, ex))
        
        # 选择最相似的top_k个
        similarities.sort(key=lambda x: x[0], reverse=True)
        selected = [ex for _, ex in similarities[:top_k]]
        
        lines = [task_description, "", "以下是相关示例：", ""]
        for i, ex in enumerate(selected, 1):
            lines.extend([
                f"### 示例 {i}",
                f"输入：{ex['input']}",
                f"输出：{ex['output']}",
                ""
            ])
        
        lines.extend([
            "现在请处理以下输入：",
            f"输入：{test_input}",
            "输出："
        ])
        
        return "\n".join(lines)

# 工具选择任务的少样本提示
builder = FewShotPromptBuilder()
builder.add_example(
    "用户说：'帮我查一下北京的天气'",
    '{"tool": "weather_query", "params": {"city": "北京", "date": "today"}}',
    "用户询问天气，需要调用天气查询工具"
)
builder.add_example(
    "用户说：'转账给张三100块'",
    '{"tool": "transfer", "params": {"recipient": "张三", "amount": 100, "currency": "CNY"}}',
    "用户要进行转账，提取收款人和金额"
)
builder.add_example(
    "用户说：'谢谢你的帮助'",
    '{"tool": "none", "response": "不客气！有其他需要随时告诉我。"}',
    "用户表达感谢，不需要调用工具"
)
builder.add_example(
    "用户说：'3的平方根是多少'",
    '{"tool": "calculate", "params": {"expression": "sqrt(3)"}}',
    "数学计算问题，使用计算器工具"
)

prompt = builder.build(
    task_description="根据用户输入，选择合适的工具或回复。输出JSON格式。",
    test_input="用户说：'明天上海下雨吗'"
)
print(prompt)
```

---

## 第3章 结构化Prompt设计

### 3.1 XML/JSON/Markdown结构化格式

不同模型对不同格式的理解能力有差异。实证研究表明：**在Prompt中使用Markdown格式通常效果最好**。

```python
# Markdown格式（推荐用于复杂Prompt）
MARKDOWN_PROMPT_TEMPLATE = """# 任务说明
{task_description}

# 输入数据
```
{input_data}
```

# 处理规则
{rules}

# 输出格式
请以以下JSON格式输出：
```json
{{
  "analysis": "分析过程",
  "result": "最终结果",
  "confidence": 0.95
}}
```
"""

# XML格式（适合严格的分段，Claude对此格式响应良好）
XML_PROMPT_TEMPLATE = """<instruction>
  <task>{task}</task>
  <context>
    <history>{conversation_history}</history>
    <facts>{known_facts}</facts>
  </context>
  <constraints>
    <constraint>必须基于提供的事实</constraint>
    <constraint>不确定时请说明</constraint>
  </constraints>
  <output_format>
    <format>JSON</format>
    <schema>{{"result": "string"}}</schema>
  </output_format>
</instruction>"""

# 为什么Markdown效果好？
"""
1. 训练数据：互联网上的Markdown内容非常丰富
2. 视觉层次：标题、列表、代码块提供了清晰的视觉结构
3. 模型熟悉：代码训练数据中大量Markdown文档
4. 人类可读：开发者容易编写和维护
"""
```

### 3.2 Chain-of-Thought提示：让模型逐步思考

#### 3.2.1 Zero-Shot CoT

```python
# 最简单的CoT变体，只需在Prompt末尾添加一句话

ZERO_SHOT_COT_PROMPTS = {
    "standard": "让我们逐步思考。",
    "detailed": "让我们一步一步地分析这个问题，先列出已知条件，再推导结论。",
    "structured": "请按以下步骤思考：\n1. 理解问题\n2. 识别关键信息\n3. 分析关系\n4. 得出结论\n5. 验证结果",
    "expert": "作为领域专家，请展示你的完整推理过程，包括中间步骤和验证。",
}

# 效果对比实验
EXPERIMENT_RESULTS = {
    "task": "数学应用题",
    "baseline": 0.18,      # 直接回答准确率
    "lets_think": 0.57,    # "Let's think step by step"
    "structured": 0.62,    # 结构化思考步骤
    "few_shot_cot": 0.78,  # 少样本CoT
}
```

#### 3.2.2 Few-Shot CoT

```python
FEW_SHOT_COT_PROMPT = """请逐步推理解决问题。

示例1：
问题：小明有5个苹果，给了小红2个，又买了3个。现在有几个？
推理：
步骤1：小明开始有5个苹果。
步骤2：给小红2个后，5 - 2 = 3个。
步骤3：又买3个，3 + 3 = 6个。
步骤4：验证：5 - 2 + 3 = 6，计算正确。
答案：6个

示例2：
问题：一个水池有两个进水管，A管单独注满需6小时，B管单独注满需4小时。两管齐开，几小时注满？
推理：
步骤1：A管每小时注1/6池水。
步骤2：B管每小时注1/4池水。
步骤3：两管每小时共注 1/6 + 1/4 = 5/12 池水。
步骤4：注满1池需要 1 / (5/12) = 12/5 = 2.4小时。
步骤5：验证：2.4小时 × 5/12 = 1池，正确。
答案：2.4小时

示例3：
问题：{question}
推理："""
```

### 3.3 系统提示、用户提示与助手提示的分层设计

```python
from dataclasses import dataclass
from typing import Literal, List

@dataclass
class Message:
    role: Literal["system", "user", "assistant", "tool"]
    content: str
    name: str = None

class LayeredPromptBuilder:
    """
    分层提示构建器。
    
    三层架构：
    - 系统层（System）：角色、规则、约束（相对静态）
    - 上下文层（Context）：历史对话、记忆（动态变化）
    - 任务层（Task）：当前具体指令（每次变化）
    
    这种分层使得：
    1. 系统提示可以缓存（如果模型支持）
    2. 上下文可以按需加载
    3. 任务提示简洁明了
    """
    
    def __init__(self):
        self.system_layer: str = ""
        self.context_layer: List[Message] = []
        self.task_layer: str = ""
    
    def set_system(self, role: str, rules: List[str], tools: List[dict], safety: List[str]):
        tool_desc = "\n".join(
            f"- {t['name']}: {t['description']}"
            for t in tools
        )
        
        self.system_layer = f"""# 角色
{role}

# 规则
{chr(10).join(f"{i+1}. {r}" for i, r in enumerate(rules))}

# 可用工具
{tool_desc}

# 安全约束
{chr(10).join(f"- {s}" for s in safety)}

# 重要提醒
- 你必须严格遵守上述规则
- 如果用户请求超出规则范围，请礼貌拒绝
- 始终先思考再行动
- 如果信息不足，主动询问而非猜测
"""
    
    def add_context(self, history: List[dict], max_turns: int = 10):
        """添加对话历史，只保留最近N轮"""
        recent = history[-max_turns * 2:] if len(history) > max_turns * 2 else history
        self.context_layer = [
            Message(role=m["role"], content=m["content"])
            for m in recent
        ]
    
    def set_task(self, task: str, input_data: str = None, expected_format: str = None):
        self.task_layer = f"""# 当前任务
{task}"""
        if input_data:
            self.task_layer += f"\n\n# 输入数据\n{input_data}"
        if expected_format:
            self.task_layer += f"\n\n# 期望输出格式\n{expected_format}"
    
    def build(self) -> List[Message]:
        messages = [Message(role="system", content=self.system_layer)]
        messages.extend(self.context_layer)
        messages.append(Message(role="user", content=self.task_layer))
        return messages
    
    def estimate_tokens(self, counter) -> int:
        """估算总token数"""
        msgs = self.build()
        return counter.count_messages([{"role": m.role, "content": m.content} for m in msgs])

# 使用
builder = LayeredPromptBuilder()
builder.set_system(
    role="你是一个智能数据分析助手",
    rules=[
        "只读取数据，不修改数据",
        "所有查询必须包含时间范围",
        "结果必须标注置信度"
    ],
    tools=[
        {"name": "sql_query", "description": "执行SQL查询"},
        {"name": "chart", "description": "生成图表"}
    ],
    safety=[
        "不执行DELETE/DROP等破坏性操作",
        "敏感数据需要脱敏"
    ]
)

builder.add_context([
    {"role": "user", "content": "你好"},
    {"role": "assistant", "content": "你好！我是数据分析助手。"}
])

builder.set_task(
    task="分析Q3销售数据",
    input_data="表：sales (id, date, amount, region)",
    expected_format="JSON格式：{summary, insights, recommendations}"
)

messages = builder.build()
for m in messages:
    print(f"[{m.role}] {m.content[:100]}...")
```

### 3.4 动态Prompt模板与变量注入

```python
from string import Template
import json
from typing import Any

class DynamicPromptTemplate:
    """
    动态Prompt模板：支持复杂变量注入和条件渲染。
    """
    
    def __init__(self, template: str):
        self.template = Template(template)
    
    def render(self, **kwargs) -> str:
        """渲染模板，自动序列化复杂对象"""
        processed = {}
        for key, value in kwargs.items():
            if isinstance(value, (list, dict)):
                processed[key] = json.dumps(value, ensure_ascii=False, indent=2)
            elif isinstance(value, str):
                processed[key] = value
            else:
                processed[key] = str(value)
        return self.template.safe_substitute(**processed)
    
    @classmethod
    def with_conditionals(cls, template: str):
        """支持条件渲染的模板"""
        return ConditionalPromptTemplate(template)

class ConditionalPromptTemplate:
    """支持条件块的Prompt模板"""
    
    def __init__(self, template: str):
        self.template = template
    
    def render(self, **kwargs) -> str:
        result = self.template
        
        # 处理条件块：{{#if condition}}...{{/if}}
        import re
        
        def replace_condition(match):
            condition = match.group(1).strip()
            content = match.group(2)
            
            # 简单条件求值
            if condition in kwargs and kwargs[condition]:
                return content
            return ""
        
        result = re.sub(
            r'\{\{#if\s+(\w+)\}\}(.*?)\{\{/if\}\}',
            replace_condition,
            result,
            flags=re.DOTALL
        )
        
        # 替换变量
        for key, value in kwargs.items():
            if isinstance(value, (list, dict)):
                value = json.dumps(value, ensure_ascii=False, indent=2)
            result = result.replace(f"{{{key}}}", str(value))
        
        return result

# 使用示例
tool_call_template = ConditionalPromptTemplate("""
根据用户请求和可用工具，决定下一步行动。

## 用户请求
{user_request}

## 对话历史
{history}

## 可用工具
{tools}

{{#if last_result}}
## 上一步执行结果
{last_result}
{{/if}}

{{#if error}}
## 之前发生的错误
{error}
请修正你的方法。
{{/if}}

请输出你的思考过程和下一步行动：
""")

prompt = tool_call_template.render(
    user_request="帮我订一张明天北京到上海的机票",
    history="[之前的对话...]",
    tools='["search_flights", "book_ticket"]',
    last_result=None,
    error=None
)
print(prompt)
```

---

## 第4章 Agent专用Prompt模式

### 4.1 ReAct Prompt模板

```python
REACT_PROMPT_V1 = """回答以下问题。你可以使用以下工具：

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

# 改进版：用于Function Calling模型
REACT_PROMPT_FUNCTION_CALLING = """你是一个智能助手，需要通过思考和使用工具来解决问题。

可用工具：
{tools_description}

请遵循以下规则：
1. 首先分析当前状态，思考下一步需要什么信息
2. 如果需要外部信息，调用相应工具
3. 获得观察结果后，继续思考下一步
4. 当获得足够信息时，直接回答用户
5. 如果陷入困境，尝试不同的方法
6. 最多思考{max_steps}步

问题：{question}

当前对话历史：
{history}

你的思考："""

# 完整ReAct执行循环的Prompt
class ReActPromptBuilder:
    def __init__(self, tools: List[dict], max_steps: int = 10):
        self.tools = tools
        self.max_steps = max_steps
    
    def build_initial(self, question: str) -> str:
        tools_desc = "\n".join(
            f"- {t['name']}: {t['description']}"
            for t in self.tools
        )
        return f"""解决以下问题。你可以使用工具获取信息。

可用工具：
{tools_desc}

执行规则：
- 每次回复必须包含"思考："和"行动："
- "行动："必须是以下之一：
  - tool_call(name=工具名, args=JSON参数)
  - finish(answer=最终答案)
- 如果{self.max_steps}步内未解决，请给出最佳答案

问题：{question}

思考："""
    
    def build_step(self, history: List[str]) -> str:
        """基于历史构建下一步的Prompt"""
        context = "\n\n".join(history)
        return f"""{context}

思考："""
```

### 4.2 Plan-and-Solve提示

```python
PLAN_AND_SOLVE_PROMPT = """请先制定完整计划，再逐步执行。

问题：{question}

阶段1：计划
请制定一个详细的执行计划，包含：
1. 需要完成的所有子任务
2. 每个子任务需要的工具/信息
3. 子任务之间的依赖关系
4. 预期输出

计划：

阶段2：执行
按照计划逐步执行。每完成一步，报告结果。

执行："""

# Plan-and-Execute with Replanning
ADAPTIVE_PLAN_PROMPT = """问题：{question}

当前计划：
{current_plan}

已执行步骤：
{executed_steps}

最新观察：
{latest_observation}

请评估当前计划是否仍然有效：
- 如果有效，继续执行下一步
- 如果需要调整，给出修订后的计划
- 如果已完成，给出最终答案

你的决定："""
```

### 4.3 反思与自我修正Prompt

```python
SELF_REFLECTION_PROMPT = """请回顾你刚才的回答，进行自我评估。

原始问题：{question}
你的回答：{answer}

请从以下维度评估：
1. 准确性：回答是否准确？有没有事实错误？
2. 完整性：是否回答了问题的所有方面？
3. 相关性：是否包含无关信息？
4. 清晰性：用户是否能理解？

如果发现问题，请提供修正后的回答。

评估结果："""

# 带验证的反思
VERIFIED_REFLECTION_PROMPT = """请验证以下推理过程。

问题：{question}
推理过程：
{reasoning}

请逐步验证每个推理步骤：
- 前提是否正确？
- 逻辑是否严密？
- 计算是否正确？
- 结论是否支持？

发现错误请指出并修正。

验证结果："""
```

---

## 第5章 输出控制与格式约束

### 5.1 JSON模式与Schema约束

```python
# OpenAI JSON Mode
JSON_MODE_PROMPT = """请分析以下输入并以JSON格式输出。

重要：你的整个回复必须是合法的JSON，不包含任何其他文本。

输入：{input}

输出Schema：
{{
  "sentiment": "positive/negative/neutral",
  "confidence": 0.0-1.0,
  "key_points": ["要点1", "要点2"],
  "entities": [{{"name": "实体名", "type": "实体类型"}}]
}}"""

# 使用OpenAI的response_format参数（更可靠）
"""
client.chat.completions.create(
    model="gpt-4o",
    messages=[{"role": "user", "content": prompt}],
    response_format={"type": "json_object"}
)
"""

# Pydantic + LLM = 类型安全输出
from pydantic import BaseModel, Field
from typing import List

class SentimentAnalysis(BaseModel):
    sentiment: str = Field(pattern=r"^(positive|negative|neutral)$")
    confidence: float = Field(ge=0.0, le=1.0)
    key_points: List[str] = Field(max_length=5)
    entities: List[dict]

class OutputValidator:
    """输出验证与重试"""
    
    def __init__(self, llm_client, max_retries: int = 3):
        self.llm = llm_client
        self.max_retries = max_retries
    
    async def generate_and_validate(
        self,
        prompt: str,
        schema_class: type[BaseModel],
        **llm_kwargs
    ) -> BaseModel:
        """生成输出并验证，失败时自动修复"""
        for attempt in range(self.max_retries):
            raw_output = await self.llm.generate(prompt, **llm_kwargs)
            
            try:
                # 尝试解析
                parsed = schema_class.model_validate_json(raw_output)
                return parsed
            except Exception as e:
                if attempt < self.max_retries - 1:
                    # 构建修复Prompt
                    fix_prompt = f"""你的上一个输出格式有误。

错误：{str(e)}

原始Prompt：{prompt}

你的输出：{raw_output}

请修正输出，确保符合JSON Schema：{schema_class.schema_json()}

修正后的输出："""
                    prompt = fix_prompt
                else:
                    raise ValueError(
                        f"Failed to validate after {self.max_retries} attempts: {e}"
                    )
```

### 5.2 类型化输出设计

```python
from enum import Enum
from pydantic import BaseModel, Field
from typing import Optional, List, Literal

class ActionType(str, Enum):
    TOOL_CALL = "tool_call"
    FINAL_ANSWER = "final_answer"
    ASK_CLARIFICATION = "ask_clarification"

class ToolCallOutput(BaseModel):
    action_type: Literal[ActionType.TOOL_CALL]
    tool_name: str
    tool_input: dict
    reasoning: str

class FinalAnswerOutput(BaseModel):
    action_type: Literal[ActionType.FINAL_ANSWER]
    answer: str
    sources: List[str] = Field(default_factory=list)

class ClarificationOutput(BaseModel):
    action_type: Literal[ActionType.ASK_CLARIFICATION]
    question: str
    why_needed: str

AgentAction = ToolCallOutput | FinalAnswerOutput | ClarificationOutput

# 用oneOf模式生成schema
import json
print(json.dumps(ToolCallOutput.model_json_schema(), indent=2))
```

---

## 第6章 Prompt优化与评估

### 6.1 A/B测试与效果评估

```python
from dataclasses import dataclass
from typing import List, Dict
import statistics

@dataclass
class PromptVariant:
    name: str
    template: str
    metadata: Dict

@dataclass
class TestResult:
    variant_name: str
    success: bool
    latency_ms: float
    token_usage: int
    quality_score: float  # 0-1
    
class PromptABTest:
    """
    Prompt A/B测试框架。
    
    测试流程：
    1. 准备多个Prompt变体
    2. 在相同测试集上运行
    3. 收集指标：成功率、延迟、Token消耗、质量评分
    4. 统计显著性检验
    5. 选择最优变体
    """
    
    def __init__(self):
        self.variants: List[PromptVariant] = []
        self.results: Dict[str, List[TestResult]] = {}
    
    def add_variant(self, variant: PromptVariant):
        self.variants.append(variant)
        self.results[variant.name] = []
    
    async def run_test(
        self,
        test_cases: List[dict],
        llm_client,
        evaluator  # 评估函数
    ):
        for case in test_cases:
            for variant in self.variants:
                prompt = variant.template.format(**case["inputs"])
                
                import time
                start = time.time()
                
                response = await llm_client.generate(prompt)
                
                latency = (time.time() - start) * 1000
                
                # 评估结果质量
                quality = evaluator.evaluate(
                    expected=case["expected"],
                    actual=response
                )
                
                result = TestResult(
                    variant_name=variant.name,
                    success=quality > 0.7,
                    latency_ms=latency,
                    token_usage=len(prompt) + len(response),  # 简化估算
                    quality_score=quality
                )
                self.results[variant.name].append(result)
    
    def report(self) -> Dict:
        report = {}
        for name, results in self.results.items():
            if not results:
                continue
            
            successes = [r for r in results if r.success]
            
            report[name] = {
                "success_rate": len(successes) / len(results),
                "avg_latency_ms": statistics.mean(r.latency_ms for r in results),
                "avg_quality": statistics.mean(r.quality_score for r in results),
                "avg_tokens": statistics.mean(r.token_usage for r in results),
                "sample_size": len(results),
            }
        
        return report
```

### 6.2 自动Prompt优化技术

```python
"""
自动Prompt优化方法：

1. 梯度-free优化（如OPRO）
   - 让LLM生成候选Prompt变体
   - 在验证集上评估
   - 选择最优的，迭代优化

2. DSPy框架
   - 声明式定义任务
   - 自动编译最优Prompt
   - 支持少样本选择和权重优化

3. 进化算法
   - 将Prompt视为基因组
   - 交叉、变异、选择
   - 多代进化得到最优Prompt
"""

# 简化版自动优化
class PromptOptimizer:
    def __init__(self, llm_client, meta_llm_client):
        self.llm = llm_client
        self.meta_llm = meta_llm_client  # 用于生成Prompt变体的更强模型
    
    async def generate_variants(self, base_prompt: str, n: int = 5) -> List[str]:
        """让LLM生成Prompt变体"""
        meta_prompt = f"""请基于以下基础Prompt，生成{n}个改进版本。

基础Prompt：
{base_prompt}

要求：
1. 每个变体应尝试不同的策略
2. 改进清晰度、具体性或结构
3. 保持核心意图不变

输出格式：每个变体用###分隔。
"""
        response = await self.meta_llm.generate(meta_prompt)
        
        # 解析变体
        variants = [v.strip() for v in response.split("###") if v.strip()]
        return variants[:n]
    
    async def optimize(
        self,
        base_prompt: str,
        test_cases: List[dict],
        iterations: int = 3
    ) -> str:
        best_prompt = base_prompt
        best_score = 0
        
        for i in range(iterations):
            print(f"\n优化迭代 {i+1}/{iterations}")
            
            # 生成变体
            variants = await self.generate_variants(best_prompt)
            variants.insert(0, best_prompt)  # 保留当前最佳
            
            # 评估
            scores = []
            for prompt in variants:
                score = await self._evaluate_prompt(prompt, test_cases)
                scores.append((prompt, score))
                print(f"  得分: {score:.3f}")
            
            # 选择最佳
            scores.sort(key=lambda x: x[1], reverse=True)
            best_prompt, best_score = scores[0]
            
            print(f"  最佳得分: {best_score:.3f}")
        
        return best_prompt
    
    async def _evaluate_prompt(self, prompt: str, test_cases: List[dict]) -> float:
        """在测试集上评估Prompt"""
        scores = []
        for case in test_cases:
            formatted = prompt.format(**case["inputs"])
            response = await self.llm.generate(formatted)
            
            # 简化评估：包含关键词得分
            score = self._keyword_match(case["expected_keywords"], response)
            scores.append(score)
        
        return sum(scores) / len(scores)
    
    def _keyword_match(self, keywords: List[str], text: str) -> float:
        text_lower = text.lower()
        matches = sum(1 for kw in keywords if kw.lower() in text_lower)
        return matches / len(keywords) if keywords else 0
```

---

## 第7章 实战：为Agent设计工业级Prompt系统

### 7.1 Prompt库架构设计

```python
from dataclasses import dataclass
from typing import Dict, Optional, Callable
import json
import hashlib

@dataclass
class PromptTemplate:
    """可版本管理的Prompt模板"""
    id: str
    name: str
    version: str
    template: str
    variables: list
    description: str
    tags: list
    performance_score: Optional[float] = None
    usage_count: int = 0

class PromptLibrary:
    """
    工业级Prompt库。
    
    特性：
    - 版本管理：每个Prompt有版本号
    - A/B测试：跟踪不同版本的性能
    - 缓存：避免重复渲染
    - 审计：记录Prompt使用日志
    """
    
    def __init__(self):
        self.templates: Dict[str, PromptTemplate] = {}
        self.cache: Dict[str, str] = {}  # 渲染缓存
        self.usage_log: list = []
    
    def register(self, template: PromptTemplate):
        key = f"{template.id}@{template.version}"
        self.templates[key] = template
    
    def get(self, template_id: str, version: Optional[str] = None) -> PromptTemplate:
        if version:
            key = f"{template_id}@{version}"
        else:
            # 获取最新版本
            versions = [k for k in self.templates.keys() if k.startswith(f"{template_id}@")]
            key = sorted(versions)[-1]
        
        return self.templates[key]
    
    def render(self, template_id: str, version: Optional[str] = None, **kwargs) -> str:
        template = self.get(template_id, version)
        
        # 缓存键
        cache_key = hashlib.sha256(
            f"{template_id}:{version}:{json.dumps(kwargs, sort_keys=True)}".encode()
        ).hexdigest()
        
        if cache_key in self.cache:
            return self.cache[cache_key]
        
        # 渲染
        from string import Template
        t = Template(template.template)
        result = t.safe_substitute(**kwargs)
        
        # 更新统计
        template.usage_count += 1
        self.usage_log.append({
            "template_id": template_id,
            "version": version,
            "timestamp": time.time(),
        })
        
        self.cache[cache_key] = result
        return result
    
    def compare_versions(self, template_id: str) -> Dict:
        """比较同一模板的所有版本性能"""
        versions = {
            k.split("@")[1]: v
            for k, v in self.templates.items()
            if k.startswith(f"{template_id}@")
        }
        return {
            v: {
                "score": t.performance_score,
                "usage": t.usage_count
            }
            for v, t in versions.items()
        }

# 初始化Prompt库
library = PromptLibrary()

library.register(PromptTemplate(
    id="intent_classification",
    name="意图识别",
    version="1.0.0",
    template="""判断以下用户输入的意图。

可选意图：{intents}

用户输入：{user_input}

请输出最匹配的意图和置信度（0-1）。
输出格式：{{"intent": "意图名", "confidence": 0.95}}""",
    variables=["intents", "user_input"],
    description="识别用户意图",
    tags=["classification", "intent"]
))

library.register(PromptTemplate(
    id="intent_classification",
    name="意图识别",
    version="1.1.0",
    template="""作为意图分类专家，分析用户输入。

意图类别：{intents}

用户输入：{user_input}

思考步骤：
1. 用户的核心需求是什么？
2. 有哪些关键词支持这个判断？
3. 是否有歧义？

输出JSON：{{"intent": "", "confidence": 0.0, "reasoning": ""}}""",
    variables=["intents", "user_input"],
    description="带推理过程的意图识别",
    tags=["classification", "intent", "cot"]
))

# 使用
result = library.render(
    "intent_classification",
    intents="[查询, 转账, 投诉, 咨询]",
    user_input="我想查一下余额"
)
print(result)
```

### 7.2 完整案例：电商客服Agent的Prompt系统

```python
"""
电商客服Agent的完整Prompt系统架构。

包含12个Prompt模板，覆盖完整客服流程：
"""

ECOMMERCE_AGENT_PROMPTS = {
    "intent_router": """# 意图路由
你是电商客服意图识别专家。

用户消息：{user_message}

分类到以下意图之一：
- order_query: 订单查询（查物流、状态、历史）
- product_inquiry: 商品咨询（规格、库存、推荐）
- return_refund: 退换货
- complaint: 投诉
- payment_issue: 支付问题
- account_help: 账户帮助
- greeting: 问候
- other: 其他

输出JSON：{{"intent": "", "confidence": 0.0, "entities": {{}}}}""",

    "entity_extraction": """# 实体提取
从用户消息中提取关键实体。

用户消息：{user_message}

需要提取的实体：
- order_id: 订单号（格式：ORD开头+数字）
- product_name: 商品名称
- phone: 手机号
- date: 日期
- amount: 金额

输出JSON：{{"entities": {{"实体名": "值"}}, "missing": ["缺失的必填实体"]}}""",

    "order_status_response": """# 订单状态回复
订单信息：{order_info}

请生成友好的回复，包含：
1. 订单当前状态
2. 预计送达时间（如果有）
3. 下一步会发生什么
4. 如有异常，说明原因和解决方案

语气：{tone}
""",

    "return_policy_check": """# 退换货政策检查
订单信息：{order_info}
商品信息：{product_info}

请判断是否符合退换货条件：
- 是否在7天无理由退货期内？
- 商品是否支持退货？
- 退货原因是否在政策范围内？

输出JSON：{{
    "eligible": true/false,
    "reason": "判断理由",
    "next_steps": ["用户需要做的事"]
}}""",

    "escalation_decision": """# 升级决策
对话历史：{conversation_history}
当前情绪评分：{sentiment_score}

判断是否应转人工：
- 用户情绪愤怒（sentiment < -0.5）
- 涉及法律问题
- 超过3轮未解决问题
- 用户明确要求人工

输出JSON：{{"escalate": true/false, "reason": "", "urgency": "high/medium/low"}}""",
}

# 完整的Prompt组装流程
class EcommerceAgentPromptSystem:
    def __init__(self, library: PromptLibrary):
        self.library = library
    
    async def build_full_context(
        self,
        user_message: str,
        user_profile: dict,
        order_history: list,
        conversation_history: list
    ) -> list:
        """构建完整的对话上下文"""
        
        # 1. 系统提示（角色定义）
        system_prompt = """你是某电商平台的智能客服助手。

## 核心能力
- 订单查询与物流追踪
- 商品咨询与推荐
- 退换货处理
- 投诉受理

## 行为准则
1. 始终礼貌、耐心
2. 不确定时不编造信息
3. 复杂问题主动提供转人工选项
4. 涉及退款时再次确认金额
5. 保护用户隐私，不泄露敏感信息

## 可用工具
- query_order: 查询订单
- track_logistics: 追踪物流
- check_inventory: 查库存
- initiate_return: 发起退货
- transfer_to_human: 转人工
"""
        
        # 2. 用户画像（动态注入）
        profile_info = f"""
## 用户画像
- 用户等级：{user_profile.get('tier', '普通')}
- 最近订单：{len(order_history)}笔
- 偏好品类：{user_profile.get('preferred_category', '未知')}
""" if user_profile else ""
        
        # 3. 最近对话历史
        recent_history = conversation_history[-6:] if conversation_history else []
        
        messages = [
            {"role": "system", "content": system_prompt + profile_info},
        ]
        
        for msg in recent_history:
            messages.append({"role": msg["role"], "content": msg["content"]})
        
        messages.append({"role": "user", "content": user_message})
        
        return messages

# 使用
# prompt_system = EcommerceAgentPromptSystem(library)
# messages = asyncio.run(prompt_system.build_full_context(
#     user_message="我的订单到哪了？",
#     user_profile={"tier": "VIP"},
#     order_history=[{"id": "123"}],
#     conversation_history=[]
# ))
```

---

## 本章小结

| 技能点 | Agent开发应用 | 关键技巧 |
|--------|-------------|---------|
| 清晰/具体/可验证原则 | 降低模型误解意图的概率 | 输出Schema约束 |
| 角色设定 | 约束Agent行为边界，提升一致性 | 明确职责+约束+示例 |
| 任务分解 | 将复杂Agent任务拆分为子任务 | PromptChain模式 |
| 少样本学习 | 快速适应新工具和新场景 | 语义相似度选择示例 |
| 结构化Prompt | 确保输出可被程序可靠解析 | Markdown > XML > JSON |
| CoT提示 | 提升Agent推理和规划能力 | "Let's think step by step" |
| 分层设计 | 系统层稳定+上下文层动态+任务层灵活 | System/User/Assistant分离 |
| ReAct模板 | 构建工具使用Agent的基础范式 | Thought→Action→Observation |
| 输出控制 | 将非确定性LLM输出转为可靠程序输入 | Pydantic + response_format |
| A/B测试 | 数据驱动选择最优Prompt | 多维度指标评估 |
| Prompt库 | 工业级Prompt管理 | 版本控制+缓存+审计 |
