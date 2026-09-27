import SwiftUI

struct PopoverMenuDivider: View {
    var body: some View {
        Divider().padding(.vertical, 4)
    }
}

struct PopoverPickerRow<Trailing: View>: View {
    @Environment(\.appTheme) private var appTheme
    let title: String
    var icon: String? = nil
    var isSelected: Bool = false
    var checkmarkColumn: Bool = true
    let action: () -> Void
    @ViewBuilder let trailing: (_ rowHovering: Bool) -> Trailing
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    if checkmarkColumn {
                        Image(systemName: "checkmark")
                            .font(AppFonts.ui(10, weight: .bold))
                            .foregroundStyle(appTheme.brass)
                            .opacity(isSelected ? 1 : 0)
                    }
                    if let icon {
                        Image(systemName: icon)
                            .font(AppFonts.ui(11))
                            .foregroundStyle(appTheme.muted)
                            .frame(width: 15)
                    }
                    Text(title)
                        .font(AppFonts.ui(12.5, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(appTheme.text)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            trailing(hovering)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .background(hovering ? appTheme.brass.opacity(0.12) : Color.clear)
        .onHover { hovering = $0 }
    }
}

extension PopoverPickerRow where Trailing == EmptyView {
    init(title: String, icon: String? = nil, isSelected: Bool = false, checkmarkColumn: Bool = true, action: @escaping () -> Void) {
        self.init(title: title, icon: icon, isSelected: isSelected, checkmarkColumn: checkmarkColumn, action: action, trailing: { _ in EmptyView() })
    }
}
