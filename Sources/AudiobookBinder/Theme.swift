import SwiftUI

enum BinderTheme {
    static let paper = Color(red: 0.957, green: 0.937, blue: 0.898)
    static let paperDeep = Color(red: 0.91, green: 0.875, blue: 0.812)
    static let ink = Color(red: 0.173, green: 0.125, blue: 0.094)
    static let inkMuted = Color(red: 0.42, green: 0.34, blue: 0.27)
    static let leather = Color(red: 0.365, green: 0.216, blue: 0.133)
    static let gold = Color(red: 0.776, green: 0.631, blue: 0.357)
    static let card = Color.white.opacity(0.72)
}

struct BinderButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? BinderTheme.leather : BinderTheme.paperDeep.opacity(0.85))
            )
            .foregroundStyle(prominent ? Color.white : BinderTheme.ink)
            .opacity(configuration.isPressed ? 0.82 : 1)
    }
}
