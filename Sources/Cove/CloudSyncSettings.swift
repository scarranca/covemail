import CoveCore
import SwiftUI

struct CloudSyncSettings: View {
  @Bindable var store: AppStore
  @State private var expanded = true
  var showsHeading = true
  @State private var confirmEnable = false
  @State private var confirmRemove = false

  var body: some View {
    Group {
      if showsHeading {
        DisclosureGroup(isExpanded: $expanded) {
          content.padding(.top, 16)
        } label: {
          SettingsSectionHeading(title: "Cloud sync", subtitle: "Private pilot · " + (store.cloudMirror.enabled ? "Enabled" : store.cloudMirror.accountID != nil ? "Paused" : "Off"), icon: "icloud")
        }
      } else { content }
    }
    .alert("Enable a cloud copy of recent mail?", isPresented: $confirmEnable) {
      Button("Cancel", role: .cancel) {}
      Button("Connect Google and enable") { Task { await store.enableCloudSync() } }
    } message: {
      Text("Your recent downloaded mail, labels and Jev results will be sent to Cove’s servers on PlanetScale and Google Cloud. Sign in with the same Gmail account. Use only one Mac as the uploader during this pilot. This does not enable background mail retrieval when the Mac is closed.")
    }
    .alert("Remove the cloud copy?", isPresented: $confirmRemove) {
      Button("Cancel", role: .cancel) {}
      Button("Remove cloud copy", role: .destructive) { Task { await store.removeCloudCopy() } }
    } message: {
      Text("Cloud sync will stop and live cloud records and their account encryption key will be removed. Remaining encrypted body objects are scheduled for cleanup after 30 days; database backups follow PlanetScale retention. Gmail and this Mac’s mail stay unchanged.")
    }
  }
  private var content: some View {
      VStack(alignment: .leading, spacing: 16) {
        Text("Keep a recent cloud copy for future mobile access. Sync runs while Cove is open on this Mac.")
          .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        Label(store.cloudStatus, systemImage: store.cloudSyncing ? "arrow.triangle.2.circlepath" : "icloud")
          .font(.coveLabel).accessibilityAddTraits(.updatesFrequently)
        if let lastSync = store.cloudMirror.lastSync {
          Text("Last synced \(lastSync.formatted(date: .abbreviated, time: .shortened))")
            .font(.coveSecondary).foregroundStyle(Palette.muted)
        }
        HStack(spacing: 12) {
          if store.cloudSyncing { ProgressView().controlSize(.small) }
          if store.cloudMirror.enabled {
            Button("Sync now") { Task { await store.syncCloud() } }.buttonStyle(SecondaryButton())
              .disabled(store.cloudSyncing)
            Button("Pause sync") { store.pauseCloudSync() }.buttonStyle(SecondaryButton())
          } else {
            Button("Enable cloud sync…") { confirmEnable = true }.buttonStyle(SecondaryButton())
              .disabled(store.cloudSyncing || store.busy || !store.entered || store.isSample)
          }
          if store.cloudMirror.accountID != nil {
            Button("Remove cloud copy…", role: .destructive) { confirmRemove = true }
              .buttonStyle(SecondaryButton()).disabled(store.cloudSyncing || store.busy)
          }
        }
        if store.cloudMirror.accountID != nil && store.cloudStatus.localizedCaseInsensitiveContains("reconnect") {
          Button("Reconnect Google…") { Task { await store.enableCloudSync(resume: false) } }
            .buttonStyle(SecondaryButton()).disabled(store.cloudSyncing || store.busy)
        }
        Text("Private pilot · one Mac uploads up to 1,000 downloaded emails from the last 30 days, including labels and Jev results. Drafts, Spam, Trash and attachments are excluded. Large bodies are shortened. Google credentials stay on this Mac.")
          .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
        Text("Cove stores encrypted mail headers and Jev results in PlanetScale, and encrypted bodies in Google Cloud. Cove’s server holds the decryption keys. Pausing keeps the existing cloud copy; removing local data does not remove it.")
          .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
      }
  }

}
