import BuildThisPleaseCore
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

struct TicketDetailView: View {
    @State private var model: TicketDetailModel
    @State private var ticketTranslation = DynamicTranslationState()
    @FocusState private var isReplyFocused: Bool
    private let conversationBottom = "conversation-bottom"

    init(client: any BuildThisPleaseClientProtocol, ticket: BuildThisPleaseTicket, onTicketUpdated: @escaping (BuildThisPleaseTicket) -> Void) {
        _model = State(initialValue: TicketDetailModel(client: client, ticket: ticket, onTicketUpdated: onTicketUpdated))
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 16) {
                    if hasTranslatableContent {
                        DynamicTranslationNotice()
                    }
                    TicketDetailSummary(
                        ticket: model.ticket,
                        isVoting: model.isVoting,
                        translation: $ticketTranslation
                    ) {
                        Task { await model.toggleVote() }
                    }
                    if !model.comments.isEmpty {
                        ConversationSection(comments: model.comments) { comment in
                            model.editingComment = comment
                        }
                    }

                    if let error = model.errorMessage {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(14)
                            .background(.red.opacity(0.10), in: .rect(cornerRadius: 12))
                    }
                    Color.clear.frame(height: 1).id(conversationBottom)
                }
                .frame(maxWidth: 700)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .buildThisPleaseDismissesKeyboardOnScroll()
            .buildThisPleaseConversationBar {
                conversationBar
            }
            .onChange(of: model.comments.count) {
                withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(conversationBottom, anchor: .bottom) }
            }
        }
        .background(BuildThisPleaseSurface.canvas)
        .navigationTitle(ticketTranslation.text(at: 0, original: model.ticket.title, texts: ticketTexts))
        .buildThisPleaseInlineTitle()
        .refreshable { await model.load() }
        .task { await model.load() }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    Task { await model.toggleFollowing() }
                } label: { Label(model.isFollowing == true ? String(localized: "Stop updates", bundle: .module) : String(localized: "Follow request", bundle: .module), systemImage: model.isFollowing == true ? "bell.slash" : "bell") }
                .disabled(model.isFollowing == nil || model.isChangingFollow || model.isVoting || model.isLoading)
            }
        }
        .buildThisPleasePretranslate(
            [ticketTexts]
                + model.comments.compactMap { comment in
                    guard !comment.isHidden, let body = comment.body else { return nil }
                    return [body]
                }
        )
        .onAppear(perform: resetKeyboardState)
        .onDisappear(perform: resetKeyboardState)
        .sheet(item: $model.editingComment) { comment in
            EditMessageView(comment: comment) { body in
                await model.updateComment(comment, body: body)
            }
        }
    }

    @ViewBuilder private var conversationBar: some View {
        if model.ticket.commentsLocked {
            Label(String(localized: "This conversation is read-only.", bundle: .module), systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
        } else {
            ReplyComposer(reply: $model.reply, isSending: model.isSending, isFocused: $isReplyFocused) {
                Task { await model.sendReply() }
            }
        }
    }

    private func resetKeyboardState() {
        isReplyFocused = false
        dismissKeyboard()
    }

    private var hasTranslatableContent: Bool {
        if DynamicTranslationState.shouldOffer(for: ticketTexts) {
            return true
        }

        return model.comments.contains { comment in
            guard !comment.isHidden, let body = comment.body else { return false }
            return DynamicTranslationState.shouldOffer(for: [body])
        }
    }

    private var ticketTexts: [String] {
        model.ticket.detailTranslationTexts
    }

    @MainActor
    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        #endif
    }
}

extension View {
    @ViewBuilder func buildThisPleaseInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

}

private extension View {
    @ViewBuilder
    func buildThisPleaseDismissesKeyboardOnScroll() -> some View {
        #if os(iOS)
        self.scrollDismissesKeyboard(.interactively)
        #else
        self
        #endif
    }
}

private struct TicketDetailSummary: View {
    @Environment(\.buildThisPleaseTheme) private var theme
    let ticket: BuildThisPleaseTicket
    let isVoting: Bool
    @Binding var translation: DynamicTranslationState
    let toggleVote: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if canVote {
                Button(action: toggleVote) {
                    Group {
                        if isVoting {
                            ProgressView()
                        } else {
                            VStack(spacing: 5) {
                                Image(systemName: "arrowtriangle.up.fill")
                                    .foregroundStyle(ticket.hasVoted == true ? theme.voteHighlight : BuildThisPleaseSurface.tertiaryLabel)
                                Text(ticket.voteCount ?? 0, format: .number)
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(ticket.hasVoted == true ? theme.voteHighlight : Color.primary)
                            }
                        }
                    }
                    .frame(width: 48)
                    .frame(minHeight: 64)
                    .frame(width: 66)
                    .frame(minHeight: 92)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(isVoting || ticket.voteLocked == true)
                .accessibilityLabel(ticket.voteLocked == true ? String(localized: "Author vote (permanent)", bundle: .module) : ticket.hasVoted == true ? String(localized: "Remove vote", bundle: .module) : String(localized: "Vote for this request", bundle: .module))
                .accessibilityValue(Text(ticket.voteCount ?? 0, format: .number))
            } else if ticket.status == .implemented {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
                    .frame(width: 62)
                    .frame(minHeight: 88)
                    .accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 10) {
                StatusLabel(status: ticket.status)
                Text(translation.text(at: 1, original: ticket.description, texts: translatableTexts))
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = ticket.implementationNote {
                    Label(translation.text(at: 2, original: note, texts: translatableTexts), systemImage: "checkmark.seal")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                DynamicTranslationDisclosure(state: $translation, texts: translatableTexts)
            }
            .padding(.vertical, 14)
            .padding(.trailing, 14)
            .padding(.leading, canVote || ticket.status == .implemented ? 0 : 14)
        }
        .buildThisPleaseCard()
        .buildThisPleaseTranslatable(state: $translation, texts: translatableTexts)
    }

    private var canVote: Bool {
        ticket.voteCount != nil && [.inReview, .planned, .inProgress].contains(ticket.status)
    }

    private var translatableTexts: [String] {
        ticket.detailTranslationTexts
    }
}

private struct ConversationSection: View {
    @State private var translations: [String: DynamicTranslationState] = [:]
    let comments: [BuildThisPleaseComment]
    let edit: (BuildThisPleaseComment) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Conversation", bundle: .module))
                .font(.callout.weight(.medium))
                .textCase(nil)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)

            LazyVStack(spacing: 14) {
                ForEach(comments) { comment in
                    CommentBubble(
                        comment: comment,
                        translation: translationBinding(for: comment.id)
                    ) {
                        edit(comment)
                    }
                }
            }
            .padding(14)
            .buildThisPleaseCard()
        }
    }

    private func translationBinding(for commentID: String) -> Binding<DynamicTranslationState> {
        Binding(
            get: { translations[commentID] ?? DynamicTranslationState() },
            set: { translations[commentID] = $0 }
        )
    }
}

private struct ReplyComposer: View {
    @Binding var reply: String
    let isSending: Bool
    let isFocused: FocusState<Bool>.Binding
    let send: () -> Void

    @ViewBuilder
    var body: some View {
        composer
        #if os(iOS)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    if isFocused.wrappedValue {
                        Button {
                            isFocused.wrappedValue = false
                        } label: {
                            Image(systemName: "keyboard.chevron.compact.down")
                                .font(.subheadline)
                        }
                        .accessibilityLabel(String(localized: "Dismiss keyboard", bundle: .module))
                    }
                }
            }
        #endif
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(String(localized: "Write a message", bundle: .module), text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .focused(isFocused)
                .submitLabel(.return)
                .padding(.leading, 14)
                .padding(.vertical, 11)
                .padding(.trailing, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            sendButton
        }
        .buildThisPleaseComposerSurface()
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder private var sendButton: some View {
        if #available(iOS 26, macOS 26, *) {
            Button(action: send) {
                sendButtonLabel
            }
            .frame(width: 36, height: 36)
            .glassEffect(.regular.tint(isSendDisabled ? Color.secondary.opacity(0.35) : Color.accentColor).interactive(), in: .circle)
            .buttonStyle(.plain)
            .disabled(isSendDisabled)
            .padding(.trailing, 4)
            .padding(.bottom, 4)
            .accessibilityLabel(String(localized: "Send reply", bundle: .module))
        } else {
            Button(action: send) {
                sendButtonLabel
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSendDisabled)
            .accessibilityLabel(String(localized: "Send reply", bundle: .module))
        }
    }

    private var sendButtonLabel: some View {
        Group {
            if isSending {
                ProgressView()
            } else {
                Image(systemName: "arrow.up")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 22, height: 22)
    }

    private var isSendDisabled: Bool {
        reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending
    }
}

private extension View {
    @ViewBuilder
    func buildThisPleaseComposerSurface() -> some View {
        if #available(iOS 26, macOS 26, *) {
            self
                .background(RoundedRectangle(cornerRadius: 23, style: .continuous).fill(Color.clear))
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 23))
        } else {
            self
                .background(BuildThisPleaseSurface.card, in: .rect(cornerRadius: 23, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 23, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2))
                }
        }
    }
}

private extension View {
    @ViewBuilder
    func buildThisPleaseConversationBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
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

private struct CommentBubble: View {
    @Environment(\.buildThisPleaseTheme) private var theme
    let comment: BuildThisPleaseComment
    @Binding var translation: DynamicTranslationState
    let edit: () -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if isMine { Spacer(minLength: 52) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 5) {
                Text(authorLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 17)
                Text(displayedBody)
                    .foregroundStyle(comment.isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(isMine ? Color.white : Color.primary))
                    .italic(comment.isHidden)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 10)
                    .background(bubbleColor, in: .rect(cornerRadius: 17, style: .continuous))
                    .accessibilityLabel(
                        "\(authorLabel), \(displayedBody)"
                    )
                HStack(spacing: 5) {
                    Text(comment.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    if comment.isEdited { Text(String(localized: "Edited", bundle: .module)) }
                    if !comment.isApproved { Text(String(localized: "Awaiting approval", bundle: .module)) }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 17)
                DynamicTranslationDisclosure(state: $translation, texts: translatableTexts)
                    .padding(.horizontal, 17)
            }
            .frame(maxWidth: 520, alignment: isMine ? .trailing : .leading)
            .contextMenu {
                if isMine && !comment.isHidden {
                    Button(String(localized: "Edit message", bundle: .module), systemImage: "pencil", action: edit)
                }
            }
            if !isMine { Spacer(minLength: 52) }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: String(localized: "Edit message", bundle: .module)) {
            if isMine && !comment.isHidden { edit() }
        }
        .buildThisPleaseTranslatable(state: $translation, texts: translatableTexts)
    }

    private var isMine: Bool { comment.isMine }
    private var authorLabel: String {
        if comment.author == .administrator { return String(localized: "Team", bundle: .module) }
        return isMine
            ? String(localized: "You", bundle: .module)
            : String(localized: "User", bundle: .module)
    }
    private var originalBody: String { comment.body ?? "" }
    private var translatableTexts: [String] { comment.isHidden ? [] : [originalBody] }
    private var displayedBody: String {
        comment.isHidden
            ? String(localized: "Message removed", bundle: .module)
            : translation.text(at: 0, original: originalBody, texts: translatableTexts)
    }
    private var bubbleColor: Color {
        if comment.isHidden { return BuildThisPleaseSurface.field }
        return isMine ? theme.accent : BuildThisPleaseSurface.conversationBubble
    }
}

private struct EditMessageView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    let save: (String) async -> Bool

    init(comment: BuildThisPleaseComment, save: @escaping (String) async -> Bool) {
        _draft = State(initialValue: comment.body ?? "")
        self.save = save
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextEditor(text: $draft)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 140)
                    .background(BuildThisPleaseSurface.card, in: .rect(cornerRadius: 14, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.secondary.opacity(0.22)) }
                if let errorMessage { Text(errorMessage).font(.callout).foregroundStyle(.red) }
                Spacer()
            }
            .padding(16)
            .background(BuildThisPleaseSurface.canvas)
            .navigationTitle(String(localized: "Edit message", bundle: .module))
            .buildThisPleaseInlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Cancel", bundle: .module), role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Save", bundle: .module)) {
                        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        isSaving = true
                        Task {
                            if await save(trimmed) { dismiss() }
                            else {
                                errorMessage = String(localized: "The message could not be updated.", bundle: .module)
                                isSaving = false
                            }
                        }
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || draft.count > 5_000 || isSaving)
                }
            }
            .interactiveDismissDisabled(isSaving)
        }
        .presentationDetents([.medium])
    }
}
