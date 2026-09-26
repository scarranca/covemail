import CoveCore
import Observation
import SwiftUI

struct AssistantModelChoice: Identifiable, Equatable {
  let provider: AIProvider
  let model: String
  var id: String { provider.rawValue + ":" + model }
}

extension AIProviderSettings {
  func assistantChoice(preferred: AssistantModelChoice?, chatGPTConnected: Bool? = nil) -> AssistantModelChoice? {
    let providers = availableProviders(chatGPTConnected: chatGPTConnected)
    if let preferred, providers.contains(preferred.provider), !preferred.model.isEmpty { return preferred }
    guard let provider = writingProvider(chatGPTConnected: chatGPTConnected) else { return nil }
    return AssistantModelChoice(provider: provider, model: model(provider))
  }
}

@MainActor @Observable final class AssistantModelCatalog {
  private(set) var models: [AIProvider: [String]] = [:]
  private(set) var loading = Set<AIProvider>()
  private(set) var errors: [AIProvider: String] = [:]
  @ObservationIgnored private var requests: [AIProvider: Task<Void, Never>] = [:]
  @ObservationIgnored private var generations: [AIProvider: UUID] = [:]

  func replaceModels(_ result: [String], for provider: AIProvider) {
    var seen = Set<String>()
    models[provider] = result.compactMap {
      let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      return !value.isEmpty && seen.insert(value).inserted ? value : nil
    }
    errors[provider] = models[provider]?.isEmpty == true
      ? "No models returned. Your saved model is still available. Try refreshing or check Integrations." : nil
  }

  func clear(_ provider: AIProvider) {
    generations[provider] = UUID()
    requests[provider]?.cancel()
    requests[provider] = nil
    loading.remove(provider)
    models[provider] = nil
    errors[provider] = nil
  }

  func choices(provider: AIProvider, saved: String, selected: String?) -> [AssistantModelChoice] {
    var seen = Set<String>()
    return ([saved, selected ?? ""] + (models[provider] ?? [])).compactMap {
      let model = $0.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !model.isEmpty, seen.insert(model).inserted else { return nil }
      return AssistantModelChoice(provider: provider, model: model)
    }
  }

  func refresh(providers: [AIProvider], fetch: @escaping (AIProvider) async throws -> [String]) async {
    for provider in providers {
      guard !Task.isCancelled else { return }
      if let request = requests[provider] {
        await request.value
        continue
      }
      let generation = UUID()
      generations[provider] = generation
      loading.insert(provider)
      errors[provider] = nil
      // Discovery belongs to the shared catalog, not a transient popover task.
      let request = Task { @MainActor in
        defer {
          if generations[provider] == generation {
            loading.remove(provider)
            requests[provider] = nil
          }
        }
        do {
          let result = try await fetch(provider)
          try Task.checkCancellation()
          guard generations[provider] == generation else { return }
          replaceModels(result, for: provider)
        } catch is CancellationError {
          return
        } catch {
          guard generations[provider] == generation else { return }
          errors[provider] = "Couldn’t load models. \(error.localizedDescription)"
        }
      }
      requests[provider] = request
      await request.value
    }
  }

}

struct AssistantModelPicker: View {
  let settings: AIProviderSettings
  let selected: AssistantModelChoice?
  let useAI: Bool
  let choose: (AssistantModelChoice) -> Void
  let choosePassages: () -> Void
  let manage: () -> Void
  var fetchModels: ((AIProvider) async throws -> [String])?
  private var catalog: AssistantModelCatalog { settings.modelCatalog }
  @State private var search = ""
  @State private var refreshID = 0
  private var providers: [AIProvider] { settings.availableProviders() }
  private var loadID: String { providers.map(\.rawValue).joined(separator: ",") + ":\(refreshID)" }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Choose a model").font(.coveLabel)
        Spacer()
        Button { refreshID += 1 } label: { Image(systemName: "arrow.clockwise") }
          .buttonStyle(.plain).disabled(!catalog.loading.isEmpty)
          .help("Refresh available models").accessibilityLabel("Refresh available models")
      }
      TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
      ScrollView {
        VStack(alignment: .leading, spacing: 14) {
          ForEach(providers) { provider in
            VStack(alignment: .leading, spacing: 5) {
              HStack {
                Text(provider.title).font(.coveMetadata).foregroundStyle(Palette.body)
                Spacer()
                if catalog.loading.contains(provider) { ProgressView().controlSize(.small).accessibilityLabel("Loading models") }
              }.padding(.horizontal, 8)
              let choices = catalog.choices(provider: provider, saved: settings.model(provider),
                selected: selected?.provider == provider ? selected?.model : nil)
                .filter { search.isEmpty || ($0.model + " " + settings.modelLabel($0.model, provider: provider)).localizedCaseInsensitiveContains(search) }
              ForEach(choices) { choice in
                Button { choose(choice) } label: {
                  HStack(spacing: 8) {
                    Text(settings.modelLabel(choice.model, provider: provider)).lineLimit(2).multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    if settings.model(provider) == choice.model {
                      Text("Default").font(.coveMetadata).foregroundStyle(Palette.muted)
                    }
                    if useAI && selected == choice { Image(systemName: "checkmark") }
                  }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(useAI && selected == choice ? Palette.selection : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("\(settings.modelLabel(choice.model, provider: provider)), \(provider.title)")
              }
              if choices.isEmpty && !search.isEmpty {
                Text("No matching models").foregroundStyle(Palette.muted).padding(8)
              }
              if let error = catalog.errors[provider] {
                Text(error).font(.coveMetadata).foregroundStyle(Palette.body).fixedSize(horizontal: false, vertical: true).padding(8)
              }
            }
          }
          if providers.isEmpty { Text("Connect a provider and save a default model in Integrations.").foregroundStyle(Palette.body) }
        }
      }.frame(height: 280)
      Text("For this conversation. Your default stays in Settings.")
        .font(.coveMetadata).foregroundStyle(Palette.muted)
      Divider()
      Button(action: choosePassages) {
        HStack {
          Text("Jev · original passages")
          Spacer()
          if !useAI { Image(systemName: "checkmark") }
        }.contentShape(Rectangle())
      }.buttonStyle(.plain).padding(.vertical, 4)
      Button("Manage models…", action: manage).buttonStyle(SecondaryButton(compact: true))
    }.padding(16).frame(width: 340).font(.coveSecondary)
      .foregroundStyle(Palette.ink).background(Palette.canvas)
      .task(id: loadID) { await catalog.refresh(providers: providers, fetch: fetchModels ?? settings.models) }
  }
}
