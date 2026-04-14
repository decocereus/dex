import SwiftUI

enum AppGlobalBanner: Identifiable, Equatable {
    case notificationPermission(NotificationPermissionBanner)

    var id: String {
        switch self {
        case .notificationPermission(let banner):
            return banner.id
        }
    }
}

struct NotificationPermissionBanner: Equatable {
    enum Kind: Equatable {
        case prompt
        case denied
    }

    let kind: Kind

    var id: String {
        switch kind {
        case .prompt:
            return "notification-permission-prompt"
        case .denied:
            return "notification-permission-denied"
        }
    }

    var title: String {
        switch kind {
        case .prompt:
            return "Turn on notifications"
        case .denied:
            return "Notifications are disabled"
        }
    }

    var message: String {
        switch kind {
        case .prompt:
            return "Get alerted when an agent finishes or needs your input."
        case .denied:
            return "Open Settings to re-enable alerts for finished runs and follow-ups."
        }
    }

    var actionTitle: String {
        switch kind {
        case .prompt:
            return "Enable"
        case .denied:
            return "Open Settings"
        }
    }

    var systemImage: String {
        switch kind {
        case .prompt:
            return "bell.badge"
        case .denied:
            return "bell.slash"
        }
    }

    var tint: Color {
        switch kind {
        case .prompt:
            return LitterTheme.accent
        case .denied:
            return LitterTheme.warning
        }
    }
}

struct AppGlobalBannerView: View {
    let banner: AppGlobalBanner
    let onPrimaryAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(LitterFont.styled(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .litterFont(.subheadline, weight: .semibold)
                    .foregroundStyle(LitterTheme.textPrimary)
                    .lineLimit(1)

                Text(message)
                    .litterFont(.caption)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: onPrimaryAction)
                .buttonStyle(.plain)
                .litterFont(.caption, weight: .semibold)
                .foregroundStyle(tint)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(LitterTheme.textMuted)
                    .frame(width: 28, height: 28)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss notice")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: LitterTheme.usesRemodexChrome ? 20 : 18, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LitterTheme.usesRemodexChrome ? 20 : 18, style: .continuous)
                .stroke(LitterTheme.border.opacity(0.3), lineWidth: 1)
        )
    }

    private var title: String {
        switch banner {
        case .notificationPermission(let value):
            return value.title
        }
    }

    private var message: String {
        switch banner {
        case .notificationPermission(let value):
            return value.message
        }
    }

    private var actionTitle: String {
        switch banner {
        case .notificationPermission(let value):
            return value.actionTitle
        }
    }

    private var iconName: String {
        switch banner {
        case .notificationPermission(let value):
            return value.systemImage
        }
    }

    private var tint: Color {
        switch banner {
        case .notificationPermission(let value):
            return value.tint
        }
    }
}
