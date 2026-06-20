import SwiftUI

struct MessageTimelineView: View {
    let store: ChatStore
    var bottomPadding: CGFloat = 0

    private let initialWindowSize = 80
    private let turnBatchSize = 40
    private let maximumWindowSize = 160

    @State private var isPinnedToBottom: Bool = true
    @State private var visibleRange: Range<Int> = 0..<0
    @State private var isAdjustingWindow: Bool = false

    var body: some View {
        Group {
            if store.loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.turns.isEmpty && !store.working {
                ChatEmptyStateView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                timelineScrollView
            }
        }
    }

    private var timelineScrollView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.l) {
                    if hasEarlierTurns {
                        TimelineWindowBoundaryView(text: "Earlier messages")
                            .padding(.horizontal, Spacing.l)
                    }

                    ForEach(visibleTurns) { turn in
                        TurnView(turn: turn, isWorking: store.working && turn.id == store.turns.last?.id)
                            .padding(.horizontal, Spacing.l)
                    }

                    if hasNewerTurns {
                        TimelineWindowBoundaryView(text: "Newer messages")
                            .padding(.horizontal, Spacing.l)
                    }

                    Color.clear
                        .frame(height: 1)
                        .id("bottom-sentinel")
                }
                .padding(.vertical, Spacing.l)
                .frame(maxWidth: 800)
                .frame(maxWidth: .infinity)
            }
            .background(.background)
            .contentMargins(.bottom, max(0, bottomPadding), for: .scrollContent)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentSize.height - geometry.visibleRect.maxY < 80
            } action: { _, isNearWindowBottom in
                if isNearWindowBottom, hasNewerTurns {
                    loadNewerTurns(proxy: proxy)
                    isPinnedToBottom = false
                } else {
                    isPinnedToBottom = isNearWindowBottom && !hasNewerTurns
                }
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.minY < 260
            } action: { _, isNearTop in
                if isNearTop {
                    loadEarlierTurns(proxy: proxy)
                }
            }
            .onChange(of: store.turns.count) { oldCount, newCount in
                reconcileVisibleRange(oldCount: oldCount, newCount: newCount, proxy: proxy)
                if isPinnedToBottom {
                    proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                }
            }
            .onChange(of: store.working) {
                if isPinnedToBottom {
                    proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                }
            }
            .onChange(of: store.streamingRevision) {
                if isPinnedToBottom {
                    proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !isPinnedToBottom {
                    Button {
                        jumpToLatest(proxy: proxy)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.headline.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .tint(.accentColor)
                    .padding(.trailing, Spacing.l)
                    .padding(.bottom, Spacing.l + max(0, bottomPadding))
                    .accessibilityLabel("Jump to latest message")
                }
            }
        }
    }

    private var visibleTurns: [ChatTurn] {
        let range = activeVisibleRange
        guard !range.isEmpty else { return [] }
        return Array(store.turns[range])
    }

    private var hasEarlierTurns: Bool {
        activeVisibleRange.lowerBound > 0
    }

    private var hasNewerTurns: Bool {
        activeVisibleRange.upperBound < store.turns.count
    }

    private var activeVisibleRange: Range<Int> {
        normalizedRange(for: store.turns.count)
    }

    private func loadEarlierTurns(proxy: ScrollViewProxy) {
        guard hasEarlierTurns, !isAdjustingWindow else { return }
        let currentRange = activeVisibleRange
        guard let anchorID = visibleTurns.first?.id else { return }

        isAdjustingWindow = true
        let newLowerBound = max(0, currentRange.lowerBound - turnBatchSize)
        var newRange = newLowerBound..<currentRange.upperBound
        if newRange.count > maximumWindowSize {
            newRange = newLowerBound..<min(currentRange.upperBound, newLowerBound + maximumWindowSize)
        }
        visibleRange = newRange
        preserve(anchorID: anchorID, anchor: .top, proxy: proxy)
    }

    private func loadNewerTurns(proxy: ScrollViewProxy) {
        guard hasNewerTurns, !isAdjustingWindow else { return }
        let currentRange = activeVisibleRange
        guard let anchorID = visibleTurns.last?.id else { return }

        isAdjustingWindow = true
        let newUpperBound = min(store.turns.count, currentRange.upperBound + turnBatchSize)
        var newRange = currentRange.lowerBound..<newUpperBound
        if newRange.count > maximumWindowSize {
            newRange = max(0, newUpperBound - maximumWindowSize)..<newUpperBound
        }
        visibleRange = newRange
        preserve(anchorID: anchorID, anchor: .bottom, proxy: proxy)
    }

    private func jumpToLatest(proxy: ScrollViewProxy) {
        isPinnedToBottom = true
        visibleRange = latestRange(for: store.turns.count)
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
            isAdjustingWindow = false
        }
    }

    private func reconcileVisibleRange(oldCount: Int, newCount: Int, proxy: ScrollViewProxy) {
        guard newCount > 0 else {
            visibleRange = 0..<0
            return
        }

        if oldCount == 0 || visibleRange.isEmpty {
            visibleRange = latestRange(for: newCount)
            return
        }

        if newCount < oldCount {
            visibleRange = latestRange(for: newCount)
            return
        }

        if isPinnedToBottom {
            let currentSize = normalizedRange(for: oldCount).count
            let nextSize = min(maximumWindowSize, max(initialWindowSize, currentSize + (newCount - oldCount)))
            visibleRange = max(0, newCount - nextSize)..<newCount
            Task { @MainActor in
                await Task.yield()
                proxy.scrollTo("bottom-sentinel", anchor: .bottom)
            }
        } else {
            visibleRange = normalizedRange(for: newCount)
        }
    }

    private func preserve(anchorID: UUID, anchor: UnitPoint, proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(anchorID, anchor: anchor)
            isAdjustingWindow = false
        }
    }

    private func normalizedRange(for count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let proposed = visibleRange.isEmpty ? latestRange(for: count) : visibleRange
        let lowerBound = min(max(proposed.lowerBound, 0), count)
        let upperBound = min(max(proposed.upperBound, lowerBound), count)
        guard lowerBound < upperBound else {
            return latestRange(for: count)
        }
        return lowerBound..<upperBound
    }

    private func latestRange(for count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let windowSize = min(initialWindowSize, count)
        return (count - windowSize)..<count
    }
}

private struct TimelineWindowBoundaryView: View {
    let text: String

    var body: some View {
        HStack(spacing: Spacing.s) {
            Image(systemName: "ellipsis")
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.s)
        .accessibilityElement(children: .combine)
    }
}

private struct ChatEmptyStateView: View {
    var body: some View {
        VStack(spacing: Spacing.l) {
            Spacer()
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Start a conversation")
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
