import AppKit
import CoveCore
import SwiftUI

struct ContactsView: View {
  @Bindable var store: AppStore
  @State private var query = ""
  @State private var sort = "Name A–Z"
  @State private var editing: ContactRecord?
  @State private var showAllConversations = false
  @FocusState private var searchFocused: Bool
  private static let wave = Bundle.module.url(forResource: "contacts-wave", withExtension: "jpg")
    .flatMap { NSImage(contentsOf: $0) }

  private var contacts: [MailContact] { store.contacts }
  private var selected: MailContact? { contacts.first { $0.id == store.selectedContactID } }
  private var visible: [MailContact] {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let filtered = contacts.filter { contact in
      let groupMatches =
        store.contactGroup == "All contacts"
        || (store.contactGroup == "Favorites" && contact.record?.isFavorite == true)
        || contact.record?.group == store.contactGroup
      let text = "\(contact.name) \(contact.email) \(contact.record?.company ?? "")"
      return groupMatches && (needle.isEmpty || text.localizedCaseInsensitiveContains(needle))
    }
    if sort == "Recent activity" {
      return filtered.sorted {
        if $0.lastMessage == $1.lastMessage { return $0.email < $1.email }
        return ($0.lastMessage ?? .distantPast) > ($1.lastMessage ?? .distantPast)
      }
    }
    return filtered
  }
  private var frequent: [(contact: MailContact, count: Int)] {
    let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: store.now) ?? .distantPast
    var ranked: [(contact: MailContact, count: Int)] = contacts.map {
      (contact: $0, count: $0.messageCount(since: cutoff, through: store.now))
    }
    ranked = ranked.filter { $0.count > 0 }
    ranked.sort { lhs, rhs in
      if lhs.count == rhs.count { return lhs.contact.email < rhs.contact.email }
      return lhs.count > rhs.count
    }
    return Array(ranked.prefix(5))
  }

  var body: some View {
    GeometryReader { geometry in
      VStack(spacing: 0) {
        toolbar
        Divider()
        HStack(spacing: 0) {
          directory(wide: geometry.size.width >= 970)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
          Divider()
          detail.frame(width: geometry.size.width < 950 ? 292 : 326)
        }
      }
    }
    .background(Palette.canvas)
    .sheet(isPresented: $store.showNewContact) {
      ContactEditor(store: store, record: ContactRecord()) { saved in
        query = ""
        store.contactGroup = "All contacts"
        store.selectedContactID = saved.email
      }
    }
    .sheet(item: $editing) { record in
      ContactEditor(store: store, record: record) { saved in
        query = ""
        store.contactGroup = "All contacts"
        store.selectedContactID = saved.email
      }
    }
    .onChange(of: store.selectedContactID) { _, _ in showAllConversations = false }
    .onChange(of: query) { _, _ in clearHiddenSelection() }
    .onChange(of: store.contactGroup) { _, _ in clearHiddenSelection() }
    .onChange(of: visible.map(\.id)) { _, ids in
      if let id = store.selectedContactID, !ids.contains(id) { store.selectedContactID = nil }
    }
  }

  private var toolbar: some View {
    HStack(spacing: 14) {
      Text("Contacts").font(.coveTitle)
      Text("\(contacts.count)").font(.coveSecondary).foregroundStyle(Palette.muted)
        .help(store.isSample ? "Sample contacts · changes stay in the sample mailbox"
          : "Saved on this Mac, with people from downloaded mail")
        .accessibilityLabel("\(contacts.count) contacts")
      Spacer(minLength: 8)
      HStack(spacing: 8) {
        Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
        TextField("Search people or companies", text: $query).textFieldStyle(.plain)
          .font(.coveSecondary).focused($searchFocused).accessibilityLabel("Search contacts")
        if query.isEmpty {
          Text("⌘ K").font(.coveMetadata).foregroundStyle(Palette.muted)
        } else {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
          }
          .buttonStyle(.plain).accessibilityLabel("Clear contact search")
        }
      }.padding(12).frame(width: 285).background(
        Palette.canvas, in: RoundedRectangle(cornerRadius: 6)
      )
      .overlay(RoundedRectangle(cornerRadius: 6).stroke(searchFocused ? Palette.ink : Palette.line))
      Button("Search contacts") { searchFocused = true }.keyboardShortcut("k")
        .hidden().frame(width: 0, height: 0).accessibilityHidden(true)
    }.padding(.horizontal, 28).frame(height: 84)
  }

  private func directory(wide: Bool) -> some View {
    VStack(alignment: .leading, spacing: 24) {
      frequentContacts
      VStack(spacing: 0) {
        HStack {
          Text(store.contactGroup).font(.coveSection)
          if !query.isEmpty {
            Text("\(visible.count)").font(.coveMetadata).foregroundStyle(Palette.muted)
          }
          Spacer()
          CoveMenuPicker(
            "Sort contacts", selection: $sort,
            options: [("Name A–Z", "Name A–Z"), ("Recent activity", "Recent activity")]
          )
        }.padding(.bottom, 16)
        HStack(spacing: 12) {
          Text("Name").frame(maxWidth: .infinity, alignment: .leading)
          if wide { Text("Company").frame(width: 120, alignment: .leading) }
          Text("Last message").frame(width: 92, alignment: .leading)
        }.font(.coveMetadata).foregroundStyle(Palette.body).padding(.horizontal, 12)
          .padding(.vertical, 10).background(Palette.sidebar)
        if visible.isEmpty {
          emptyDirectory.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          List(selection: $store.selectedContactID) {
            ForEach(visible) { contact in
              contactRow(contact, wide: wide).tag(contact.id)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                .listRowSeparator(.hidden)
            }
          }.listStyle(.plain).scrollContentBackground(.hidden)
            .accessibilityLabel("Contact directory")
        }
      }.frame(maxHeight: .infinity)
    }.padding(.horizontal, 28).padding(.top, 26).padding(.bottom, 20)
  }

  private var frequentContacts: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        Text("Most messaged").font(.coveLabel)
        Spacer()
        Text("Last 30 days").font(.coveMetadata).help("Messages in downloaded mail from the last 30 days")
      }.foregroundStyle(.white)
      if frequent.isEmpty {
        Text("No recent messages yet.")
          .font(.coveSecondary).foregroundStyle(.white.opacity(0.9)).padding(.vertical, 10)
      } else {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(spacing: 8) {
            ForEach(frequent, id: \.contact.id) { item in
              Button {
                query = ""
                store.contactGroup = "All contacts"
                store.selectedContactID = item.contact.id
              } label: {
                HStack(spacing: 8) {
                  CoveAvatar(initials: item.contact.initials, size: 34)
                  VStack(alignment: .leading, spacing: 5) {
                    Text(item.contact.name).font(.coveCaption).lineLimit(1)
                    Text("\(item.count) \(item.count == 1 ? "message" : "messages")")
                      .font(.coveMetadata).foregroundStyle(.white.opacity(0.85))
                  }
                }.frame(width: 136, alignment: .leading).padding(8)
                  .background(
                    .white.opacity(store.selectedContactID == item.contact.id ? 0.18 : 0.06),
                    in: RoundedRectangle(cornerRadius: 7))
              }.buttonStyle(.plain).foregroundStyle(.white)
                .accessibilityLabel(
                  "\(item.contact.name), \(item.count) messages in downloaded mail")
            }
          }
        }
      }
    }.padding(18).frame(height: 138).background {
      GeometryReader { geometry in
        ZStack {
          Color(red: 0.098, green: 0.114, blue: 0.161)
          if let wave = Self.wave {
            Image(nsImage: wave).resizable().scaledToFill()
              .frame(width: geometry.size.width, height: geometry.size.height).opacity(0.65)
              .clipped()
          }
          Color.black.opacity(0.16)
        }
      }
    }.clipShape(RoundedRectangle(cornerRadius: 10))
  }

  private func contactRow(_ contact: MailContact, wide: Bool) -> some View {
    HStack(spacing: 12) {
      HStack(spacing: 10) {
        CoveAvatar(initials: contact.initials, size: 32)
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 5) {
            Text(contact.name).font(.coveControl).lineLimit(1)
            if contact.record?.isFavorite == true {
              Image(systemName: "star.fill").font(.cove(size: 9))
            }
          }
          Text(contact.email).font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
        }
      }.frame(maxWidth: .infinity, alignment: .leading)
      if wide {
        Text(contact.record?.company.isEmpty == false ? contact.record!.company : "—")
          .font(.coveMetadata).foregroundStyle(Palette.body).lineLimit(1)
          .frame(width: 120, alignment: .leading)
      }
      Text(contact.lastMessage.map { $0.formatted(.dateTime.month(.abbreviated).day()) } ?? "—")
        .font(.coveMetadata).foregroundStyle(Palette.body).frame(width: 92, alignment: .leading)
    }.padding(.horizontal, 12).frame(height: 62)
      .background(store.selectedContactID == contact.id ? Palette.mailSelection : Palette.canvas)
      .overlay(alignment: .bottom) {
        Rectangle().fill(Palette.line.opacity(0.65)).frame(height: 0.5)
      }
      .contentShape(Rectangle()).foregroundStyle(Palette.ink)
      .accessibilityElement(children: .combine)
  }

  private var emptyDirectory: some View {
    VStack(spacing: 12) {
      Image(systemName: "person.crop.rectangle").font(.cove(size: 28)).foregroundStyle(
        Palette.muted)
      Text(query.isEmpty ? (store.contactGroup == "Favorites" ? "No favorites yet" : "No contacts yet") : "No matching contacts")
        .font(.coveSection)
      if query.isEmpty && store.contactGroup == "Favorites" {
        Text("Star a contact to add it here.")
          .font(.coveSecondary).foregroundStyle(Palette.muted).multilineTextAlignment(.center)
      }
      if query.isEmpty && contacts.isEmpty && !store.isSample {
        Button("Sync Gmail") { Task { await store.sync() } }
          .buttonStyle(PrimaryButton()).disabled(store.busy)
      }
      if query.isEmpty {
        Button("New contact") { store.showNewContact = true }.buttonStyle(SecondaryButton())
      } else {
        Button("Clear search") { query = "" }.buttonStyle(SecondaryButton())
      }
    }.padding(24)
  }

  @ViewBuilder private var detail: some View {
    if let contact = selected {
      ScrollView {
        VStack(alignment: .leading, spacing: 24) {
          HStack {
            Spacer()
            Button {
              var record = editable(contact)
              record.isFavorite.toggle()
              store.saveContact(record)
            } label: {
              Image(systemName: contact.record?.isFavorite == true ? "star.fill" : "star")
            }
            .buttonStyle(.plain).help(
              contact.record?.isFavorite == true ? "Remove from favorites" : "Add to favorites"
            )
            .accessibilityLabel(
              contact.record?.isFavorite == true ? "Remove from favorites" : "Add to favorites")
            Button("Edit") { editing = editable(contact) }.buttonStyle(.plain).font(.coveSecondary)
          }
          VStack(alignment: .leading, spacing: 12) {
            CoveAvatar(initials: contact.initials, size: 72)
            Text(contact.name).font(.coveDetailTitle).textSelection(.enabled)
            if let company = contact.record?.company, !company.isEmpty {
              Text(company).font(.coveSecondary).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 8) {
              Button {
                store.compose(to: contact)
              } label: {
                Label("Email", systemImage: "envelope")
              }
              .buttonStyle(PrimaryButton())
              Button {
                store.screen = "calendar"
              } label: {
                Label("Calendar", systemImage: "calendar")
              }
              .buttonStyle(SecondaryButton()).help("Open your calendar to plan a meeting")
              .accessibilityLabel("Open calendar")
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 16) {
            info("Email", contact.email)
            if let record = contact.record {
              if !record.phone.isEmpty { info("Phone", record.phone) }
              if !record.group.isEmpty { info("Group", record.group) }
            }
            info("Source", contact.record == nil ? "Downloaded mail" : "Saved on this Mac")
          }
          VStack(alignment: .leading, spacing: 10) {
            Text("Notes").font(.coveLabel)
            if let notes = contact.record?.notes, !notes.isEmpty {
              Text(notes).font(.coveBody).lineSpacing(CoveTypography.bodyLineSpacing).foregroundStyle(Palette.body)
                .help("Your notes · stored on this Mac")
            } else {
              Button("Add a note") { editing = editable(contact) }.buttonStyle(.plain).font(.coveSecondary)
                .foregroundStyle(Palette.body).help("Notes are stored on this Mac")
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 16) {
            Text("Recent conversations").font(.coveLabel)
              .help("\(contact.messages.count) \(contact.messages.count == 1 ? "message" : "messages") in downloaded mail")
            if contact.recentConversations.isEmpty {
              Text("None in downloaded mail.")
                .font(.coveSecondary).foregroundStyle(Palette.muted)
            }
            ForEach(Array(contact.recentConversations.prefix(showAllConversations ? Int.max : 3))) {
              message in
              Button {
                open(message)
              } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Text(message.subject.isEmpty ? "No subject" : message.subject)
                    .font(.coveSecondary).lineLimit(2).multilineTextAlignment(.leading)
                  Text(message.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.coveMetadata).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
            if contact.recentConversations.count > 3 {
              Button(
                showAllConversations
                  ? "Show fewer" : "Show all \(contact.recentConversations.count)"
              ) {
                showAllConversations.toggle()
              }.buttonStyle(.plain).font(.coveMetadata)
            }
          }
        }.padding(24)
      }.background(Palette.surface)
    } else {
      VStack(spacing: 14) {
        Image(systemName: "person.crop.circle").font(.cove(size: 42)).foregroundStyle(Palette.muted)
        Text("Select a contact").font(.coveSection).foregroundStyle(Palette.body)
      }.padding(28).frame(maxHeight: .infinity).background(Palette.surface)
    }
  }
  private func info(_ label: String, _ value: String) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(label).font(.coveMetadata).foregroundStyle(Palette.muted)
      Text(value).font(.coveSecondary).foregroundStyle(Palette.body).textSelection(.enabled)
    }
  }
  private func editable(_ contact: MailContact) -> ContactRecord {
    contact.record ?? ContactRecord(name: contact.name, email: contact.email)
  }
  private func clearHiddenSelection() {
    if let id = store.selectedContactID, !visible.contains(where: { $0.id == id }) {
      store.selectedContactID = nil
    }
  }
  private func open(_ message: Mail) {
    store.search = ""
    store.priorityOnly = false
    if message.labels.contains("SENT") {
      store.chooseFolder("Sent")
    } else if (message.snoozedUntil ?? .distantPast) > store.now {
      store.chooseFolder("Snoozed")
    } else {
      store.chooseFolder(message.labels.contains("INBOX") ? "Inbox" : "Archive")
    }
    store.select(message)
  }
}

struct ContactEditor: View {
  @Bindable var store: AppStore
  @State var record: ContactRecord
  var onSave: (ContactRecord) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var validation: String?
  private var isExisting: Bool { store.contactRecords.contains { $0.id == record.id } }
  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Text(isExisting ? "Edit contact" : "Save a contact").font(.coveTitle)
      Text("Saved on this Mac.").font(.coveSecondary).foregroundStyle(Palette.muted)
      VStack(spacing: 14) {
        field("Name", text: $record.name)
        field("Email", text: $record.email)
        field("Company", text: $record.company)
        field("Phone", text: $record.phone)
        field("Group", text: $record.group)
        VStack(alignment: .leading, spacing: 6) {
          Text("Notes").font(.coveLabel)
          TextEditor(text: $record.notes).font(.coveBody).scrollContentBackground(.hidden)
            .padding(8).frame(height: 88).background(Palette.canvas)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Palette.inputBorder))
            .accessibilityLabel("Contact notes")
        }
      }
      if let validation { Text(validation).font(.coveSecondary).foregroundStyle(Palette.danger) }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.buttonStyle(SecondaryButton()).keyboardShortcut(
          .cancelAction)
        Button("Save contact") {
          guard ContactDirectory.isValidEmail(record.email) else {
            validation = "Enter one valid email address."
            return
          }
          guard ContactDirectory.isValidGroup(record.group) else {
            validation = "Choose a group name other than All contacts or Favorites."
            return
          }
          if store.contactRecords.contains(where: {
            $0.id != record.id
              && ContactDirectory.normalizedEmail($0.email)
                == ContactDirectory.normalizedEmail(record.email)
          }) {
            validation = "A saved contact already uses that email address."
            return
          }
          if store.saveContact(record) {
            record.email = ContactDirectory.normalizedEmail(record.email)
            onSave(record)
            dismiss()
          }
        }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
      }
    }.padding(28).frame(width: 490).background(Palette.canvas).foregroundStyle(Palette.ink)
  }
  private func field(_ label: String, text: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label).font(.coveLabel)
      TextField(label == "Email" ? "name@example.com" : label, text: text)
        .textFieldStyle(CoveFieldStyle()).accessibilityLabel("Contact \(label.lowercased())")
    }
  }
}
