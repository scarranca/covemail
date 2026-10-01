import SwiftUI

struct ReadingSettingsView: View {
  var showsHeading = true
  var store: AppStore?
  @AppStorage("reading.textOnly") private var textOnly = false
  @AppStorage("reading.externalImages") private var externalImages = false

  var body: some View {
    VStack(alignment: .leading, spacing: 24) {
      if showsHeading { Text("Reading").font(.coveSection) }
      if let store {
        Toggle(isOn: Binding(get: { store.splitsInbox }, set: { store.setSplitInbox($0) })) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Split inbox").font(.coveLabel)
            Text("Show Important and Other tabs. Newsletters and automated mail go to Other.")
              .font(.coveSecondary).foregroundStyle(Palette.body)
              .fixedSize(horizontal: false, vertical: true)
          }
        }.toggleStyle(CoveToggleStyle())
          .accessibilityLabel("Split inbox")
      }
      if let store, store.sendingAliases.count > 1 {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
          VStack(alignment: .leading, spacing: 5) {
            Text("Default From address").font(.coveLabel)
            Text("New emails come from this address. Replies come from the address the email was sent to.")
              .font(.coveSecondary).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true)
          }
          Spacer()
          CoveMenuPicker("Default From address", selection: Binding(get: { store.defaultSender }, set: { store.setDefaultSender($0) }),
                         options: store.sendingAliases.map { ($0, $0) })
        }
      }
      Toggle(isOn: $textOnly) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Text-only reading").font(.coveLabel)
          Text("No images or sender styling. You can still show the original.")
            .font(.coveSecondary).foregroundStyle(Palette.body)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.toggleStyle(CoveToggleStyle())
        .accessibilityLabel("Text-only reading")
      Toggle(isOn: $externalImages) {
        VStack(alignment: .leading, spacing: 5) {
          Text("Load external images automatically").font(.coveLabel)
          Text("Senders may learn that you opened their email.")
            .font(.coveSecondary).foregroundStyle(Palette.body)
            .fixedSize(horizontal: false, vertical: true)
        }
      }.toggleStyle(CoveToggleStyle())
        .accessibilityLabel("Load external images automatically")
    }
    .task { if let store, !store.isSample { await store.loadSendingAliasesIfNeeded() } }
  }
}
