# GPT 按需历史检索

2026-11-12：macOS 的 Responses API 聊天（包括 ChatGPT 账号授权）在记忆开启时提供两个只读工具：`sideai_memory.search_history` 与 `sideai_memory.read_history`。不再在请求前固定检索四条历史；模型自主决定是否查询，可换词、分页及读取更完整的会话。

- 搜索每页最多 8 条，读取每页最多 8,000 字符，返回 `next_offset`。空搜索按最近更新时间列出允许参考的会话。
- 来源仍在本轮用户消息下面折叠显示。列出的来源表示提供给模型的历史，不保证模型在答案中实际采用每条内容。
- 尊重全局记忆开关、本会话开关和来源会话排除设置。只读取本机已保存的已完成用户/助手文本；不读取任意文件、工具日志、隐藏推理或图片附件。
- 用户记忆笔记保留原有注入行为。搜索后端仍为本地关键词排序；本次升级的是模型控制查询过程，不是语义向量检索或自动长期记忆提炼。
- 每次发送最多 6 轮工具响应、16 次调用，最后要求直接回答；异常或断流不会自动重发用户消息。可随时停止。
- `store: false`，重放本轮完整 Responses output（包括加密推理和 phase）及工具结果，不依赖 `previous_response_id`，也不上传 Vector Store。相关摘录仅随本轮请求发送给当前连接。
- Claude、ACP 和 Codex Agent 当前仍使用已有的自动摘录机制；Windows 尚未接入这个新的工具循环。iOS 遥控由 Mac 执行，因此远程发送到相同 GPT 连接也使用新逻辑。

验证：本地 HTTP 流夹具覆盖搜索→读取→回答、加密推理重放、未知工具拒绝、未完成流不执行、工具轮数上限；存储测试覆盖开启、关闭、排除、分页与来源记录。

协议参考：https://developers.openai.com/api/docs/guides/function-calling
账号限制：https://developers.openai.com/siwc/token-sharing-open-source/preview-limitations

真实链路验证：`SIDEAI_MEMORY_LIVE=1 swift test --filter MemoryLiveTests` 通过。使用现有 ChatGPT 授权向 GPT-6-Astra 发送合成会话，实际收到 `search_history`、`read_history`，最终回答与合成测试词匹配。没有发送用户真实历史。该测试默认跳过，只有显式设置环境变量才消耗账号额度。
