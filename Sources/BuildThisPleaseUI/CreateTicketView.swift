import BuildThisPleaseCore
import SwiftUI

struct CreateTicketView: View {
    @Environment(\.dismiss) private var dismiss
    let client: any BuildThisPleaseClientProtocol
    let onCreated: (BuildThisPleaseTicket) -> Void
    let onEmailError: (String) -> Void
    init(client: any BuildThisPleaseClientProtocol, onEmailError: @escaping (String) -> Void = { _ in }, onCreated: @escaping (BuildThisPleaseTicket) -> Void) {
        self.client = client; self.onEmailError = onEmailError; self.onCreated = onCreated
    }
    @State private var title = ""
    @State private var description = ""
    @State private var email = ""
    @State private var emailUpdates = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var idempotencyKey = UUID().uuidString
    @FocusState private var focusedField: Field?

    private enum Field { case title, description, email }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 15) {
                    RequestField(
                        title: String(localized: "Title", bundle: .module),
                        count: title.count,
                        limit: 100
                    ) {
                        TextField("", text: $title, axis: .vertical)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .title)
                            .padding(16)
                    }

                    RequestField(
                        title: String(localized: "Description", bundle: .module),
                        count: description.count,
                        limit: 5000
                    ) {
                        TextEditor(text: $description)
                            .scrollContentBackground(.hidden)
                            .focused($focusedField, equals: .description)
                            .lineSpacing(3)
                            .frame(height: 200)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }

                    RequestEmailField(email: $email)
                        .focused($focusedField, equals: .email)
                        .onChange(of: email) { _, _ in
                            if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isEmailValid { emailUpdates = false }
                        }

                    Toggle(String(localized: "Email me when followed requests ship", bundle: .module), isOn: $emailUpdates)
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isEmailValid)
                    if emailUpdates { Text(String(localized: "Confirm the email we send to enable updates for requests you follow.", bundle: .module)).font(.footnote).foregroundStyle(.secondary) }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.red.opacity(0.10), in: .rect(cornerRadius: 12))
                    }

                }
                .frame(maxWidth: 700)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .buildThisPleaseDismissesCreateRequestKeyboardOnScroll()
            .background(BuildThisPleaseSurface.canvas.ignoresSafeArea())
            .buildThisPleaseSubmitBar {
                submitButton
            }
            .navigationTitle(String(localized: "New request", bundle: .module))
            .buildThisPleaseInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if #available(iOS 26, macOS 26, *) {
                        Button(role: .cancel) { dismiss() } label: {
                            Label(String(localized: "Cancel", bundle: .module), systemImage: "xmark")
                                .labelStyle(.iconOnly)
                        }
                        .tint(Color.primary)
                    } else {
                        Button(String(localized: "Cancel", bundle: .module), role: .cancel) { dismiss() }
                            .tint(Color.primary)
                    }
                }
            }
            .onAppear { focusedField = .title }
            .interactiveDismissDisabled(isSubmitting)
        }
    }

    private var isValid: Bool {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return !cleanTitle.isEmpty && cleanTitle.count <= 100
            && !cleanDescription.isEmpty && cleanDescription.count <= 5000
            && isEmailValid
    }

    private var isEmailValid: Bool {
        RequestEmailValidator.isValid(email)
    }

    @ViewBuilder private var submitButton: some View {
        if #available(iOS 26, macOS 26, *) {
            Button(role: .confirm, action: submit) {
                submitLabel
            }
            .buttonStyle(.glassProminent)
            .disabled(!isValid || isSubmitting)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        } else {
            Button(action: submit) {
                submitLabel
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isValid || isSubmitting)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }

    private var submitLabel: some View {
        Group {
            if isSubmitting {
                ProgressView()
                    .tint(Color.white)
            } else {
                Text(String(localized: "Submit request", bundle: .module))
                    .fontWeight(.semibold)
            }
        }
        .foregroundStyle(Color.white)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private func submit() {
        guard isValid else { return }
        isSubmitting = true
        Task {
            do {
                let ticket = try await client.createTicket(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    description: description.trimmingCharacters(in: .whitespacesAndNewlines),
                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                    idempotencyKey: idempotencyKey
                )
                if emailUpdates {
                    do { _ = try await client.updateNotificationPreferences(email: email.trimmingCharacters(in: .whitespacesAndNewlines), emailEnabled: true, localNotificationsEnabled: nil) }
                    catch { onEmailError(String(localized: "Your request was saved. Open Updates to retry email setup.", bundle: .module)) }
                }
                onCreated(ticket)
            } catch {
                errorMessage = error.localizedDescription
                isSubmitting = false
            }
        }
    }
}

enum RequestEmailValidator {
    static func isValid(_ email: String) -> Bool {
        let cleanEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanEmail.isEmpty else { return true }
        let zodEmailPattern = #"^(?!\.)(?!.*\.\.)([A-Za-z0-9_'+\-\.]*[A-Za-z0-9_+\-])@([A-Za-z0-9][A-Za-z0-9\-]*\.)+[A-Za-z]{2,}$"#
        return cleanEmail.count <= 320
            && cleanEmail.range(of: zodEmailPattern, options: .regularExpression) != nil
    }
}

private extension View {
    @ViewBuilder
    func buildThisPleaseDismissesCreateRequestKeyboardOnScroll() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }

    @ViewBuilder
    func buildThisPleaseSubmitBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        if #available(iOS 26, macOS 26, *) {
            safeAreaBar(edge: .bottom, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0) {
                content()
                    .background(.bar)
            }
        }
    }
}

private struct RequestField<Content: View>: View {
    let title: String
    let count: Int
    let limit: Int
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)/\(limit)")
                    .foregroundStyle(count > limit ? .red : .secondary)
                    .monospacedDigit()
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding([.leading, .trailing, .bottom], 5)
            .padding(.horizontal, 12)

            content
                .background(BuildThisPleaseSurface.card)
                .clipShape(.rect(cornerRadius: 23, style: .continuous))
        }
    }
}

private struct RequestEmailField: View {
    @Binding var email: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "Email (optional)", bundle: .module))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding([.leading, .trailing, .bottom], 5)
                .padding(.horizontal, 12)

            TextField("", text: $email)
                .textFieldStyle(.plain)
                .buildThisPleaseEmailInputTraits()
                .padding(16)
                .background(BuildThisPleaseSurface.card)
                .clipShape(.rect(cornerRadius: 23, style: .continuous))
                .accessibilityLabel(String(localized: "Email (optional)", bundle: .module))
        }
    }
}

private extension View {
    @ViewBuilder
    func buildThisPleaseEmailInputTraits() -> some View {
        #if os(iOS)
        self
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        #else
        self
        #endif
    }
}
