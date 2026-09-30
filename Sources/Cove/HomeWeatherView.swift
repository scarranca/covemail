import CoveCore
import SwiftUI

struct HomeWeatherView: View {
  @Bindable var weather: HomeWeatherController
  @State private var city = ""
  @State private var enteringCity = false
  @FocusState private var cityFocused: Bool
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text("Weather").font(HomeType.supportingSection)
        Spacer()
        Menu {
          Button("Use my location") { Task { await weather.refresh(useLocation: true) } }
          Button("Choose a city") { chooseCity() }
          Toggle("Fahrenheit", isOn: $weather.fahrenheit)
          if weather.enabled { Button("Turn off weather") { weather.turnOff() } }
        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
          .accessibilityLabel("Weather options")
      }
      if let cache = weather.cache, let point = cache.forecast.current(at: Date()) {
        HStack(alignment: .center, spacing: 12) {
          Image(systemName: symbol(point.symbol)).font(.system(size: 30)).accessibilityHidden(true)
          VStack(alignment: .leading, spacing: 4) {
            Text(temperature(point.celsius)).font(.coveTitle).monospacedDigit()
            Text(condition(point.symbol)).font(HomeType.compactBody).foregroundStyle(Palette.body)
          }
          Spacer()
        }
        Text(weather.name).font(.coveControl)
        if let rain = point.rain {
          Text("Next hour · \(rain.formatted(.number.precision(.fractionLength(0...1)))) mm rain")
            .font(.coveMetadata).foregroundStyle(Palette.body)
        }
        Text("\(cache.expires < Date() ? "Saved forecast" : "Forecast") · updated \(cache.fetched.formatted(date: .omitted, time: .shortened))")
          .font(.coveMetadata).foregroundStyle(Palette.muted)
        HStack(spacing: 6) {
          Link("MET Norway", destination: URL(string: "https://api.met.no/")!)
          Text("·")
          Link("CC BY 4.0", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
        }.font(HomeType.metadata).foregroundStyle(Palette.muted)
      } else if !weather.working {
        HStack(spacing: 12) {
          Button("Use my location") { Task { await weather.refresh(useLocation: true) } }
            .buttonStyle(SecondaryButton(compact: true))
          if !enteringCity && weather.error == nil {
            Button("Choose city") { chooseCity() }.buttonStyle(.plain).font(HomeType.action)
          }
        }
      }
      if weather.working {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(weather.phase).font(HomeType.compactBody).foregroundStyle(Palette.body)
          Spacer(minLength: 0)
          Button("Cancel") { weather.cancelLookup() }.buttonStyle(.plain).font(HomeType.action)
        }
      }
      if let error = weather.error {
        Text(error).font(HomeType.compactBody).foregroundStyle(Palette.danger).fixedSize(horizontal: false, vertical: true)
      }
      if enteringCity || weather.error != nil {
        HStack {
          TextField("City, state or country", text: $city).textFieldStyle(CoveFieldStyle())
            .font(HomeType.compactBody).focused($cityFocused)
            .onSubmit { lookupCity() }
          Button("Find") { lookupCity() }.buttonStyle(SecondaryButton(compact: true))
            .disabled(city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || weather.working)
        }
      }
      if weather.cache == nil {
        Text("City search by Apple · forecasts by MET Norway (rounded location)")
          .font(HomeType.metadata).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
      }
    }
  }
  private func chooseCity() {
    weather.cancelLookup()
    enteringCity = true
    cityFocused = true
  }
  private func lookupCity() {
    let query = city.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return }
    Task { await weather.refresh(city: query); if weather.error == nil { enteringCity = false } }
  }
  private func temperature(_ celsius: Double) -> String {
    let value = weather.fahrenheit ? celsius * 9 / 5 + 32 : celsius
    return "\(Int(value.rounded()))°\(weather.fahrenheit ? "F" : "C")"
  }
  private func symbol(_ code: String) -> String {
    if code.contains("thunder") { return "cloud.bolt.rain" }
    if code.contains("snow") || code.contains("sleet") { return "cloud.snow" }
    if code.contains("rain") { return "cloud.rain" }
    if code.contains("fog") { return "cloud.fog" }
    if code.contains("partlycloudy") || code.contains("fair") { return code.contains("night") ? "cloud.moon" : "cloud.sun" }
    if code.contains("cloudy") { return "cloud" }
    if code.contains("clearsky") { return code.contains("night") ? "moon.stars" : "sun.max" }
    return "cloud"
  }
  private func condition(_ code: String) -> String {
    if code.contains("thunder") { return "Thunderstorms" }
    if code.contains("sleet") { return "Sleet" }
    if code.contains("snow") { return "Snow" }
    if code.contains("rain") { return "Rain" }
    if code.contains("fog") { return "Fog" }
    if code.contains("partlycloudy") { return "Partly cloudy" }
    if code.contains("cloudy") { return "Cloudy" }
    if code.contains("fair") { return "Mostly clear" }
    if code.contains("clearsky") { return "Clear sky" }
    return "Local forecast"
  }
}
