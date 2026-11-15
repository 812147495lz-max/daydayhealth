import SwiftUI

/// Reusable colors, type scale and surfaces for the DayDayHealth iPhone app.
/// The app deliberately uses system type and SF Symbols, with no third-party UI kit.
enum HealthTheme {
  static let accent = Color(
    uiColor: UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.46, green: 0.86, blue: 0.82, alpha: 1)
        : UIColor(red: 0.04, green: 0.43, blue: 0.48, alpha: 1)
    }
  )
  static let onAccent = Color(
    uiColor: UIColor { trait in
      trait.userInterfaceStyle == .dark ? .black : .white
    }
  )
  static let background = Color(
    uiColor: UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.055, green: 0.09, blue: 0.12, alpha: 1)
        : UIColor(red: 0.96, green: 0.975, blue: 0.977, alpha: 1)
    }
  )
  static let surface = Color(
    uiColor: UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.11, green: 0.16, blue: 0.19, alpha: 1)
        : .white
    }
  )
  static let subtle = Color(
    uiColor: UIColor { trait in
      trait.userInterfaceStyle == .dark
        ? UIColor(red: 0.16, green: 0.23, blue: 0.26, alpha: 1)
        : UIColor(red: 0.91, green: 0.945, blue: 0.945, alpha: 1)
    }
  )
  static let primaryText = Color.primary
  static let secondaryText = Color.secondary
  static let caution = Color.orange
  static let spacing: CGFloat = 16
  static let radius: CGFloat = 20
}

struct HealthCard<Content: View>: View {
  let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    content
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(HealthTheme.spacing)
      .background(HealthTheme.surface, in: Rectangle())
  }
}

struct SectionTitle: View {
  let title: String
  let caption: String?

  init(_ title: String, caption: String? = nil) {
    self.title = title
    self.caption = caption
  }

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title).font(.title3.weight(.bold))
      Spacer(minLength: 8)
      if let caption {
        Text(caption)
          .font(.footnote)
          .foregroundStyle(HealthTheme.secondaryText)
      }
    }
  }
}

struct StateMessage: View {
  let symbol: String
  let title: String
  let detail: String

  var body: some View {
    VStack(spacing: 12) {
      Image(systemName: symbol)
        .font(.system(size: 30, weight: .medium))
        .foregroundStyle(HealthTheme.accent)
        .accessibilityHidden(true)
      Text(title).font(.headline)
      Text(detail)
        .font(.subheadline)
        .foregroundStyle(HealthTheme.secondaryText)
        .multilineTextAlignment(.center)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 24)
    .padding(.horizontal, 8)
  }
}

struct StatusLine: View {
  let message: String
  let isError: Bool

  var body: some View {
    Label(message, systemImage: isError ? "exclamationmark.circle" : "info.circle")
      .font(.footnote)
      .foregroundStyle(isError ? Color.orange : HealthTheme.secondaryText)
      .fixedSize(horizontal: false, vertical: true)
      .accessibilityElement(children: .combine)
  }
}

struct PrimaryActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .frame(maxWidth: .infinity, minHeight: 48)
      .foregroundStyle(HealthTheme.onAccent)
      .background(HealthTheme.accent, in: Rectangle())
      .opacity(configuration.isPressed ? 0.80 : 1)
  }
}

struct QuietActionStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .frame(minHeight: 44)
      .foregroundStyle(HealthTheme.accent)
      .padding(.horizontal, 12)
      .background(HealthTheme.subtle, in: Rectangle())
      .opacity(configuration.isPressed ? 0.75 : 1)
  }
}
