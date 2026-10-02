import SwiftUI

struct SettingsSidebar: View {
  @Bindable var store: AppStore
  let section: String
  let select: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 26) {
      Logo().padding(.top, 35)
      Button {
        if store.showConnections { store.showConnections = false }
        else { store.chooseFolder("Inbox") }
      } label: {
        Label(store.entered ? "Back to Cove" : "Back to sign in", systemImage: "arrow.left")
          .font(.coveLabel)
      }.buttonStyle(.plain).disabled(store.busy)
      VStack(alignment: .leading, spacing: 5) {
        Text("Settings").font(.coveControl)
          .foregroundStyle(Palette.body).padding(.horizontal, 11).padding(.bottom, 8)
        ForEach([("Gmail", "envelope"),
                 ("Jev · Mail agent", "sparkles"), ("Reading", "text.alignleft"), ("Menu bar", "menubar.rectangle")] +
                 (store.cloudConfigured ? [("Cloud sync", "icloud")] : []) +
                 [("Privacy", "lock.shield"), ("App updates", "arrow.down.circle")], id: \.0) { title, icon in
          Button { select(title) } label: {
            Label(title, systemImage: icon).font(.coveLabel)
              .frame(maxWidth: .infinity, alignment: .leading).padding(11)
              .background(section == title ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
          }.buttonStyle(.plain)
        }
        Button { store.screen = "integrations" } label: {
          Label("Connections", systemImage: "square.stack.3d.up").font(.coveLabel)
            .frame(maxWidth: .infinity, alignment: .leading).padding(11)
        }.buttonStyle(.plain)
          .background(section == "Integrations" ? Palette.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
          .disabled(!store.entered || store.busy)
      }
      Spacer()
      if store.entered {
        HStack(spacing: 10) {
          CoveAvatar(initials: store.isSample ? "AL" : String(store.accountEmail.prefix(2)).uppercased(), size: 32)
          VStack(alignment: .leading, spacing: 4) {
            Text(store.isSample ? "Alex Lee" : store.accountEmail).font(.coveLabel).lineLimit(1)
            Text(store.isSample ? "Sample mailbox" : "Personal · Gmail").font(.coveMetadata).foregroundStyle(Palette.body)
          }
        }
      }
    }.padding(.horizontal, 18).padding(.bottom, 22).background(Palette.sidebar)
  }
}
