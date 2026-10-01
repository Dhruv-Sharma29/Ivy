import AppKit
import IvyCore

/// Saves a redacted export where the user chooses (save panel only). Shared by the popover list and the sidebar.
@MainActor
enum ConversationFileExport {
    static func run(_ library: ConversationLibrary, id: UUID, title: String, format: ConversationExporter.Format) {
        guard let data = library.export(id, format: format) else { return }
        let panel = NSSavePanel()
        let safeName = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(safeName.prefix(60)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
