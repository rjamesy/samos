import SwiftUI

/// Approval dialog for dangerous or impactful actions.
struct ActionConfirmationView: View {
    let title: String
    let description: String
    let actionLabel: String
    let onApprove: () -> Void
    let onDeny: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)

            Text(title)
                .font(.headline)

            Text(description)
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Cancel") {
                    onDeny()
                }
                .keyboardShortcut(.cancelAction)

                Button(actionLabel) {
                    onApprove()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
