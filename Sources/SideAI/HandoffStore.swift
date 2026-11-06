import SideAICore
import Foundation

extension SessionStore {
  func createHandoff(source: Conversation, route: ConnectionRoute, task: String, context: String,
                     images: [ImageAttachment], memory: String, cwd: String, mode: AgentMode) {
    guard route.workspace == .agent, routes.contains(where: { $0.id == route.id }), !isBusy, !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          mode != .project || !cwd.isEmpty else { return }
    newConversation(route: route)
    guard let id = selectedID else { return }
    mutate(id) {
      $0.handoff = HandoffLink(source: source)
      $0.title = "任务 · " + String(task.prefix(32))
      $0.draft = HandoffBuilder.draft(task: task, context: context, memory: memory)
      $0.attachments = images
      $0.cwd = cwd.isEmpty ? scratch.path : cwd; $0.mode = mode
    }
    banner = "已创建 \(route.name) 任务草稿。核对后点击发送；尚未调用模型。"
    saveNow()
    onRouteOpen?()
  }
  func bringResultBack() {
    guard let c = selected, let parent = c.handoff?.sourceID,
          state.conversations.contains(where: { $0.id == parent }),
          let result = c.items.last(where: { $0.kind == "agentMessage" && $0.status == "completed" && !$0.text.isEmpty }) else { return }
    let text = "\(route(for: c).name) 的任务结果（待核对）：\n" + result.text
    mutate(parent) { $0.draft += ($0.draft.isEmpty ? "" : "\n\n") + text }
    select(parent)
    banner = "结果已带回原会话草稿；没有发送给原服务商。"
  }
}
