import CoveCore
import SwiftUI

/// An approval-gated change to many emails, as shown in one chat answer.
struct AssistantBulkState: Equatable {
  enum Phase: Equatable { case review, running(done: Int), finished, undoing(done: Int), undone, cancelled }
  var plan: AssistantBulkPlan
  var phase: Phase = .review
  var result: AssistantBulkResult?
  var undoResult: AssistantBulkResult?
  var isRunning: Bool {
    switch phase { case .running, .undoing: true; default: false }
  }
  var groundingLabel: String {
    switch phase {
    case .review: "Waiting for your approval"
    case .running: "Updating emails"
    case .finished: "\(result?.succeeded.count ?? 0) updated" + ((result?.failed.isEmpty ?? true) ? "" : " · \(result?.failed.count ?? 0) failed")
    case .undoing: "Restoring"
    case .undone: "Restored"
    case .cancelled: "Nothing changed"
    }
  }
}

/// Lists exactly which emails will change; one primary action applies it, Cancel leaves everything as is.
struct AssistantBulkCard: View {
  let state: AssistantBulkState
  let approve: () -> Void
  let cancel: () -> Void
  let undo: () -> Void
  private var plan: AssistantBulkPlan { state.plan }
  private var symbol: String {
    switch plan.operation {
    case .archive: "archivebox"
    case .markRead: "envelope.open"
    case .markUnread: "envelope.badge"
    case .star, .unstar: "star"
    case .addLabel, .removeLabel: "tag"
    }
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbol).font(.cove(size: 15)).foregroundStyle(Palette.body).frame(width: 20)
          .accessibilityHidden(true)
        VStack(alignment: .leading, spacing: 3) {
          Text(plan.title).font(.coveSubheading)
          Text(plan.detail).font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      if state.phase == .review || state.phase == .cancelled {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(plan.targets.prefix(AssistantBulkPlan.previewCount).enumerated()), id: \.element.id) { index, target in
            if index > 0 { Divider() }
            HStack(spacing: 8) {
              Text(target.sender.isEmpty ? "Unknown sender" : target.sender).font(.coveLabel).lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading).fixedSize(horizontal: true, vertical: false)
              Text(target.subject.isEmpty ? "(No subject)" : target.subject).font(.coveSecondary)
                .foregroundStyle(Palette.body).lineLimit(1)
              Spacer(minLength: 0)
            }.padding(.horizontal, 12).frame(height: 32)
          }
        }.background(Palette.canvas, in: RoundedRectangle(cornerRadius: 8))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
          .accessibilityElement(children: .combine).accessibilityLabel("Emails that will change")
        if plan.targets.count > AssistantBulkPlan.previewCount {
          Text("and \(plan.targets.count - AssistantBulkPlan.previewCount) more").font(.coveMetadata).foregroundStyle(Palette.body)
        }
      }
      footer
    }
    .padding(16).frame(maxWidth: .infinity, alignment: .leading)
    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
    .accessibilityElement(children: .contain)
  }

  @ViewBuilder private var footer: some View {
    switch state.phase {
    case .review:
      HStack(spacing: 10) {
        Button(plan.approveTitle, action: approve).buttonStyle(PrimaryButton(compact: true))
        Spacer(minLength: 0)
        Button("Cancel", action: cancel).buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
      }
    case .running(let done), .undoing(let done):
      VStack(alignment: .leading, spacing: 8) {
        ProgressView(value: Double(done), total: Double(max(1, total))).tint(Palette.ink)
        Text("\(state.phase == .running(done: done) ? plan.operation.progress(label: plan.labelName) : "Restoring") \(min(done + 1, total)) of \(total)…")
          .font(.coveMetadata).foregroundStyle(Palette.body)
      }
    case .finished:
      outcome(state.result, done: plan.operation.done(label: plan.labelName), canUndo: true)
    case .undone:
      outcome(state.undoResult, done: "Restored", canUndo: false)
    case .cancelled:
      Text("Cancelled. Nothing changed.").font(.coveSecondary).foregroundStyle(Palette.body)
    }
  }
  private var total: Int {
    if case .undoing = state.phase { return state.result?.succeeded.count ?? 0 }
    return plan.targets.count
  }

  @ViewBuilder private func outcome(_ result: AssistantBulkResult?, done: String, canUndo: Bool) -> some View {
    let succeeded = result?.succeeded.count ?? 0
    let failed = result?.failed ?? []
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 10) {
        Label("\(done) \(succeeded)", systemImage: failed.isEmpty ? "checkmark.circle.fill" : "exclamationmark.circle")
          .font(.coveControl)
        if !failed.isEmpty {
          Text("· \(failed.count) failed").font(.coveControl).foregroundStyle(Palette.danger)
        }
        Spacer(minLength: 0)
        if canUndo && succeeded > 0 {
          Button("Undo", action: undo).buttonStyle(SecondaryButton(compact: true))
        }
      }
      if !failed.isEmpty {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(failed.prefix(5), id: \.id) { failure in
            Text("\(failure.subject.isEmpty ? "(No subject)" : failure.subject) — \(failure.message)")
              .font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(2)
          }
          if failed.count > 5 {
            Text("and \(failed.count - 5) more").font(.coveMetadata).foregroundStyle(Palette.body)
          }
        }
      }
    }
  }
}
