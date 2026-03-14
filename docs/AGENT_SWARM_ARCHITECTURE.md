# NanoClaw Agent Swarm 架构解析

本文档详细说明 NanoClaw 中 Agent Swarm（智能体团队）的实现原理和使用方式。

## 一、架构概述

NanoClaw 的 Agent Swarm 是基于 **Claude Agent SDK** 的 Agent Teams 功能构建的。整个系统采用三层架构：

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Host Process (Node.js)                        │
│  ┌─────────────┐   ┌──────────────┐   ┌───────────────────────────┐ │
│  │   Channels  │ → │   Router/    │ → │   Container Runner        │ │
│  │ (Telegram,  │   │   IPC        │   │   (spawns containers)     │ │
│  │  WhatsApp)  │   │              │   └───────────────────────────┘ │
│  └─────────────┘   └──────────────┘                 ↓                │
└─────────────────────────────────────────────────────────────────────┘

                    ┌───────────────────────────────────────┐
                    │   Container (Linux sandbox)           │
                    │  ┌─────────────────────────────────┐  │
                    │  │   Claude Agent SDK (cli.js)     │  │
                    │  │   ┌─────────────────────────┐   │  │
                    │  │   │  Lead Agent (main)      │   │  │
                    │  │   │  - Creates teammates    │   │  │
                    │  │   │  - Orchestrates tasks   │   │  │
                    │  │   │  - Communicates via     │   │  │
                    │  │   │    SendMessage tool     │   │  │
                    │  │   └─────────────────────────┘   │  │
                    │  │            ↓ spawns             │  │
                    │  │   ┌─────────────────────────┐   │  │
                    │  │   │  Subagents (Team)       │   │  │
                    │  │   │  - Researcher           │   │  │
                    │  │   │  - Coder                │   │  │
                    │  │   │  - Analyst              │   │  │
                    │  │   └─────────────────────────┘   │  │
                    │  └─────────────────────────────────┘  │
                    │                                      │
                    │  MCP Server (ipc-mcp-stdio.ts)       │
                    │  - send_message tool                  │
                    │  - schedule_task tool                 │
                    └───────────────────────────────────────┘
```

## 二、核心组件分析

### 1. Agent Teams 的启用 (container-runner.ts)

在容器启动时，通过环境变量启用 Agent Teams 功能：

```typescript
// 容器设置文件 - container-runner.ts
settings.json 内容:
{
  "env": {
    // 启用 agent swarms (subagent orchestration)
    CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS: '1',
    // 从额外挂载目录加载 CLAUDE.md
    CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD: '1',
    // 启用 Claude 记忆功能
    CLAUDE_CODE_DISABLE_AUTO_MEMORY: '0',
  }
}
```

### 2. Agent Runner 中的工具配置

```typescript
allowedTools: [
  'Bash',
  'Read', 'Write', 'Edit', 'Glob', 'Grep',
  'WebSearch', 'WebFetch',
  'Task', 'TaskOutput', 'TaskStop',
  'TeamCreate', 'TeamDelete', 'SendMessage',  // ← Agent Teams 相关工具
  'TodoWrite', 'ToolSearch', 'Skill',
  'NotebookEdit',
  'mcp__nanoclaw__*'  // ← NanoClaw MCP 工具
],
```

### 3. 消息流机制

**关键发现：** Agent Teams 的工作方式是 **Result First, Then Polling**：

```
1. Lead Agent 创建 teammates
2. Lead Agent 的 EZ loop 结束 → emit type: "result"
3. Lead Agent 进入轮询循环：
   while (true) {
     - 检查是否有活跃的 teammates
     - 检查是否有来自 teammates 的未读消息
     - 如果收到消息 → 重新注入 prompt，重启 EZ loop
     - 如果 stdin 关闭且有活跃 teammates → 发送关闭请求
   }
```

### 4. isSingleUserTurn 问题的解决

这是一个关键的技术问题。当使用字符串 prompt 时：

```typescript
// 问题场景：
query({ prompt: "do something" })  // isSingleUserTurn = true
// → 第一个 result 后 stdin 被关闭
// → teammates 被强制关闭
```

**解决方案 - 使用 AsyncIterable (MessageStream)**：

```typescript
class MessageStream {
  private queue: SDKUserMessage[] = [];
  private waiting: (() => void) | null = null;
  private done = false;

  push(text: string): void {
    this.queue.push({
      type: 'user',
      message: { role: 'user', content: text },
      parent_tool_use_id: null,
      session_id: '',
    });
    this.waiting?.();
  }

  end(): void {
    this.done = true;
    this.waiting?.();
  }

  async *[Symbol.asyncIterator](): AsyncGenerator<SDKUserMessage> {
    while (true) {
      while (this.queue.length > 0) {
        yield this.queue.shift()!;
      }
      if (this.done) return;
      await new Promise<void>(r => { this.waiting = r; });
      this.waiting = null;
    }
  }
}
```

## 三、Telegram Swarm 实现详解

### 架构图

```
┌────────────────────────────────────────────────────────────────────┐
│                    Telegram Group Chat                              │
│                                                                     │
│   用户消息 ─────────────────────────────────────────────────────────→│
│                                                                     │
│   ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────────┐  │
│   │  Main Bot   │ │  Pool Bot 1 │ │  Pool Bot 2 │ │  Pool Bot 3 │  │
│   │  (Lead)     │ │ "Researcher"│ │   "Coder"   │ │  "Analyst"  │  │
│   └─────────────┘ └─────────────┘ └─────────────┘ └─────────────┘  │
│         ↑               ↑               ↑               ↑          │
│         │               │               │               │          │
└─────────┼───────────────┼───────────────┼───────────────┼──────────┘
          │               │               │               │
          ▼               ▼               ▼               ▼
┌─────────────────────────────────────────────────────────────────────┐
│                    Host Process (src/telegram.ts)                   │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐   │
│   │ Bot Pool Management                                          │   │
│   │                                                              │   │
│   │ poolApis: Api[]           // Grammy Api 实例数组            │   │
│   │ senderBotMap: Map<string, number>  // sender → bot index    │   │
│   │ key: `${groupFolder}:${senderName}`                          │   │
│   └─────────────────────────────────────────────────────────────┘   │
│                                                                     │
│   initBotPool() ──→ 为每个 token 创建 send-only Api 实例            │
│   sendPoolMessage() ──→ 分配 bot，重命名，发送消息                  │
└─────────────────────────────────────────────────────────────────────┘
```

### Bot Pool 实现

```typescript
// Bot pool 状态
const poolApis: Api[] = [];
const senderBotMap = new Map<string, number>();
let nextPoolIndex = 0;

// 初始化 Bot Pool
export async function initBotPool(tokens: string[]): Promise<void> {
  for (const token of string[]) {
    const api = new Api(token);  // Grammy send-only Api
    const me = await api.getMe();
    poolApis.push(api);
  }
}

// 发送消息并动态分配 bot
export async function sendPoolMessage(
  chatId: string,
  text: string,
  sender: string,
  groupFolder: string,
): Promise<void> {
  const key = `${groupFolder}:${sender}`;
  let idx = senderBotMap.get(key);

  if (idx === undefined) {
    // Round-robin 分配
    idx = nextPoolIndex % poolApis.length;
    nextPoolIndex++;
    senderBotMap.set(key, idx);

    // 重命名 bot 以匹配 sender 角色
    await poolApis[idx].setMyName(sender);
    await new Promise(r => setTimeout(r, 2000)); // 等待 Telegram 传播
  }

  await poolApis[idx].sendMessage(numericId, text);
}
```

### 消息路由流程

```
1. Subagent 调用 mcp__nanoclaw__send_message(text, sender="Researcher")
   ↓
2. MCP Server 写入 IPC 文件
   {
     type: 'message',
     chatJid: 'tg:-1001234567890',
     text: 'Found 3 results',
     sender: 'Researcher',
     groupFolder: 'telegram_dev-team'
   }
   ↓
3. Host IPC watcher 读取文件 (src/ipc.ts)
   ↓
4. 检查 sender 字段和 chatJid 前缀
   if (data.sender && data.chatJid.startsWith('tg:')) {
     await sendPoolMessage(data.chatJid, data.text, data.sender, sourceGroup);
   }
   ↓
5. 分配/复用 Pool Bot，发送消息
   ↓
6. 用户在 Telegram 看到来自 "Researcher" bot 的消息
```

## 四、智能体协作机制

### 1. Teammate 间通信

Lead Agent 和 Subagents 通过两种方式通信：

1. **内部协调** - 使用 SDK 内置的 `SendMessage` 工具
2. **用户可见消息** - 使用 NanoClaw 的 `mcp__nanoclaw__send_message` 工具

### 2. MCP 工具 (container/agent-runner/src/ipc-mcp-stdio.ts)

```typescript
server.tool(
  'send_message',
  "Send a message to the user or group immediately while you're still running.",
  {
    text: z.string().describe('The message text to send'),
    sender: z.string().optional()
      .describe('Your role/identity name (e.g. "Researcher"). When set, messages appear from a dedicated bot in Telegram.'),
  },
  async (args) => {
    const data = {
      type: 'message',
      chatJid,
      text: args.text,
      sender: args.sender || undefined,
      groupFolder,
      timestamp: new Date().toISOString(),
    };
    writeIpcFile(MESSAGES_DIR, data);
    return { content: [{ type: 'text', text: 'Message sent.' }] };
  },
);
```

### 3. CLAUDE.md 中的 Agent Teams 指导

在 Telegram 群组的 `groups/{folder}/CLAUDE.md` 中添加的指导：

```markdown
## Agent Teams

### Team member instructions

Each team member MUST be instructed to:

1. Share progress in the group via `mcp__nanoclaw__send_message` with a `sender`
   parameter matching their exact role/character name (e.g., `sender: "Marine Biologist"`).

2. Also communicate with teammates via `SendMessage` as normal for coordination.

3. Keep group messages short — 2-4 sentences max per message.

4. Use the `sender` parameter consistently — always the same name.

### Example teammate prompt

You are the Marine Biologist. When you have findings or updates for the user,
send them to the group using mcp__nanoclaw__send_message with sender set to
"Marine Biologist". Keep each message short (2-4 sentences max). Also
communicate with teammates via SendMessage.
```

## 五、身份/Bot 分配机制

### Bot 分配策略

```
┌─────────────────────────────────────────────────────────────────┐
│                    Bot Pool 分配流程                             │
│                                                                 │
│  1. 首次消息 from "Researcher"                                   │
│     → key = "telegram_dev-team:Researcher"                      │
│     → idx = 0 % 3 = 0                                          │
│     → senderBotMap.set("telegram_dev-team:Researcher", 0)       │
│     → poolApis[0].setMyName("Researcher")                       │
│     → 发送消息                                                   │
│                                                                 │
│  2. 后续消息 from "Researcher"                                   │
│     → key = "telegram_dev-team:Researcher"                      │
│     → idx = senderBotMap.get(key) = 0                           │
│     → 直接使用 poolApis[0] 发送（不再重命名）                      │
│                                                                 │
│  3. 新 subagent "Coder"                                         │
│     → key = "telegram_dev-team:Coder"                           │
│     → idx = 1 % 3 = 1                                          │
│     → senderBotMap.set("telegram_dev-team:Coder", 1)            │
│     → poolApis[1].setMyName("Coder")                            │
│     → 发送消息                                                   │
└─────────────────────────────────────────────────────────────────┘
```

### 重要特性

1. **稳定性** - 同一 group + sender 组合始终使用相同的 bot
2. **全局重命名** - `setMyName` 是全局的，不是 per-chat 的
3. **重启重置** - 服务重启后 mapping 重置，bots 会被重新分配

## 六、支持的平台

### 当前实现

| 平台 | Agent Teams 支持 | Swarm (独立 Bot 身份) | 状态 |
|------|-----------------|----------------------|------|
| Telegram | Yes | Yes (通过 `/add-telegram-swarm`) | 完整支持 |
| WhatsApp | Yes | No | 内部协作，无独立身份 |
| Slack | Yes | No | 内部协作，无独立身份 |
| Discord | Yes | No | 内部协作，无独立身份 |
| Gmail | Yes | No | 内部协作，无独立身份 |

### 原因分析

Telegram 之所以能实现 Swarm，是因为：
1. **Bot API 支持动态重命名** - `setMyName` API
2. **多 Bot 加入群组** - 可以添加多个 bots 到同一个群组
3. **Send-only Api 模式** - Grammy 支持只发送不轮询的 Api 实例

WhatsApp/Slack 等平台不支持类似功能，因为：
- WhatsApp Business API 不支持动态更改 bot 显示名称
- Slack 需要为每个 "bot" 创建单独的 App
- 这些平台的多 bot 集成成本和复杂度更高

## 七、关键文件总结

| 文件 | 作用 |
|------|------|
| `.claude/skills/add-telegram-swarm/SKILL.md` | Telegram Swarm 安装指南 |
| `src/container-runner.ts` | 容器创建、Agent Teams 环境配置 |
| `container/agent-runner/src/index.ts` | Agent 运行器、MessageStream 实现 |
| `container/agent-runner/src/ipc-mcp-stdio.ts` | MCP 工具定义、sender 参数 |
| `src/ipc.ts` | IPC 消息处理、路由逻辑 |
| `src/channels/telegram.ts` | Telegram 频道实现 |
| `docs/SDK_DEEP_DIVE.md` | Claude Agent SDK 深度分析 |

## 八、内容创作团队示例

在 Telegram 上，可以创建这样的内容创作团队：

```
Lead Agent (主编)
  ├── Researcher (研究员) - 收集素材和资料
  ├── Writer (作者) - 撰写初稿
  └── Editor (编辑) - 审核修改
```

每个角色在 Telegram 群组中显示为独立的 bot，用户可以看到他们的讨论和协作过程。

### 角色定义示例

```markdown
## Content Creation Team

You are the Lead Editor. Create teammates as needed:

1. **Researcher** - 搜索和收集相关素材、数据、参考资料
2. **Writer** - 根据研究结果撰写初稿
3. **Editor** - 审核文章质量、修正错误、优化表达

When creating teammates, instruct each to:
- Use mcp__nanoclaw__send_message with their role name as sender
- Keep group messages concise (2-4 sentences)
- Communicate with teammates via SendMessage for coordination
```
