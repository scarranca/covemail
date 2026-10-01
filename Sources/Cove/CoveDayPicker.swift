import SwiftUI

/// Cove's own month grid for choosing a day, in place of the native graphical date picker: Inter, the
/// palette, round day cells, today ringed and the chosen day filled.
struct CoveDayPicker: View {
  let selection: Date?
  let choose: (Date) -> Void
  var calendar: Calendar = .current
  var today: Date = Date()
  @State private var month: Date

  init(selection: Date?, calendar: Calendar = .current, today: Date = Date(), choose: @escaping (Date) -> Void) {
    self.selection = selection; self.calendar = calendar; self.today = today; self.choose = choose
    let anchor = selection ?? today
    _month = State(initialValue: calendar.date(from: calendar.dateComponents([.year, .month], from: anchor)) ?? anchor)
  }

  /// Whole weeks covering the month; days of other months are nil, so the grid keeps its shape.
  static func weeks(of month: Date, calendar: Calendar) -> [[Date?]] {
    guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
    let lead = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
    var cells: [Date?] = Array(repeating: nil, count: lead)
    cells += range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: month) }
    while cells.count % 7 != 0 { cells.append(nil) }
    return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<$0 + 7]) }
  }
  private var symbols: [String] {
    let short = calendar.veryShortStandaloneWeekdaySymbols
    return (0..<7).map { short[($0 + calendar.firstWeekday - 1) % 7] }
  }

  var body: some View {
    VStack(spacing: 10) {
      HStack {
        Text(month.formatted(Date.FormatStyle(calendar: calendar, timeZone: calendar.timeZone).month(.wide).year())).font(.coveSubheading).foregroundStyle(Palette.ink)
        Spacer()
        step("chevron.left", by: -1, label: "Previous month")
        Button("Today") { show(today) }.buttonStyle(.plain).font(.coveControl).foregroundStyle(Palette.body)
          .padding(.horizontal, 6)
        step("chevron.right", by: 1, label: "Next month")
      }
      HStack(spacing: 2) {
        ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
          Text(symbol).font(.coveMetadata).foregroundStyle(Palette.muted).frame(width: 34)
        }
      }
      VStack(spacing: 2) {
        ForEach(Array(Self.weeks(of: month, calendar: calendar).enumerated()), id: \.offset) { _, week in
          HStack(spacing: 2) {
            ForEach(0..<7, id: \.self) { index in
              if let day = week[index] { cell(day) } else { Color.clear.frame(width: 34, height: 34) }
            }
          }
        }
      }
    }
    .padding(16).frame(width: 278)
    .background(Palette.canvas)
  }

  private func step(_ icon: String, by months: Int, label: String) -> some View {
    Button { if let next = calendar.date(byAdding: .month, value: months, to: month) { month = next } } label: {
      Image(systemName: icon).font(.cove(size: 11, weight: .medium)).frame(width: 26, height: 26).contentShape(Rectangle())
    }.buttonStyle(.plain).foregroundStyle(Palette.body).accessibilityLabel(label)
  }
  private func show(_ day: Date) {
    month = calendar.date(from: calendar.dateComponents([.year, .month], from: day)) ?? day
  }
  private func cell(_ day: Date) -> some View {
    let selected = selection.map { calendar.isDate($0, inSameDayAs: day) } ?? false
    let isToday = calendar.isDate(day, inSameDayAs: today)
    let past = day < calendar.startOfDay(for: today)
    return Button { choose(calendar.startOfDay(for: day)) } label: {
      Text("\(calendar.component(.day, from: day))")
        .font(selected || isToday ? .coveLabel : .coveSecondary)
        .foregroundStyle(selected ? Color.white : past ? Palette.muted : Palette.ink)
        .frame(width: 34, height: 34)
        .background { if selected { Circle().fill(Palette.ink) } }
        .overlay { if isToday && !selected { Circle().strokeBorder(Palette.line, lineWidth: 1.5) } }
        .contentShape(Circle())
    }
    .buttonStyle(DayCellStyle(selected: selected))
    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    .accessibilityAddTraits(selected ? .isSelected : [])
  }
}

private struct DayCellStyle: ButtonStyle {
  let selected: Bool
  @State private var hovering = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background { if !selected && (hovering || configuration.isPressed) { Circle().fill(Palette.sidebar) } }
      .onHover { hovering = $0 }
  }
}
