import SwiftUI

/*
 * Signing this iPad in to a PickPic account.
 *
 * Tapping the link in the email now opens this app directly and signs it in
 * -- see onOpenURL in App.swift, wired to applinks:app.pickpic.photos via the
 * entitlement and the AASA route the worker serves at
 * /.well-known/apple-app-site-association. The paste field below stays as a
 * fallback: a universal link can fail open to Safari instead of this app
 * (link previews, some third-party mail clients), and the worker only ever
 * delivers a session as a Set-Cookie on /api/auth/magic-link/consume, so
 * landing in Safari would otherwise leave the operator stuck with no way to
 * hand the token to this app. The operator copies the link out of the email
 * and pastes it here, and the app redeems it itself rather than letting
 * Safari redeem it into a browser session this app could never read.
 *
 * Creating an account works the same way: POST /api/auth/signup emails a
 * /sign-up link, and that link -- tapped or pasted -- redeems here at
 * /api/auth/signup/consume. The invite code is typed by the operator and
 * never stored, so it exists nowhere in the app or the repository.
 *
 * Sign in with Apple, which the worker already implements for the web app,
 * would remove the paste step too but needs a native endpoint that accepts an
 * identity token minted for the app's bundle id rather than the web Services
 * id, plus the capability enabled on the App ID. That is worth doing and is
 * not this change.
 */
struct ConnectionSettingsView: View {
    @ObservedObject var configuration: APIConfigurationStore

    @EnvironmentObject private var feedback: AppFeedbackStore

    @Environment(\.dismiss) private var dismiss

    private enum Mode: Hashable {
        case signIn
        case signUp
    }

    @State private var mode = Mode.signIn
    @State private var email = ""
    @State private var inviteCode = ""
    @State private var studioName = ""
    @State private var pastedLink = ""
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var errorStep = Step.request
    @State private var isWorking = false

    /*
     * Requesting and redeeming a link for a different account while this
     * one stays signed in. Signing out first used to be the only way, which
     * ended this account's session before the new link had even arrived.
     */
    @State private var isAddingAccount = false

    private var showsSignInSteps: Bool {
        !configuration.isConfigured || isAddingAccount
    }

    /*
     * Which numbered section a message is shown in. Messages used to sit in
     * their own section at the foot of the form, and the signup fields push
     * that below the fold -- a rejected invite code looked like a button
     * that did nothing. Status only ever comes from step 1; an error is
     * shown beside whichever step's action produced it.
     */
    private enum Step {
        case request
        case redeem
    }

    var body: some View {
        NavigationStack {
            Form {
                serverSection

                if configuration.isConfigured {
                    signedInSection
                }

                if showsSignInSteps {
                    modeSection

                    switch mode {
                    case .signIn:
                        requestLinkSection

                    case .signUp:
                        signupSection
                    }

                    redeemLinkSection
                }
            }
            .navigationTitle(
                configuration.isConfigured
                    ? "PickPic Account"
                    : "Sign In to PickPic"
            )
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
                 * A session slides forward on use -- 30 days of idle time,
                 * capped at a year from when it was created -- so this date
                 * keeps moving out on its own as long as the app is opened at
                 * least monthly (APIConfigurationStore.refreshSession()).
                 * This warning firing at all means either the app has not
                 * been opened in a while, or the year cap itself is close,
                 * which no amount of use can extend -- either way the only
                 * remedy is to sign in again, better done now with the queue
                 * idle than discovered as a 401 partway through a shoot.
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

            if isAddingAccount {
                /*
                 * Said before the link is requested, not in the switch
                 * itself: by then the operator has already decided.
                 */
                Text(
                    """
                    This iPad stays signed in to this account until the new \
                    link is used. After the switch, this account's events \
                    and unfinished uploads stay on this iPad, and can \
                    upload again once you sign back in to it.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)

                Button("Cancel") {
                    isAddingAccount = false
                    statusMessage = nil
                    errorMessage = nil
                    pastedLink = ""
                }
            } else {
                Button("Sign In to Another Account") {
                    mode = .signIn
                    statusMessage = nil
                    errorMessage = nil
                    isAddingAccount = true
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

    private var modeSection: some View {
        Section {
            /*
             * Messages are cleared here, on the operator's own switch, rather
             * than in an onChange(of: mode) -- signIn() also changes the mode
             * to steer a half-finished signup towards sign-in, and an
             * onChange would then wipe the error explaining why.
             */
            Picker(
                "Account",
                selection: Binding(
                    get: { mode },
                    set: { newMode in
                        mode = newMode
                        statusMessage = nil
                        errorMessage = nil
                    }
                )
            ) {
                Text("Sign In").tag(Mode.signIn)
                Text("Create Account").tag(Mode.signUp)
            }
            .pickerStyle(.segmented)
        }
    }

    private var signupSection: some View {
        Section("1. Create your account") {
            TextField(
                "Invite code",
                text: $inviteCode
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()

            TextField(
                "Email address",
                text: $email
            )
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .keyboardType(.emailAddress)
            .textContentType(.emailAddress)

            TextField(
                "Studio name",
                text: $studioName
            )
            .textContentType(.organizationName)

            Button("Email Me a Sign-Up Link") {
                Task {
                    await requestSignup()
                }
            }
            .disabled(
                [inviteCode, email, studioName].contains { field in
                    field.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ).isEmpty
                }
            )

            messages(for: .request)
        }
    }

    @ViewBuilder
    private func messages(for step: Step) -> some View {
        if step == .request, let statusMessage {
            Label(
                statusMessage,
                systemImage: "envelope"
            )
            .font(.footnote)
        }

        if errorStep == step, let errorMessage {
            Label(
                errorMessage,
                systemImage: "exclamationmark.triangle"
            )
            .foregroundStyle(.red)
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

            messages(for: .request)
        }
    }

    private var redeemLinkSection: some View {
        Section("2. Tap the link in the email") {
            TextField(
                "Paste the link from the email",
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

            Button(redeemButtonTitle) {
                Task {
                    await signIn()
                }
            }
            .disabled(
                pastedLink.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
            )

            messages(for: .redeem)

            Text(
                """
                Tapping the link in the email signs this iPad in directly. \
                If it opens Safari instead of PickPic, press and hold the \
                link, choose Copy Link, and paste it above. Sign-in links \
                expire after 15 minutes and sign-up links after 30, and \
                each works only once.
                """
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var redeemButtonTitle: String {
        switch (mode, isAddingAccount) {
        case (.signUp, false):
            return "Create Account"

        case (.signUp, true):
            return "Create and Switch"

        case (.signIn, false):
            return "Sign In"

        case (.signIn, true):
            return "Switch Account"
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
            errorStep = .request
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
            errorStep = .request
            errorMessage = error.localizedDescription
        }

        isWorking = false
    }

    private func requestSignup() async {
        // Same re-entrancy guard as requestLink() below.
        guard !isWorking else {
            return
        }

        let trimmedEmail = email.trimmingCharacters(
            in: .whitespacesAndNewlines
        )

        isWorking = true
        errorMessage = nil
        statusMessage = nil

        do {
            try await configuration
                .makeAuthClient()
                .requestSignup(
                    inviteCode: inviteCode.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    ),
                    email: trimmedEmail,
                    accountName: studioName.trimmingCharacters(
                        in: .whitespacesAndNewlines
                    )
                )

            /*
             * Worded to be true in all three cases the worker answers ok for:
             * a new address gets a sign-up link, one with an active account
             * gets a sign-in link instead, and a disabled account gets
             * nothing. Promising "confirm your new account" would be wrong
             * for the last two.
             */
            statusMessage = """
            Check your email at \(trimmedEmail). If the address already has \
            a PickPic account, the email holds a sign-in link instead. Tap \
            the link, or copy it and paste it below.
            """

            inviteCode = ""
        } catch {
            errorStep = .request
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
            let redemption = try await configuration
                .makeAuthClient()
                .redeem(pastedText: pastedLink)

            /*
             * Not save(): when this is a switch, the session being replaced
             * must be revoked rather than left live, the same as a tapped
             * link (App.swift's redeem).
             */
            try await configuration.replaceCredential(
                with: redemption.credential
            )

            pastedLink = ""
            statusMessage = nil
            isAddingAccount = false

            feedback.show(
                title: redemption.feedbackTitle,
                detail: redemption.feedbackDetail,
                systemImage: "checkmark.circle.fill"
            )

            dismiss()
        } catch AuthClientError.accountCreatedButNotSignedIn {
            /*
             * The account exists and the link is spent, so the only way in
             * is a sign-in link. Switching the form there, with the address
             * already filled in when this view knows it, makes that one tap.
             */
            pastedLink = ""
            statusMessage = nil
            mode = .signIn

            // Shown at step 1, where the sign-in link it asks for is sent.
            errorStep = .request
            errorMessage = AuthClientError
                .accountCreatedButNotSignedIn
                .localizedDescription
        } catch {
            errorStep = .redeem
            errorMessage = error.localizedDescription
        }

        isWorking = false
    }
}
