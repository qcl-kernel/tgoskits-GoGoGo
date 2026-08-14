---
name: agent-template
description: |
  TODO: 用一到三句话描述这个 Agent 的用途和触发场景。
  建议格式：用于 <场景> 时自动执行 <操作>。
  示例：用于审计所有开放的 GitHub PR 时自动审查非本人提交的 PR，并与 POSIX/Linux/RFC/VirtIO 语义对比验证。
---

# <Agent 名称>

TODO: 用一段话概述这个 Agent 解决的核心问题，以及它在 TGOSKits 工作流中的位置。

## 适用场景

TODO: 列出 3-6 个触发条件，格式为"当用户想 <动作> 时使用此 Agent"。

- 当用户想 TODO 时使用此 Agent。
- 当用户想 TODO 时使用此 Agent。
- 当用户想 TODO 时使用此 Agent。

## 工作流程

### 1. <步骤一名称>

TODO: 描述此步骤的具体操作、输入来源和预期产出。

### 2. <步骤二名称>

TODO: 描述此步骤的具体操作、输入来源和预期产出。

### 3. <步骤三名称>

TODO: 描述此步骤的具体操作、输入来源和预期产出。

## 输出格式

TODO: 描述此 Agent 产出的内容格式，例如：

- 文件：`<路径>` 中的 TODO
- 摘要：在对话中展示的 TODO
- 验证结果：TODO

## 约束与规则

TODO: 列出此 Agent 必须遵守的约束，例如：

- 只修改与任务直接相关的文件。
- 不提交生成物、临时文件或二进制文件。
- 修改代码后运行 `cargo clippy` 和 `cargo fmt`。
- TODO：其他约束。

## 资源

### 参考文档

- `references/<文件名>.md` --- TODO：此参考文档的内容摘要。

### 脚本

- `scripts/<文件名>` --- TODO：此脚本的用途说明。
