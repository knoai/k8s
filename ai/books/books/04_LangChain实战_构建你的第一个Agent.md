# 04. LangChain实战：构建你的第一个Agent

> **目标读者**：已掌握Python和LLM基础，希望使用LangChain快速构建Agent的开发者  
> **核心目标**：掌握LangChain核心组件、Chain与Agent的构建方法、Memory系统设计

---

## 目录

### 第1章 LangChain架构全景（已详细编写）
1.1 LangChain设计哲学与核心抽象  
1.2 组件生态：Model I/O、Chains、Agents、Memory、Retrieval、Callbacks  
1.3 LCEL：LangChain表达式语言  
1.4 LangChain vs 原生开发：选型考量

### 第2章 Model I/O：标准化LLM交互（已详细编写）
2.1 Chat Models与LLMs的区别  
2.2 Prompt Templates与消息模板  
2.3 Output Parsers：结构化输出解析  
2.4 构建健壮的LLM调用链

### 第3章 Chains：工作流编排基础（已详细编写）
3.1 LLMChain与SequentialChain  
3.2 RouterChain：动态路由  
3.3 TransformChain：数据转换  
3.4 自定义Chain开发

### 第4章 Tools：Agent的能力扩展
4.1 内置Tools与自定义Tool  
4.2 Tool装饰器与Schema定义  
4.3 异步Tool与并发执行  
4.4 错误处理与容错

### 第5章 Agents：智能决策引擎
5.1 Agent类型对比：Zero-Shot、Conversational、Plan-and-Execute  
5.2 AgentExecutor执行循环  
5.3 自定义Agent与Tool Calling Agent  
5.4 多Agent协作初步

### 第6章 Memory：上下文与记忆管理
6.1 记忆类型：Buffer、Window、Summary、Vector  
6.2 实体记忆与知识提取  
6.3 多会话记忆持久化  
6.4 记忆压缩与Token优化

### 第7章 Callbacks与可观测性
7.1 Callback Handler机制  
7.2 日志记录与性能追踪  
7.3 与LangSmith集成  
7.4 自定义Callback开发

### 第8章 实战：从零构建智能客服Agent
8.1 需求分析与架构设计  
8.2 工具开发：订单查询、物流追踪、退换货  
8.3 Agent组装与Prompt调优  
8.4 评估与迭代优化

---

## 第1章 LangChain架构全景

### 1.1 LangChain设计哲学与核心抽象

LangChain的设计围绕一个核心理念：**将LLM应用开发中的常见模式抽象为可组合、可复用的组件**。

```
┌──────────────────────────────────────────────────────────────┐
│                    LangChain 架构层次                         │
├──────────────────────────────────────────────────────────────┤
│  应用层 (Applications)                                        │
│  ├── Chatbots, RAG, Agents, Code Analysis                   │
├──────────────────────────────────────────────────────────────┤
│  链层 (Chains)                                               │
│  ├── LLMChain, SequentialChain, RouterChain, Custom Chain   │
├──────────────────────────────────────────────────────────────┤
│  组件层 (Components)                                         │
│  ├── Model I/O: ChatModels, Prompts, OutputParsers          │
│  ├── Retrieval: Document Loaders, Text Splitters, VectorStores│
│  ├── Memory: Buffer, Window, Summary, Entity                │
│  └── Agents: Tools, AgentExecutor, Strategies               │
├──────────────────────────────────────────────────────────────┤
│  集成层 (Integrations)                                       │
│  ├── OpenAI, Anthropic, Cohere, Ollama...                   │
│  ├── Pinecone, Weaviate, Chroma, FAISS...                   │
│  └── FastAPI, Streamlit, Gradio...                          │
└──────────────────────────────────────────────────────────────┘
```

**为什么Agent开发需要LangChain：**

| 问题 | 原生Python方案 | LangChain方案 |
|------|--------------|---------------|
| 多模型切换 | 手动封装每个SDK | 统一的BaseChatModel接口 |
| 提示词管理 | 字符串拼接 | PromptTemplate + 变量注入 |
| 输出解析 | 手写JSON解析 | OutputParser + 自动重试 |
| 工具调用 | 手写调用逻辑 | Tool接口 + AgentExecutor |
| 记忆管理 | 手动维护数组 | Memory接口 + 多种实现 |
| 流式处理 | 手动处理SSE | 统一的astream接口 |

### 1.2 组件生态

```python
# LangChain核心组件导入速查
from langchain_core.messages import SystemMessage, HumanMessage, AIMessage, ToolMessage
from langchain_core.prompts import ChatPromptTemplate, MessagesPlaceholder
from langchain_core.output_parsers import JsonOutputParser, StrOutputParser
from langchain_core.runnables import RunnablePassthrough, RunnableLambda, RunnableParallel
from langchain_core.tools import tool, BaseTool
from langchain_core.callbacks import BaseCallbackHandler

from langchain_openai import ChatOpenAI
from langchain_anthropic import ChatAnthropic
from langchain_community.tools import DuckDuckGoSearchRun
from langchain_community.vectorstores import FAISS
```

### 1.3 LCEL：LangChain表达式语言

LCEL是LangChain v0.1+引入的声明式编排语法，用管道操作符 `|` 连接组件。

```python
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import ChatOpenAI
from langchain_core.output_parsers import StrOutputParser

# LCEL核心：管道操作符
prompt = ChatPromptTemplate.from_messages([
    ("system", "你是一个{role}。"),
    ("human", "{question}")
])

model = ChatOpenAI(model="gpt-4o-mini")
parser = StrOutputParser()

# 构建Chain: prompt -> model -> parser
chain = prompt | model | parser

# 调用
result = chain.invoke({"role": "Python专家", "question": "什么是装饰器？"})
print(result)
```

**LCEL的高级特性：**

```python
from langchain_core.runnables import RunnableParallel, RunnablePassthrough

# 并行执行多个分支
parallel_chain = RunnableParallel(
    summary=(prompt_summary | model | parser),
    keywords=(prompt_keywords | model | parser),
    sentiment=(prompt_sentiment | model | parser)
)

# 传递上下文：将输入同时传给多个组件
chain_with_context = RunnableParallel(
    context=retriever,           # 检索相关文档
    question=RunnablePassthrough()  # 透传原始问题
) | prompt | model | parser

# 条件路由
from langchain_core.runnables import RunnableBranch

branch = RunnableBranch(
    (lambda x: x["intent"] == "search", search_chain),
    (lambda x: x["intent"] == "chat", chat_chain),
    default_chain
)
```

---

## 第2章 Model I/O：标准化LLM交互

### 2.1 Chat Models与LLMs的区别

```python
from langchain_openai import ChatOpenAI, OpenAI

# Chat Model（推荐）：基于消息列表，支持系统/用户/助手/工具角色
chat_model = ChatOpenAI(model="gpt-4o-mini")
result = chat_model.invoke([
    SystemMessage(content="你是一个助手"),
    HumanMessage(content="你好")
])

# Legacy LLM：基于纯文本prompt
llm = OpenAI(model="gpt-3.5-turbo-instruct")
result = llm.invoke("你好，请自我介绍")

# Agent开发必须使用Chat Model，因为：
# 1. 支持 Function Calling / Tool Use
# 2. 支持系统消息设定角色和行为
# 3. 支持多轮对话的Message格式
```

### 2.2 Prompt Templates与消息模板

```python
from langchain_core.prompts import (
    ChatPromptTemplate, 
    SystemMessagePromptTemplate,
    HumanMessagePromptTemplate,
    MessagesPlaceholder
)

# 基础模板
prompt = ChatPromptTemplate.from_messages([
    ("system", "你是一个{role}，专长是{expertise}。"),
    ("human", "{question}")
])

# 带历史消息的模板（对话Agent必备）
conversation_prompt = ChatPromptTemplate.from_messages([
    SystemMessagePromptTemplate.from_template(
        "你是一个智能助手。可用工具：{tools}"
    ),
    MessagesPlaceholder(variable_name="history"),  # 动态插入历史
    HumanMessagePromptTemplate.from_template("{input}")
])

# 使用
from langchain_core.messages import HumanMessage, AIMessage

messages = conversation_prompt.invoke({
    "tools": "搜索、计算、查询数据库",
    "history": [
        HumanMessage(content="北京天气怎么样？"),
        AIMessage(content="今天北京晴朗，25°C。")
    ],
    "input": "那上海呢？"
})
```

**少样本提示模板：**

```python
from langchain_core.prompts import FewShotChatMessagePromptTemplate

examples = [
    {"input": "2+2", "output": "4"},
    {"input": "10*5", "output": "50"},
]

few_shot_prompt = FewShotChatMessagePromptTemplate(
    example_prompt=ChatPromptTemplate.from_messages([
        ("human", "{input}"),
        ("ai", "{output}")
    ]),
    examples=examples,
)

final_prompt = ChatPromptTemplate.from_messages([
    ("system", "你是一个计算器"),
    few_shot_prompt,
    ("human", "{input}")
])
```

### 2.3 Output Parsers：结构化输出解析

```python
from langchain_core.output_parsers import (
    JsonOutputParser, 
    PydanticOutputParser,
    CommaSeparatedListOutputParser
)
from pydantic import BaseModel, Field

# Pydantic Parser（最推荐）
class AgentAction(BaseModel):
    thought: str = Field(description="思考过程")
    tool: str = Field(description="要使用的工具名")
    tool_input: dict = Field(description="工具参数")

parser = PydanticOutputParser(pydantic_object=AgentAction)

prompt = ChatPromptTemplate.from_messages([
    ("system", "根据用户请求决定下一步行动。\n{format_instructions}"),
    ("human", "{query}")
]).partial(format_instructions=parser.get_format_instructions())

chain = prompt | ChatOpenAI() | parser

# 自动重试的解析器
from langchain_core.output_parsers import OutputFixingParser

fixing_parser = OutputFixingParser.from_llm(
    parser=parser,
    llm=ChatOpenAI(model="gpt-4o")
)
# 如果解析失败，自动让LLM修复格式
```

### 2.4 构建健壮的LLM调用链

```python
from langchain_core.runnables import RunnableRetry
from langchain_core.output_parsers import JsonOutputParser
import json

# 带重试和fallback的Chain
base_chain = prompt | ChatOpenAI(model="gpt-4o-mini") | JsonOutputParser()

# 重试3次
retry_chain = RunnableRetry(
    bound=base_chain,
    retry_exception_types=(json.JSONDecodeError,),
    max_attempt_number=3,
    wait_exponential_jitter=True
)

# Fallback到更强的模型
from langchain_core.runnables import RunnableWithFallbacks

robust_chain = retry_chain.with_fallbacks(
    fallbacks=[
        prompt | ChatOpenAI(model="gpt-4o") | JsonOutputParser()
    ]
)
```

---

## 第3章 Chains：工作流编排基础

### 3.1 SequentialChain与复杂工作流

```python
from langchain_core.prompts import ChatPromptTemplate
from langchain_openai import ChatOpenAI
from operator import itemgetter

# 多步骤分析Chain
model = ChatOpenAI(model="gpt-4o-mini")

# 步骤1：意图识别
intent_prompt = ChatPromptTemplate.from_template(
    "分析以下用户输入的意图。只输出一个词：[查询, 订购, 投诉, 咨询]\n\n{input}"
)
intent_chain = intent_prompt | model | StrOutputParser()

# 步骤2：根据意图路由到不同处理
analysis_prompt = ChatPromptTemplate.from_template(
    "用户意图是{intent}。请分析以下请求：\n{input}"
)

# 使用 LCEL 组合
full_chain = (
    {"intent": intent_chain, "input": RunnablePassthrough()}
    | analysis_prompt
    | model
    | StrOutputParser()
)

result = full_chain.invoke("我想查一下我的订单")
```

### 3.2 RouterChain：动态路由

```python
from langchain_core.runnables import RunnableBranch

# 定义多个 specialist chains
math_chain = ChatPromptTemplate.from_template("数学问题：{input}") | model | StrOutputParser()
code_chain = ChatPromptTemplate.from_template("编程问题：{input}") | model | StrOutputParser()
general_chain = ChatPromptTemplate.from_template("一般问题：{input}") | model | StrOutputParser()

# 分类器
classifier_prompt = ChatPromptTemplate.from_template(
    "分类以下问题（只输出类别）：[math, code, general]\n\n{input}"
)
classifier = classifier_prompt | model | StrOutputParser()

# 路由Chain
router = RunnableBranch(
    (lambda x: "math" in x["topic"], math_chain),
    (lambda x: "code" in x["topic"], code_chain),
    general_chain
)

full_router = (
    {"topic": classifier, "input": RunnablePassthrough()}
    | router
)
```

### 3.3 自定义Chain开发

```python
from langchain_core.runnables import RunnableSerializable
from langchain_core.pydantic_v1 import BaseModel
from typing import Any

class ValidationChain(RunnableSerializable[dict, dict]):
    """自定义Chain：在输出前进行业务规则验证"""
    
    next_chain: RunnableSerializable
    validator: callable
    max_retries: int = 3
    
    class Config:
        arbitrary_types_allowed = True
    
    def invoke(self, input: dict, config=None) -> dict:
        for attempt in range(self.max_retries):
            result = self.next_chain.invoke(input, config)
            if self.validator(result):
                return result
            # 在prompt中追加修正指令
            input = {
                **input,
                "correction_hint": f"上次输出未通过验证，请修正。"
            }
        raise ValueError(f"验证失败，已重试{self.max_retries}次")
    
    # LCEL兼容
    def _invoke(self, input, **kwargs):
        return self.invoke(input)

# 使用
validated_chain = ValidationChain(
    next_chain=prompt | model | parser,
    validator=lambda x: "required_field" in x,
    max_retries=3
)
```

---

## 第4-8章 内容精要

### 第4章 Tools：Agent的能力扩展
- `@tool` 装饰器自动从函数签名生成Schema
- `StructuredTool` 支持复杂参数类型
- 异步Tool使用 `async def` + `ainvoke`
- Tool错误处理：`handle_tool_error=True` 或自定义错误包装

### 第5章 Agents：智能决策引擎
- **Zero-Shot ReAct**：最基础的思考-行动循环
- **Conversational Agent**：带记忆的多轮对话Agent
- **Plan-and-Execute Agent**：先规划后执行，适合复杂任务
- **Tool Calling Agent**：直接使用模型的原生Function Calling
- **AgentExecutor参数**：`max_iterations` 防止无限循环，`early_stopping_method` 超时处理

### 第6章 Memory：上下文与记忆管理
- `ConversationBufferMemory`：保存完整历史（Token消耗大）
- `ConversationBufferWindowMemory`：只保留最近K轮
- `ConversationSummaryMemory`：LLM自动总结历史
- `VectorStoreRetrieverMemory`：基于语义检索相关记忆
- 实体提取记忆：自动提取对话中的关键实体和事实

### 第7章 Callbacks与可观测性
- `BaseCallbackHandler`：追踪所有Chain/Agent/LLM事件
- 记录输入输出、Token使用量、延迟、错误
- LangSmith集成：一键可视化Agent执行轨迹
- 自定义Callback：发送指标到Prometheus/Datadog

### 第8章 实战：智能客服Agent
- 架构：用户输入 → 意图识别 → 参数提取 → 工具调用 → 结果生成
- 工具开发：订单查询API、物流追踪API、退换货流程
- 记忆设计：保留用户身份信息、订单上下文
- 评估指标：问题解决率、平均交互轮数、用户满意度

---

## 本章小结

| 组件 | Agent开发作用 |
|------|--------------|
| ChatPromptTemplate | 构建角色设定 + 动态上下文 |
| PydanticOutputParser | 将LLM输出转化为类型安全的Python对象 |
| LCEL管道 | 声明式编排Agent工作流 |
| RunnableBranch | 根据意图动态路由到不同处理链 |
| @tool | 将Python函数注册为Agent可用工具 |
| AgentExecutor | 管理思考-行动-观察的完整循环 |
| ConversationBufferWindowMemory | 控制上下文长度，避免Token溢出 |
| Callbacks | 实现Agent系统的可观测性 |
