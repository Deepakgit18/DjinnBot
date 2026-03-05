import SwiftUI

/// A standalone window that displays the in-memory debug log.
///
/// Features:
/// - Live-updating log entries with auto-scroll
/// - Filter by level (debug/info/warn/error) and category
/// - Full-text search
/// - Copy selection or export all to clipboard
/// - Clear button
struct DebugLogWindow: View {
    @ObservedObject private var store = LogStore.shared
    @State private var autoScroll = true
    @State private var selectedEntryID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            filterBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)

            Divider()

            // Log entries
            ScrollViewReader { proxy in
                List(store.filteredEntries, selection: $selectedEntryID) { entry in
                    logRow(entry)
                        .id(entry.id)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                }
                .listStyle(.plain)
                .font(.system(.caption, design: .monospaced))
                .onChange(of: store.filteredEntries.count) { _, _ in
                    if autoScroll, let last = store.filteredEntries.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Divider()

            // Status bar
            statusBar
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.bar)
        }
        .frame(minWidth: 700, idealWidth: 900, minHeight: 400, idealHeight: 600)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: 8) {
            // Search
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                    .font(.caption)
                TextField("Filter logs...", text: $store.searchText)
                    .textFieldStyle(.plain)
                    .font(.caption)
                if !store.searchText.isEmpty {
                    Button {
                        store.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.05))
            )
            .frame(maxWidth: 250)

            // Level filter
            Picker("Level", selection: $store.filterLevel) {
                Text("All Levels").tag(nil as LogStore.Level?)
                ForEach(LogStore.Level.allCases, id: \.self) { level in
                    Label(level.rawValue, systemImage: level.icon)
                        .tag(level as LogStore.Level?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 120)

            // Category filter
            Picker("Category", selection: $store.filterCategory) {
                Text("All Categories").tag(nil as LogStore.Category?)
                ForEach(LogStore.Category.allCases, id: \.self) { cat in
                    Text(cat.rawValue).tag(cat as LogStore.Category?)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 140)

            Spacer()

            // Auto-scroll toggle
            Toggle(isOn: $autoScroll) {
                Image(systemName: "arrow.down.to.line")
                    .font(.caption)
            }
            .toggleStyle(.button)
            .help("Auto-scroll to bottom")

            // Copy to clipboard
            Button {
                let text = store.exportText()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
            }
            .help("Copy all visible logs to clipboard")

            // Save to file
            Button {
                saveToFile()
            } label: {
                Image(systemName: "square.and.arrow.down")
                    .font(.caption)
            }
            .help("Save logs to file")

            // Clear
            Button(role: .destructive) {
                store.clear()
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
            }
            .help("Clear all logs")
        }
    }

    // MARK: - Log Row

    private func logRow(_ entry: LogStore.Entry) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Timestamp
            Text(entry.formattedTimestamp)
                .foregroundStyle(.tertiary)
                .frame(width: 85, alignment: .leading)

            // Level badge
            Text(entry.level.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(entry.level.color)
                .frame(width: 42, alignment: .leading)

            // Category badge
            Text(entry.category.rawValue)
                .font(.caption2)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(entry.category.color.opacity(0.15))
                )
                .foregroundStyle(entry.category.color)
                .frame(width: 100, alignment: .leading)

            // Message
            Text(entry.message)
                .foregroundStyle(entry.level == .error ? .red : entry.level == .warning ? .orange : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            Text("\(store.filteredEntries.count) of \(store.entries.count) entries")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if store.filterLevel != nil || store.filterCategory != nil || !store.searchText.isEmpty {
                Button("Clear Filters") {
                    store.filterLevel = nil
                    store.filterCategory = nil
                    store.searchText = ""
                }
                .font(.caption2)
                .buttonStyle(.link)
            }
        }
    }

    // MARK: - Actions

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "dialogue-debug-\(ISO8601DateFormatter().string(from: Date())).log"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let text = store.exportText()
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
