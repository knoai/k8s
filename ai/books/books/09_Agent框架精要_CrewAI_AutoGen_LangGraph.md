# 09. Agent框架精要：CrewAI、AutoGen与LangGraph

> **目标读者**：希望掌握企业级Agent框架的资深开发工程师  
> **核心目标**：深入理解主流框架的设计哲学、核心能力与工程实践

---

## 目录

### 第1章 Agent框架选型指南（已详细编写）
1.1 框架选型的关键维度  
1.2 CrewAI vs AutoGen vs LangGraph 概览  
1.3 其他框架速览：MetaGPT、Camel、Swarm

### 第2章 CrewAI：面向任务的Agent团队（已详细编写）
2.1 CrewAI设计哲学  
2.2 Agent、Task、Crew三大核心概念  
2.3 Process模式：Sequential vs Hierarchical  
2.4 工具集成与自定义  
2.5 实战：构建内容创作团队

### 第3章 AutoGen：对话驱动的Multi-Agent（已详细编写）
3.1 AutoGen的Conversation-centric设计  
3.2 ConversableAgent与UserProxyAgent  
3.3 GroupChat与对话管理  
3.4 代码执行与Human-in-the-loop  
3.5 实战：自动化数据分析工作流

### 第4章 LangGraph：状态机驱动的Agent编排
4.1 为什么需要LangGraph  
4.2 StateGraph与节点、边  
4.3 持久化与检查点  
4.4 循环、条件分支与并行  
4.5 实战：构建可恢复的长期运行Agent

### 第5章 框架对比与混合使用
5.1 功能矩阵对比  
5.2 框架间的互操作  
5.3 自定义框架的考量

### 第6章 生产级Agent框架实践
6.1 配置管理与环境隔离  
6.2 错误处理与重试策略  
6.3 日志与监控集成  
6.4 测试策略

### 第7章 实战：跨框架构建企业Agent平台
7.1 平台架构设计  
7.2 CrewAI负责业务流程  
7.3 LangGraph负责状态管理  
7.4 AutoGen负责人机协作

---

## 第1章 Agent框架选型指南

### 1.1 框架选型的关键维度

```
选型决策树：

你的Agent任务类型是什么？
├── 固定的多步骤工作流
│   └── 推荐：CrewAI（Process驱动）或 LangGraph（DAG/状态机）
│
├── 开放性的对话与协作
│   └── 推荐：AutoGen（Conversation-centric）
│
├── 复杂的状态管理与恢复
│   └── 推荐：LangGraph（持久化 + 检查点）
│
├── 软件开发全生命周期
│   └── 推荐：MetaGPT（SOP驱动的多Agent）
│
└── 简单的单Agent任务
    └── 推荐：LangChain或直接API调用
```

### 1.2 三大框架概览

| 维度 | CrewAI | AutoGen | LangGraph |
|------|--------|---------|-----------|
| **核心抽象** | Agent + Task + Crew | ConversableAgent | StateGraph |
| **设计哲学** | 角色驱动的任务执行 | 对话即编排 | 状态机即代码 |
| **Multi-Agent** | ✅ 原生支持 | ✅ 原生支持 | ✅ 原生支持 |
| **工作流类型** | Sequential / Hierarchical | 自由对话 | 任意图结构 |
| **人机协作** | 有限 | ✅ 优秀 | 有限 |
| **持久化** | 基础 | 基础 | ✅ 强大 |
| **代码执行** | 通过工具 | ✅ 内置 | 通过工具 |
| **学习曲线** | 平缓 | 中等 | 较陡 |
| **灵活性** | 中 | 高 | 很高 |
| **适合场景** | 业务流程自动化 | 探索性协作 | 复杂状态管理 |

### 1.3 其他框架速览

- **MetaGPT**：将SOP（标准操作流程）编码为Agent行为，特别适合软件开发
- **Camel**：角色扮演框架，通过Inception Prompting让Agent自主协作
- **Swarm**：OpenAI推出的轻量级Multi-Agent编排框架（实验性）
- **AgentScope**：阿里开源，支持分布式部署和故障恢复

---

## 第2章 CrewAI：面向任务的Agent团队

### 2.1 CrewAI设计哲学

CrewAI的核心理念：**将业务团队的工作模式映射到AI Agent团队**。

```
现实世界团队            CrewAI抽象
─────────────────────────────────────────
团队成员     ──►      Agent（角色+目标+背景）
分配任务     ──►      Task（描述+期望输出+Agent）
工作流程     ──►      Process（执行顺序）
团队协作     ──►      Crew（Agent集合 + Task列表）
```

### 2.2 Agent、Task、Crew三大核心概念

```python
from crewai import Agent, Task, Crew, Process
from langchain_openai import ChatOpenAI

# 1. 定义Agent（团队成员）
researcher = Agent(
    role="研究员",
    goal="收集和整理关于{topic}的最新信息",
    backstory="你是一位资深行业研究员，擅长从多个来源收集信息并提炼关键洞察。",
    verbose=True,
    allow_delegation=False,
    llm=ChatOpenAI(model="gpt-4o", temperature=0.3)
)

writer = Agent(
    role="写作专家",
    goal="基于研究资料撰写高质量的{content_type}",
    backstory="你是一位获奖作家，擅长将复杂信息转化为引人入胜的内容。",
    verbose=True,
    allow_delegation=False,
    llm=ChatOpenAI(model="gpt-4o", temperature=0.7)
)

# 2. 定义Task（任务）
research_task = Task(
    description="研究{topic}的最新发展趋势，收集至少10个关键数据点。",
    expected_output="一份结构化的研究报告，包含关键发现和数据支撑。",
    agent=researcher
)

writing_task = Task(
    description="基于研究报告，撰写一篇{content_type}。",
    expected_output="一篇完整的、可直接发布的{content_type}。",
    agent=writer,
    context=[research_task]  # 依赖research_task的输出
)

# 3. 定义Crew（团队）
crew = Crew(
    agents=[researcher, writer],
    tasks=[research_task, writing_task],
    process=Process.sequential,  # 顺序执行
    verbose=2
)

# 4. 执行任务
result = crew.kickoff(inputs={
    "topic": "AI Agent在2024年的应用",
    "content_type": "行业分析文章"
})
print(result)
```

### 2.3 Process模式

```python
from crewai import Process

# Sequential：按Task列表顺序执行（默认）
# 适合：有明确依赖关系的工作流

# Hierarchical：有Manager Agent协调
# 适合：复杂任务需要动态分配
manager = Agent(
    role="项目经理",
    goal="协调团队高效完成任务",
    backstory="你是一位经验丰富的项目经理...",
    allow_delegation=True  # 关键：允许委派
)

crew = Crew(
    agents=[researcher, writer, analyst],
    tasks=[task1, task2, task3],
    process=Process.hierarchical,
    manager_agent=manager,
    memory=True  # 启用记忆
)
```

### 2.4 工具集成

```python
from crewai_tools import SerperDevTool, ScrapeWebsiteTool
from langchain_community.tools import DuckDuckGoSearchRun

# CrewAI内置工具
search_tool = SerperDevTool()
scrape_tool = ScrapeWebsiteTool()

# 也可以直接使用LangChain工具
langchain_search = DuckDuckGoSearchRun()

researcher = Agent(
    role="研究员",
    goal="...",
    tools=[search_tool, scrape_tool, langchain_search],
    # Agent会自动选择合适的工具
)
```

### 2.5 实战：内容创作团队

```python
from crewai import Agent, Task, Crew
from crewai_tools import SerperDevTool

# 工具
search = SerperDevTool()

# Agent定义
researcher = Agent(
    role="内容研究员",
    goal="深入研究主题，收集权威信息和数据",
    backstory="你是一名资深研究分析师...",
    tools=[search],
    verbose=True
)

outline_writer = Agent(
    role="大纲设计师",
    goal="基于研究设计清晰的文章结构",
    backstory="你是一位擅长信息架构的编辑...",
    verbose=True
)

content_writer = Agent(
    role="主笔作家",
    goal="撰写高质量、有深度的文章",
    backstory="你是一位知名科技专栏作家...",
    verbose=True
)

editor = Agent(
    role="主编",
    goal="确保文章质量，提出修改建议",
    backstory="你是一家顶级科技媒体的主编...",
    verbose=True
)

# Task定义（带依赖关系）
research = Task(
    description="研究'{topic}'，收集关键信息、数据和观点",
    expected_output="详细的研究笔记",
    agent=researcher
)

outline = Task(
    description="基于研究笔记设计文章大纲",
    expected_output="包含各级标题的完整大纲",
    agent=outline_writer,
    context=[research]
)

draft = Task(
    description="根据大纲撰写完整文章",
    expected_output="3000字以上的完整文章",
    agent=content_writer,
    context=[outline]
)

review = Task(
    description="审查文章质量，输出修改建议和评分",
    expected_output="审稿意见和评分报告",
    agent=editor,
    context=[draft]
)

# 组装Crew
content_team = Crew(
    agents=[researcher, outline_writer, content_writer, editor],
    tasks=[research, outline, draft, review],
    process=Process.sequential,
    memory=True
)

# 运行
result = content_team.kickoff(inputs={"topic": "2024年AI Agent发展报告"})
```

---

## 第3章 AutoGen：对话驱动的Multi-Agent

### 3.1 AutoGen的Conversation-centric设计

AutoGen的核心创新：**将Agent交互建模为对话，而非任务链**。

```
CrewAI视角：              AutoGen视角：
Task A → Task B           Agent A: "我完成了数据分析"
   │         │            Agent B: "我看到了，但有几个异常值需要处理"
   ▼         ▼            Agent A: "好，我重新检查一下..."
[输出]    [输出]          ...（持续对话直到共识）
```

### 3.2 ConversableAgent与UserProxyAgent

```python
import autogen

# 配置LLM
config_list = [
    {
        "model": "gpt-4o",
        "api_key": "your-key"
    }
]

llm_config = {
    "config_list": config_list,
    "temperature": 0.3,
}

# AssistantAgent：AI Agent
assistant = autogen.AssistantAgent(
    name="coder",
    llm_config=llm_config,
    system_message="""你是一位Python数据分析师。
    当你需要执行代码时，请用代码块格式写出代码。
    如果任务完成，回复 TERMINATE。"""
)

# UserProxyAgent：代表人类用户，可执行代码
user_proxy = autogen.UserProxyAgent(
    name="user_proxy",
    human_input_mode="NEVER",  # "ALWAYS" / "NEVER" / "TERMINATE"
    max_consecutive_auto_reply=10,
    code_execution_config={
        "work_dir": "coding",
        "use_docker": False,  # 生产环境建议用Docker
    },
    llm_config=llm_config,
)

# 启动对话
user_proxy.initiate_chat(
    assistant,
    message="请分析 ./sales_data.csv 中的销售趋势，并绘制月度图表。"
)
```

### 3.3 GroupChat与对话管理

```python
from autogen import GroupChat, GroupChatManager

# 定义多个专家Agent
data_analyst = autogen.AssistantAgent(
    name="data_analyst",
    llm_config=llm_config,
    system_message="数据分析师。负责数据清洗、统计分析和可视化。"
)

business_expert = autogen.AssistantAgent(
    name="business_expert", 
    llm_config=llm_config,
    system_message="业务专家。负责解读数据背后的业务含义。"
)

report_writer = autogen.AssistantAgent(
    name="report_writer",
    llm_config=llm_config,
    system_message="报告撰写者。将分析结果整理为结构化的业务报告。"
)

# GroupChat配置
groupchat = GroupChat(
    agents=[user_proxy, data_analyst, business_expert, report_writer],
    messages=[],
    max_round=20,
    speaker_selection_method="round_robin"  # 轮流发言
    # 可选："auto"（LLM决定下一个发言人）
)

manager = GroupChatManager(
    groupchat=groupchat,
    llm_config=llm_config
)

# 启动群聊
user_proxy.initiate_chat(
    manager,
    message="分析Q3销售数据，找出增长机会。"
)
```

### 3.4 代码执行与Human-in-the-loop

```python
# Human-in-the-loop模式
user_proxy_with_human = autogen.UserProxyAgent(
    name="user_proxy",
    human_input_mode="TERMINATE",  # 每次Agent回复后询问人类
    code_execution_config={"work_dir": "coding"},
)

# 注册自定义回复函数
@user_proxy.register_for_execution()
@assistant.register_for_llm(description="执行SQL查询")
def execute_sql(query: str) -> str:
    """执行SQL查询并返回结果"""
    import sqlite3
    conn = sqlite3.connect("data.db")
    result = conn.execute(query).fetchall()
    conn.close()
    return str(result)
```

### 3.5 实战：自动化数据分析工作流

```python
import autogen

config_list = [{"model": "gpt-4o", "api_key": "your-key"}]

# Agent定义
planner = autogen.AssistantAgent(
    name="planner",
    system_message="""你是数据分析项目的规划师。
    你的任务是理解用户需求，制定分析计划。
    计划完成后，回复 TERMINATE。""",
    llm_config={"config_list": config_list, "temperature": 0.1}
)

coder = autogen.AssistantAgent(
    name="coder",
    system_message="""你是Python数据分析师。
    你负责编写和执行Python代码进行数据分析。
    任务完成后，回复 TERMINATE。""",
    llm_config={"config_list": config_list}
)

critic = autogen.AssistantAgent(
    name="critic",
    system_message="""你是数据质量审查员。
    你审查分析结果，检查是否有遗漏或错误。
    审查通过后，回复 TERMINATE。""",
    llm_config={"config_list": config_list}
)

user = autogen.UserProxyAgent(
    name="user",
    human_input_mode="NEVER",
    code_execution_config={"work_dir": "analysis", "use_docker": False}
)

# 嵌套对话：先规划，再执行，再审查
# 第一轮：规划
user.initiate_chat(planner, message="分析客户流失原因，数据在churn.csv中")
plan = user.last_message()["content"]

# 第二轮：执行
user.initiate_chat(coder, message=f"请按以下计划执行分析：\n{plan}")
analysis = user.last_message()["content"]

# 第三轮：审查
user.initiate_chat(critic, message=f"请审查以下分析结果：\n{analysis}")
```

---

## 第4章 LangGraph：状态机驱动的Agent编排

### 4.1 为什么需要LangGraph

LangChain的局限：
- Chain是线性/有向无环的
- 不支持循环（Agent需要思考-行动循环）
- 状态管理不直观

LangGraph的解决：**用图（Graph）建模Agent工作流，节点是处理步骤，边是状态转移**。

```
LangGraph核心概念：

State（状态）──► 随执行流动的数据
Node（节点）──► 处理函数，接收State，返回新State  
Edge（边）────► 状态转移，可以是条件分支
Graph（图）───► 节点+边的组合，可包含循环
```

### 4.2 StateGraph基础

```python
from langgraph.graph import StateGraph, END
from typing import TypedDict, Annotated
import operator

# 定义状态
class AgentState(TypedDict):
    messages: Annotated[list, operator.add]  # 累积消息
    next_step: str
    tool_calls: list
    final_answer: str | None

# 定义节点函数
def agent_node(state: AgentState) -> AgentState:
    """Agent思考节点"""
    response = llm.invoke(state["messages"])
    return {
        "messages": [response],
        "next_step": "tools" if response.tool_calls else "end"
    }

def tools_node(state: AgentState) -> AgentState:
    """工具执行节点"""
    results = []
    for tc in state["messages"][-1].tool_calls:
        result = execute_tool(tc)
        results.append(result)
    return {
        "messages": results,
        "next_step": "agent"
    }

# 构建图
workflow = StateGraph(AgentState)

# 添加节点
workflow.add_node("agent", agent_node)
workflow.add_node("tools", tools_node)

# 添加边
workflow.set_entry_point("agent")
workflow.add_edge("agent", "tools")  # 默认转移到tools
workflow.add_conditional_edges(
    "agent",
    lambda state: state["next_step"],
    {"tools": "tools", "end": END}
)
workflow.add_edge("tools", "agent")  # 工具执行后回到agent

# 编译
app = workflow.compile()

# 运行
result = app.invoke({
    "messages": [("human", "北京今天天气怎么样？")]
})
```

### 4.3 持久化与检查点

```python
from langgraph.checkpoint.sqlite import SqliteSaver

# 添加持久化
memory = SqliteSaver.from_conn_string(":memory:")
app = workflow.compile(checkpointer=memory)

# 运行（带线程ID，支持多会话）
config = {"configurable": {"thread_id": "user_123"}}

# 第一次调用
result = app.invoke(
    {"messages": [("human", "你好")]},
    config=config
)

# 后续调用（自动恢复状态）
result2 = app.invoke(
    {"messages": [("human", "刚才我说了什么？")]},
    config=config
)
# 由于有checkpointer，Agent知道之前的对话内容
```

---

## 第5-7章 内容精要

### 第5章 框架对比与混合使用
- **CrewAI**：快速搭建业务流程，角色定义清晰
- **AutoGen**：探索性任务，代码执行，人机协作
- **LangGraph**：复杂状态管理，需要持久化和恢复
- 混合方案：LangGraph做底层编排 + CrewAI定义业务角色 + AutoGen处理人机交互

### 第6章 生产级实践
- 配置管理：环境变量 + 配置中心，不同环境用不同模型
- 错误处理：节点级重试 + 全局断路器
- 监控：每个节点记录延迟、输入输出大小、Token使用量
- 测试：单元测试每个节点函数，集成测试完整图路径

### 第7章 跨框架企业平台
- 统一Agent注册中心
- 任务队列 + 调度器
-  LangGraph管理状态机
-  CrewAI编排业务流程
-  AutoGen处理需要人类确认的关键节点

---

## 本章小结

| 框架 | 核心优势 | 最佳场景 |
|------|----------|----------|
| **CrewAI** | 角色驱动，易上手 | 内容创作、研究分析、标准业务流程 |
| **AutoGen** | 对话即代码，代码执行 | 数据分析、探索性编程、人机协作 |
| **LangGraph** | 状态机，持久化 | 复杂工作流、需要恢复的长期任务 |
| **MetaGPT** | SOP驱动 | 软件开发全流程 |
