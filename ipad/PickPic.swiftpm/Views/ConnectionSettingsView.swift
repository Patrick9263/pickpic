import SwiftUI

/*
 * Signing this iPad in to a PickPic account.
 *
 * The flow is deliberately two steps -- request a link, then paste it back --
 * because the worker only ever delivers a session as a Set-Cookie on
 * /api/auth/magic-link/consume, and there is no universal link or custom URL
 * scheme that would let Mail hand the token to this app directly. So the
 * operator copies the link out of the email and pastes it here, and the app
 * redeems it itself rather than letting Safari redeem it into a browser
 * session this app could never read.
 *
 * Sign in with Apple, which the worker already implements for the web app,
 * would remove the paste step but needs a native endpoint that accepts an
 * identity token minted for the app's bundle id rather than the web Services
 * id, plus the capability enabled on the App ID. That is worth doing and is
 * not this change.
 */
struct ConnectionSettingsView: View {
    @ObservedObject var configuration: APIConfigurationStore

    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var pastedLink = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            Form {
                serverSection

                if configuration.isConfigured {
                    signedInSection
                } else {
                    requestLinkSection
                    redeemLinkSection
                }

                if let statusMessage {
                    Section {
                        Label(
                            statusMessage,
                            systemImage: "envelope"
                        )
                        .font(.footnote)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(
                            errorMessage,
                            systemImage: "exclamationmark.triangle"
                        )
                        .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("PickPic Account")
            .navigationBarTitleDisplayMode(.inline)
            .disabled(isWorking)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    /*
                     * Only offered once there is a session to go back to.
                     * Without one every screen behind this sheet is empty, so
                     * dismissing it would just look like the app is broken.
                     */
                    if configuration.isConfigured {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    if isWorking {
                        ProgressView()
                    }
                }
            }
        }
    }

    private var serverSection: some View {
        Section("PickPic Server") {
            Text(
                APIConfigurationStore
                    .productionBaseURL
                    .absoluteString
            )
            .font(.footnote)
            .textSelection(.enabled)

            if let message = configuration.signInRequiredMessage {
                Label(
                    message,
                    systemImage: "person.badge.key"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private var signedInSection: some View {
        Section("Signed in") {
            if let description = configuration.accountDescription {
                Text(description)
                    .font(.body)
            }

            if let credential = configuration.credential {
                LabeledContent(
                    "Sign-in expires",
                    value: credential.expiresAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.footnote)

                /*
                 * A session lasts thirty days from the moment it was created
                 * and cannot be extended in place, so the only remedy is to
                 * sign in again -- better done now, with the queue idle, than
                 * discovered as a 401 partway through a shoot's uploads.
                 */
                if configuration.isExpiringSoon {
                    Label(
                        """
                        This sign-in expires soon. Sign out and sign in \
                        again before your next shoot so uploads are not \
                        interrupted.
                        """,
                        systemImage: "clock.badge.exclamationmark"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Button("Sign Out", role: .destructive) {
                Task {
                    isWorking = true
                    await configuration.signOut()
                    isWorking = false
                }
            }
        }
    }

    private var requestLinkSection: some View {
        Section("1. Email yourself a sign-in link") {
            TextField(
                "Email address",
                text: $email
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)

            Button("Send Sign-In Link") {
                Task {
                    await requestLink()
                }
            }
            .disabled(
                email.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )
        }
    }

    private var redeemLinkSection: some View {
        Section("2. Paste the link from the email") {
            TextField(
                "https://app.pickpic.photos/sign-in?token=…",
                text: $pastedLink,
                axis: .vertical
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .lineLimit(1...3)

            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else {
                    return
                }

                /*
                 * PasteButton delivers on a background queue, and this is a
                 * @MainActor view.
                 */
                Task { @MainActor in
                    pastedLink = pasted

                    await signIn()
                }
            }

            Button("Sign In") {
                Task {
                    await signIn()
                }
            }
            .disabled(
                pastedLink.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )

            Text(
                """
                In Mail, press and hold the button in the email and choose \
                Copy Link. Links expire 15 minutes after they are sent and \
                work only once.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private func requestLink() async {
        /*
         * The whole form carries .disabled(isWorking), but that only takes
         * effect on the next render -- a second tap landing before SwiftUI
         * has re-rendered still reaches this action, and two links would go
         * out with the second invalidating the first. This view is
         * @MainActor and isWorking is set before the first suspension point
         * below, so a re-entrant call always observes it.
         */
        guard !isWorking else {
            return
        }

        let trimmed = email.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        guard !trimmed.isEmpty else {
            errorMessage = APIConfigurationError
                .missingEmail
                .localizedDescription

            return
        }

        isWorking = true
        errorMessage = nil
        statusMessage = nil

        do {
            try await configuration
                .makeAuthClient()
                .requestSignInLink(email: trimmed)

            /*
             * The worker answers identically whether or not the address has
             * an account, so this deliberately promises nothing more than
             * that the request was accepted.
             */
            statusMessage = """
            If \(trimmed) has a PickPic account, a sign-in link is on its \
            way. Copy the link from the email and paste it below.
            """
        } catch {
            errorMessage = error.localizedDescription
        }

        isWorking = false
    }

    private func signIn() async {
        /*
         * Same re-entrancy window as requestLink() above, and worse here: a
         * magic link is single-use, so a second redemption of the same token
         * fails and surfaces as an error on a sign-in that actually worked.
         * The PasteButton path makes this easy to hit -- pasting already
         * signs in, so tapping Sign In afterwards is a second attempt.
         */
        guard !isWorking else {
            return
        }

        isWorking = true
        errorMessage = nil

        do {
            let credential = try await configuration
                .makeAuthClient()
                .signIn(withPastedLink: pastedLink)

            try configuration.save(credential)

            pastedLink = ""
            statusMessage = nil

            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }

        isWorking = false
    }
}
