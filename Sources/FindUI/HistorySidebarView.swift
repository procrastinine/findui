import SearchBackend
import SwiftUI

struct HistorySidebarView: View, Equatable {
    let viewModel: SearchViewModel
    private let modelID: ObjectIdentifier
    private let history: [SearchHistoryEntry]
    private let selection: SearchHistoryEntry.ID?

    init(viewModel: SearchViewModel) {
        self.viewModel = viewModel
        modelID = ObjectIdentifier(viewModel)
        history = viewModel.history
        selection = viewModel.selectedHistoryEntryID
    }

    // Result streaming, row selection, and preview changes do not change history.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.modelID == rhs.modelID && lhs.history == rhs.history && lhs.selection == rhs.selection
    }

    var body: some View {
        let ordered = SearchViewModel.orderHistory(history)
        let pinned = ordered.filter(\.isPinned)
        let unpinned = ordered.filter { !$0.isPinned }
        VStack(spacing: 0) {
            PaneHeader(title: "Search History")
            List {
                if ordered.isEmpty {
                    Text("No history yet")
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10))
                } else {
                    if !pinned.isEmpty {
                        // List's scroll-content margins are ignored by the
                        // native plain table on some macOS versions.
                        Color.clear.frame(height: 6)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                            .accessibilityHidden(true)
                        ForEach(pinned) { entry in
                            historyRow(entry)
                        }
                        .onMove(perform: viewModel.movePinnedHistory)
                    }

                    if !pinned.isEmpty && !unpinned.isEmpty {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.34))
                            .frame(height: 1)
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }

                    ForEach(unpinned) { entry in
                        historyRow(entry)
                    }
                }
            }
            .listStyle(.plain)
            .environment(\.defaultMinListRowHeight, 1)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Clear History") { viewModel.clearHistory() }
                    .nativeUtilityButtonStyle()
                    .disabled(history.isEmpty)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 44)
        }
    }

    private func historyRow(_ entry: SearchHistoryEntry) -> some View {
        let selected = isSelected(entry)

        return HStack(spacing: 8) {
            Button {
                viewModel.runHistoryEntry(entry)
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.snapshot.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(entry.snapshot.summary) · \(matchLabel(for: entry.resultCount))")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? Color.white.opacity(0.82) : .secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.snapshot.parameterDescription)

            Button {
                viewModel.togglePinned(entry)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                    .foregroundStyle(selected ? Color.white : (entry.isPinned ? Color.accentColor : .secondary))
                    .frame(width: 24, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.isPinned ? "Unpin Search" : "Pin Search")
            .accessibilityLabel(entry.isPinned ? "Unpin Search" : "Pin Search")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .foregroundStyle(selected ? Color.white : Color.primary)
        .contextMenu {
            Button("Run Search") {
                viewModel.runHistoryEntry(entry)
            }
            Button(entry.isPinned ? "Unpin Search" : "Pin Search") {
                viewModel.togglePinned(entry)
            }
            Button("Delete Search") {
                viewModel.deleteHistoryEntry(entry)
            }
        }
        .listRowInsets(EdgeInsets())
        .listRowBackground(selected ? Color.accentColor : Color.clear)
        .listRowSeparator(.hidden)
    }

    private func isSelected(_ entry: SearchHistoryEntry) -> Bool {
        selection == entry.id
    }

    private func matchLabel(for count: Int) -> String {
        count == 1 ? "1 result" : "\(count) results"
    }
}
