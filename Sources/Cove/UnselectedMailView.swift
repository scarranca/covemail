import SwiftUI

/// The reading pane before the user selects a conversation.
/// Layout and copy follow the supplied “Inbox — No email selected” export.
struct UnselectedMailView: View {
  @Bindable var store: AppStore

  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 7) {
        Spacer(minLength: 0)
        if store.busy || store.syncing {
          ProgressView().controlSize(.mini)
        } else {
          Image(systemName: store.lastSync == nil ? "tray" : "checkmark.circle")
            .font(.coveText).accessibilityHidden(true)
        }
        syncStatus.font(.coveMetadata).multilineTextAlignment(.trailing).lineLimit(2)
      }
      .foregroundStyle(Palette.muted).frame(height: 66)

      VStack(spacing: 18) {
        Image(systemName: "envelope.open").font(.cove(size: 28, weight: .regular))
          .foregroundStyle(Palette.muted)
          .frame(width: 64, height: 64)
          .background(Color(white: 242.0 / 255), in: RoundedRectangle(cornerRadius: 20))
          .accessibilityHidden(true)

        Text("A little space to focus.")
          .font(.coveTitle).foregroundStyle(Palette.ink)
          .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)

        Text(
          "Select an email to read the conversation,\nsee its key passage, and write your reply."
        )
        .font(.coveText).lineSpacing(6).foregroundStyle(Palette.muted)
        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: 390)

        HStack(spacing: 7) {
          keycap("↑")
          keycap("↓")
          Text("to move through your inbox").font(.coveMetadata)
            .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.muted).padding(.top, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Use the Up Arrow and Down Arrow keys to move through your inbox.")
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)

      HStack(spacing: 7) {
        Image(systemName: "sparkles").font(.cove(size: 13)).accessibilityHidden(true)
        Text(reassurance).font(.coveMetadata).multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .foregroundStyle(Palette.muted).frame(maxWidth: .infinity)
    }
    .padding(.horizontal, 32).padding(.bottom, 24)
    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
  }

  @ViewBuilder private var syncStatus: some View {
    if store.busy || store.syncing {
      Text(store.status.isEmpty ? "Working…" : store.status)
    } else if store.isSample {
      Text("Sample inbox · saved locally")
    } else if let lastSync = store.lastSync {
      Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
    } else {
      Text("Ready to sync Gmail")
    }
  }

  private var reassurance: String {
    store.preferences.autoClassify
      ? "Jev checks new mail every two minutes while Cove is open."
      : "Your agent is ready to help. Nothing sends without you."
  }

  private func keycap(_ key: String) -> some View {
    Text(key).font(.coveSecondary).frame(width: 24, height: 24)
      .background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
      .overlay(RoundedRectangle(cornerRadius: 4).stroke(Palette.line, lineWidth: 1))
  }
}
