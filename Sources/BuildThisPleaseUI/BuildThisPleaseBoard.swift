import BuildThisPleaseCore
import Foundation
import SwiftUI

/// A standalone feedback screen that owns its navigation stack.
public struct BuildThisPleaseBoard: View {
    private let client: any BuildThisPleaseClientProtocol

    public init(client: any BuildThisPleaseClientProtocol) {
        self.client = client
    }

    public var body: some View {
        NavigationStack {
            BuildThisPleaseFeedbackView(client: client)
        }
    }
}

/// The embeddable feedback destination. Put this view inside a host app's
/// `NavigationLink`, menu, settings screen, tab, or sheet.
public struct BuildThisPleaseFeedbackView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.buildThisPleaseTheme) private var theme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var model: BoardModel

    public init(client: any BuildThisPleaseClientProtocol) {
        _model = State(initialValue: BoardModel(client: client))
    }

    public var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                HStack(spacing: 0) {
                    SectionRail(
                        selection: $model.selectedSection,
                        requestCount: model.requests.count,
                        mineCount: model.mine.count,
                        showsMine: model.showsMineSection,
                        implementedCount: model.implemented.count
                    )
                    .frame(width: 230)
                    Divider()
                    TicketCollection(model: model)
                }
            } else {
                compactCollection
            }
        }
        .background(BuildThisPleaseSurface.canvas)
        .navigationTitle(String(localized: "Feature requests", bundle: .module))
        .buildThisPleaseInlineTitle()
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    model.presentsCreate = true
                } label: {
                    Label(String(localized: "New request", bundle: .module), systemImage: "plus")
                }
            }
        }
        .task(id: scenePhase) { if scenePhase == .active { await model.becameActive() } }
        .buildThisPleasePretranslate((model.currentTickets + model.requests + model.mine + model.implemented).translationTextGroups)
        .sheet(isPresented: $model.presentsCreate) {
            CreateTicketView(client: model.client) { ticket in
                model.created(ticket)
                model.presentsCreate = false
            }
        }
        .navigationDestination(item: $model.selectedTicket) { ticket in
            TicketDetailView(client: model.client, ticket: ticket) { updated in
                model.replace(updated, replacingID: ticket.id)
            }
        }
        .tint(theme.accent)
    }

    @ViewBuilder private var compactCollection: some View {
        if #available(iOS 26, macOS 26, *) {
            TicketCollection(model: model)
                .safeAreaBar(edge: .top) {
                    compactTabs
                }
        } else {
            TicketCollection(model: model)
                .safeAreaInset(edge: .top, spacing: 0) {
                    compactTabs
                        .background(.bar)
                        .overlay(Divider(), alignment: .bottom)
                }
        }
    }

    private var compactTabs: some View {
        WorkfieldTabs(
            selection: $model.selectedSection,
            requestCount: model.requests.count,
            mineCount: model.mine.count,
            showsMine: model.showsMineSection,
            implementedCount: model.implemented.count
        )
    }
}

private struct TicketCollection: View {
    let model: BoardModel

    var body: some View {
        Group {
            if DebugOptions.forceLoadingSkeleton || (model.isLoading && !model.hasLoadedCurrentSection && model.currentTickets.isEmpty) {
                TicketListSkeleton()
            } else if let error = model.errorMessage, model.currentTickets.isEmpty, !model.hasLoadedCurrentSection {
                ContentUnavailableView {
                    Label(String(localized: "Couldn’t load requests", bundle: .module), systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button(String(localized: "Try again", bundle: .module)) {
                        Task { await model.load() }
                    }
                }
            } else if model.currentTickets.isEmpty {
                VStack {
                    if let error = model.errorMessage { ErrorBanner(message: error) { model.errorMessage = nil } }
                    EmptySection(section: model.selectedSection) { model.presentsCreate = true }
                    Button(String(localized: "Try again", bundle: .module), systemImage: "arrow.clockwise") {
                        Task { await model.refreshCurrentSection() }
                    }
                    .padding(.bottom)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        if containsTranslatableContent {
                            DynamicTranslationNotice()
                        }
                        if let error = model.errorMessage {
                            ErrorBanner(message: error) { model.errorMessage = nil }
                        }
                        ForEach(model.currentTickets) { ticket in
                            FeedbackTicketCard(
                                ticket: ticket,
                                implemented: model.selectedSection == .implemented,
                                isVoting: model.votingTicketIDs.contains(ticket.id),
                                open: { model.selectedTicket = ticket },
                                vote: { Task { await model.toggleVote(ticket) } }
                            )
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
                    .frame(maxWidth: 732)
                    .frame(maxWidth: .infinity)
                }
                .refreshable { await model.refreshCurrentSection() }
            }
        }
        .background(BuildThisPleaseSurface.canvas)
    }

    private var containsTranslatableContent: Bool {
        model.currentTickets.contains { ticket in
            DynamicTranslationState.shouldOffer(for: ticket.cardTranslationTexts)
        }
    }
}

private enum DebugOptions {
    #if DEBUG
    static let forceLoadingSkeleton = ProcessInfo.processInfo.arguments.contains("-BuildThisPleaseForceLoadingSkeleton")
    #else
    static let forceLoadingSkeleton = false
    #endif
}

private struct TicketListSkeleton: View {
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<6, id: \.self) { index in
                    SkeletonTicketCard(index: index)
                        .opacity(cardOpacity(for: index))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 28)
            .frame(maxWidth: 732)
            .frame(maxWidth: .infinity)
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Loading requests…", bundle: .module))
    }

    private func cardOpacity(for index: Int) -> Double {
        index < 2 ? 1 : 1 - (Double(index - 1) * 0.2)
    }
}

private struct SkeletonTicketCard: View {
    let index: Int

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 5) {
                placeholder(width: 16, height: 10)
                placeholder(width: 22, height: 15)
            }
            .frame(width: 58)
            .frame(minHeight: 92)

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    flexiblePlaceholder(maxWidth: titleWidth, height: 16)
                    Spacer(minLength: 8)
                    placeholder(width: 62, height: 18)
                }
                flexiblePlaceholder(maxWidth: detailWidth, height: 12)
                flexiblePlaceholder(maxWidth: 150, height: 12)
            }
            .padding(.vertical, 12)
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .buildThisPleaseCard()
        .accessibilityHidden(true)
    }

    private var titleWidth: CGFloat { index.isMultiple(of: 2) ? 172 : 218 }
    private var detailWidth: CGFloat { index.isMultiple(of: 3) ? 230 : 280 }

    private func placeholder(width: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
            .fill(Color.secondary.opacity(0.2))
            .frame(width: width, height: height)
    }

    private func flexiblePlaceholder(maxWidth: CGFloat, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: min(6, height / 2), style: .continuous)
            .fill(Color.secondary.opacity(0.2))
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(height: height)
    }
}

private struct WorkfieldTabs: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selection: BoardModel.Section
    let requestCount: Int
    let mineCount: Int
    let showsMine: Bool
    let implementedCount: Int

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Picker(String(localized: "Request list", bundle: .module), selection: $selection) {
                    sectionLabels
                }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if usesCapsuleSegmentedBackground {
                    Picker(String(localized: "Request list", bundle: .module), selection: $selection) {
                        sectionLabels
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 1)
                    .background(BuildThisPleaseSurface.canvas, in: .capsule)
                    .padding(.bottom, -1)
                } else if #available(iOS 26, macOS 26, *) {
                    Picker(String(localized: "Request list", bundle: .module), selection: $selection) {
                        sectionLabels
                    }
                    .pickerStyle(.segmented)
                    .padding(.bottom, 1)
                    .background(
                        BuildThisPleaseSurface.canvas,
                        in: .rect(cornerRadius: 9, style: .continuous)
                    )
                    .padding(.bottom, -1)
                } else {
                    Picker(String(localized: "Request list", bundle: .module), selection: $selection) {
                        sectionLabels
                    }
                    .pickerStyle(.segmented)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityLabel(String(localized: "Request list", bundle: .module))
    }

    private var usesCapsuleSegmentedBackground: Bool {
        #if os(iOS)
        if #available(iOS 27, *) {
            return true
        }
        #endif
        return false
    }

    @ViewBuilder private var sectionLabels: some View {
        Text("\(String(localized: "Requests", bundle: .module)) (\(requestCount))").tag(BoardModel.Section.requests)
        if showsMine {
            Text("\(String(localized: "Mine", bundle: .module)) (\(mineCount))").tag(BoardModel.Section.mine)
        }
        Text("\(String(localized: "Done", bundle: .module)) (\(implementedCount))").tag(BoardModel.Section.implemented)
    }
}

private struct SectionRail: View {
    @Binding var selection: BoardModel.Section
    let requestCount: Int
    let mineCount: Int
    let showsMine: Bool
    let implementedCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "Feature requests", bundle: .module))
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            sectionButton(.requests, title: String(localized: "Requests", bundle: .module), icon: "rectangle.3.group", count: requestCount)
            if showsMine {
                sectionButton(.mine, title: String(localized: "Mine", bundle: .module), icon: "person.crop.circle", count: mineCount)
            }
            sectionButton(.implemented, title: String(localized: "Done", bundle: .module), icon: "checkmark.seal", count: implementedCount)
            Spacer()
        }
        .padding(.top, 20)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
    }

    private func sectionButton(_ section: BoardModel.Section, title: String, icon: String, count: Int) -> some View {
        Button { selection = section } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text(count, format: .number).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(selection == section ? Color.accentColor.opacity(0.14) : Color.clear, in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .accessibilityAddTraits(selection == section ? .isSelected : [])
    }
}

private struct FeedbackTicketCard: View {
    @Environment(\.buildThisPleaseTheme) private var theme
    @State private var translation = DynamicTranslationState()
    let ticket: BuildThisPleaseTicket
    let implemented: Bool
    let isVoting: Bool
    let open: () -> Void
    let vote: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            leadingAction
            VStack(alignment: .leading, spacing: 0) {
                Button(action: open) {
                    cardContent
                }
                .buttonStyle(.plain)
                if translation.showsStatus(for: translatableTexts) {
                    DynamicTranslationDisclosure(state: $translation, texts: translatableTexts)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                }
            }
        }
        .buildThisPleaseCard()
        .accessibilityElement(children: .contain)
        .buildThisPleaseTranslatable(state: $translation, texts: translatableTexts)
    }

    @ViewBuilder private var leadingAction: some View {
        if implemented {
            Image(systemName: "checkmark.seal.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .frame(width: 58)
                .frame(minHeight: 76)
                .accessibilityHidden(true)
        } else if ticket.voteCount != nil && [.inReview, .planned, .inProgress].contains(ticket.status) {
            Button(action: vote) {
                Group {
                    if isVoting {
                        ProgressView()
                    } else {
                        VStack(spacing: 4) {
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
                .frame(width: 58)
                .frame(minHeight: 92)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(isVoting)
            .accessibilityLabel(ticket.hasVoted == true ? String(localized: "Remove vote", bundle: .module) : String(localized: "Vote for this request", bundle: .module))
            .accessibilityValue(Text(ticket.voteCount ?? 0, format: .number))
        } else {
            Image(systemName: "person.crop.circle")
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 58)
                .frame(minHeight: 92)
                .accessibilityHidden(true)
        }
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Text(translation.text(at: 0, original: ticket.title, texts: translatableTexts))
                    .font(.body.weight(.semibold))
                    .multilineTextAlignment(.leading)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if ticket.status != .implemented {
                    StatusLabel(status: ticket.status, compact: true)
                        .fixedSize()
                        .offset(x: 2, y: 0)
                }
            }
            Text(translation.text(at: 1, original: detailText, texts: translatableTexts))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .lineLimit(implemented ? 3 : 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.trailing, 14)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        [
            translation.text(at: 0, original: ticket.title, texts: translatableTexts),
            ticket.status.displayName,
            translation.text(at: 1, original: detailText, texts: translatableTexts)
        ]
            .joined(separator: ", ")
    }

    private var detailText: String { ticket.implementationNote ?? ticket.description }
    private var translatableTexts: [String] { ticket.cardTranslationTexts }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: dismiss) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .accessibilityLabel(String(localized: "Dismiss", bundle: .module))
        }
        .padding(14)
        .background(.red.opacity(0.10), in: .rect(cornerRadius: 12))
    }
}

struct StatusLabel: View {
    let status: BuildThisPleaseTicketStatus
    var compact = false

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .textCase(.uppercase)
            .padding(.horizontal, 7)
            .padding(.vertical, compact ? 2 : 4)
            .background(status.color.opacity(0.18), in: .capsule)
            .foregroundStyle(status.color)
    }
}

private struct EmptySection: View {
    let section: BoardModel.Section
    let create: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        } actions: {
            if section != .implemented {
                Button(String(localized: "New request", bundle: .module), action: create)
            }
        }
    }

    private var title: String {
        switch section {
        case .requests: String(localized: "No public requests", bundle: .module)
        case .mine: String(localized: "Nothing submitted yet", bundle: .module)
        case .implemented: String(localized: "Nothing implemented yet", bundle: .module)
        }
    }

    private var detail: String {
        switch section {
        case .requests: String(localized: "Requests under review, planned, or being built will appear here.", bundle: .module)
        case .mine: String(localized: "Requests submitted from this installation appear here, including pending requests.", bundle: .module)
        case .implemented: String(localized: "Implemented requests and release notes will appear here without vote totals.", bundle: .module)
        }
    }

    private var icon: String {
        switch section {
        case .requests: "rectangle.3.group"
        case .mine: "person.crop.circle"
        case .implemented: "checkmark.seal"
        }
    }
}

extension BuildThisPleaseTicketStatus {
    var color: Color {
        switch self {
        case .pending: .orange
        case .inReview: .cyan
        case .planned: .purple
        case .inProgress: .blue
        case .implemented: .green
        case .rejected: .red
        case .merged, .archived: .secondary
        }
    }
}
