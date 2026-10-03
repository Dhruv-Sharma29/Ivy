import SwiftUI
import UniformTypeIdentifiers
import IvyCore

/// Above the composer: what will be sent with the next message. The user always sees
/// exactly what goes out (thumbnail, label, masked regions) before pressing Return.
struct AttachmentBar: View {
    @ObservedObject var tray: AttachmentTray

    var body: some View {
        if tray.lastError != nil || tray.isWorking || !tray.attachments.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if let error = tray.lastError {
                    HStack {
                        Text(error).font(.callout).foregroundStyle(.primary)
                        Spacer()
                        Button("Dismiss") { tray.dismissError() }.buttonStyle(.plain).font(.system(size: 11))
                    }
                }
                HStack(spacing: 8) {
                    if tray.isWorking {
                        ProgressView().controlSize(.small)
                        Text("Reading on this Mac…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(tray.attachments) { attachment in
                                AttachmentChip(attachment: attachment) { tray.remove(attachment.id) }
                            }
                        }
                    }
                    if !tray.attachments.isEmpty {
                        Text(tray.summary).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
    }
}

/// Attachment actions belong to the composer, beside the text being sent.
struct AttachmentMenu: View {
    @ObservedObject var tray: AttachmentTray

    var body: some View {
        attachmentMenu
            .buttonStyle(ComposerControlStyle())
            .help("Show Ivy your screen, an image or a PDF")
            .accessibilityLabel("Attach")
            .accessibilityIdentifier("ivy.attach")
    }

    @ViewBuilder
    private var attachmentMenu: some View {
        if #available(macOS 26.0, *) {
            menu.menuStyle(.button)
        } else {
            menu.menuStyle(.borderlessButton)
        }
    }

    private var menu: some View {
        Menu {
            Button("Front Window") { Task { await tray.capture(.frontWindow) } }
            Button("Whole Screen") { Task { await tray.capture(.display) } }
            Button("Select a Region…") { Task { await tray.capture(.region) } }
            Divider()
            Button("Image or PDF…", action: pickFile)
        } label: {
            Image(systemName: "plus").font(.system(size: 18)).foregroundStyle(.primary)
        }
        .menuIndicator(.hidden)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image, .pdf]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { await tray.addFile(url) }
        }
    }
}

/// One attachment: thumbnail (images) or icon (text-only, PDFs), its label, and a remove button while composing.
struct AttachmentChip: View {
    let attachment: ImageAttachment
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 6) {
            if let first = attachment.jpeg.first, let image = NSImage(data: first) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: icon).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.label).font(.system(size: 11)).lineLimit(1)
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
            }
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Remove \(attachment.label)")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .ivyGlass(cornerRadius: 8)
        .help(attachment.text.map { "Text found: " + String($0.prefix(300)) } ?? "No text found")
    }

    private var icon: String {
        if case .pdf = attachment.source { return "doc.richtext" }
        return "text.viewfinder"
    }

    private var detail: String {
        var parts: [String] = []
        if attachment.jpeg.isEmpty { parts.append("text only") }
        if attachment.maskedRegions > 0 { parts.append("\(attachment.maskedRegions) hidden (looked like a key)") }
        parts.append("not saved")
        return parts.joined(separator: " · ")
    }
}
