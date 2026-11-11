import SwiftUI
import UniformTypeIdentifiers

/// The Cloud tab, in the same layout as Links: a 368 pt sidebar of cards
/// (accounts, add account, shared link) and, on the right, this Mac and the
/// cloud side by side like a file-transfer app. Drag between the two (or use
/// the arrow buttons) to copy whole folders either way.
struct CloudView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cloud: CloudModel

    var body: some View {
        HStack(spacing: 0) {
            CloudSidebar(cloud: cloud)
                .frame(width: 368)
                .background(Theme.sidebar)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            CloudMain(cloud: cloud)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .sheet(isPresented: $cloud.showConnect) { ConnectSheet(cloud: cloud) }
        .sheet(isPresented: $cloud.showLink) { LinkSheet(cloud: cloud) }
        .onAppear { cloud.activate() }
    }
}

// MARK: - Sidebar

struct CloudSidebar: View {
    @ObservedObject var cloud: CloudModel
    @Local private var confirmRemove: CloudAccount?

    var body: some View {
        VStack(spacing: 12) {
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    if !cloud.accounts.isEmpty { accountsCard }
                    if cloud.status?.available == true {
                        ActionCard(icon: "plus", title: "Add account",
                                   subtitle: "Google Drive, Dropbox, OneDrive and more") { cloud.showConnect = true }
                        if cloud.accounts.contains(where: { $0.type == "drive" }) {
                            ActionCard(icon: "link", title: "Open a shared link",
                                       subtitle: "Browse a Drive folder someone sent you") { cloud.showLink = true }
                        }
                    }
                }
                .padding(.top, 48)
                .padding(.horizontal, 14)
            }
            Footer().padding(.horizontal, 20).padding(.bottom, 14)
        }
        .confirmationDialog("Remove \(confirmRemove?.label ?? "this account")?",
                            isPresented: Binding(get: { confirmRemove != nil }, set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { acct in
            Button("Remove Account", role: .destructive) { cloud.disconnect(acct) }
        } message: { _ in
            Text("Dwn forgets this account. Nothing in it is deleted, and you can add it again later.")
        }
    }

    private var accountsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Accounts").sectionLabel()
            ForEach(Array(cloud.accounts.enumerated()), id: \.element.id) { i, acct in
                if i > 0 { Rectangle().fill(Theme.stroke).frame(height: 1).padding(.vertical, 4) }
                accountSection(acct)
            }
        }
        .padding(14)
        .card(Theme.card, radius: 16)
    }

    private func accountSection(_ acct: CloudAccount) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                ServiceIcon(type: acct.type, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(acct.service).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    if let e = acct.email {
                        Text(e).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer(minLength: 4)
                Menu {
                    Button("Sign In Again") { cloud.reconnect(acct) }
                    Divider()
                    Button("Remove Account…") { confirmRemove = acct }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(IconButtonStyle(size: 28)).menuIndicator(.hidden)
                    .fixedSize()
            }
            .padding(.bottom, 6)
            ForEach(acct.views, id: \.id) { v in
                let loc = CloudLocation(account: acct.name, view: v.id)
                SidebarRow(icon: viewIcon(v.id), title: v.title,
                           selected: cloud.location?.root == loc) { cloud.open(loc) }
            }
            ForEach(cloud.links.filter { $0.account == acct.name }) { l in
                let loc = CloudLocation(account: acct.name, view: "link", link: l.link)
                SidebarRow(icon: "link", title: l.title, selected: cloud.location?.root == loc) { cloud.open(loc) }
                    .contextMenu {
                        Button("Copy Link") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(l.link, forType: .string)
                        }
                        Button("Remove from Sidebar") { cloud.removeLink(l) }
                    }
            }
            if let u = cloud.usage[acct.name], u.total > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressBar(value: u.used / u.total)
                    Text("\(formatBytes(u.used)) of \(formatBytes(u.total)) used")
                        .font(.ui(11)).foregroundStyle(Theme.text3)
                }
                .padding(.horizontal, 4).padding(.top, 8)
            }
        }
    }

    private func viewIcon(_ id: String) -> String {
        switch id {
        case "shared": return "person.2"
        case "shared_files": return "doc.on.doc"
        default: return "folder"
        }
    }
}

/// A one-tap card in the sidebar, styled like Links' "Bulk download" card.
struct ActionCard: View {
    var icon: String
    var title: String
    var subtitle: String
    var action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.ui(15, .medium)).foregroundStyle(Theme.text2)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.06)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                    Text(subtitle).font(.ui(11.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            .card(hover ? Theme.raised : Theme.card, radius: 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct SidebarRow: View {
    var icon: String
    var title: String
    var selected: Bool
    var action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.ui(M.icon, .medium)).frame(width: M.iconColumn)
                    .foregroundStyle(selected ? Theme.text : Theme.text3)
                Text(title).font(.ui(13, .medium)).lineLimit(1)
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                Spacer()
            }
            .padding(.horizontal, 12).frame(height: M.control)
            .background(RoundedRectangle(cornerRadius: M.r, style: .continuous)
                .fill(Color.white.opacity(selected ? 0.10 : (hover ? 0.045 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }
}

struct ServiceIcon: View {
    var type: String
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(color))
    }

    private var symbol: String {
        switch type {
        case "drive": return "triangle"
        case "dropbox": return "shippingbox"
        case "box": return "square"
        default: return "cloud"
        }
    }

    private var color: Color {
        switch type {
        case "drive": return Color(red: 0.13, green: 0.59, blue: 0.33)
        case "dropbox": return Color(red: 0.0, green: 0.38, blue: 1.0)
        case "onedrive": return Color(red: 0.0, green: 0.47, blue: 0.84)
        case "box": return Color(red: 0.0, green: 0.38, blue: 0.84)
        default: return Color(red: 0.08, green: 0.62, blue: 0.75)
        }
    }
}

// MARK: - Main area

struct CloudMain: View {
    @ObservedObject var cloud: CloudModel

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.black.opacity(0.35), Theme.bg], startPoint: .top, endPoint: .init(x: 0.5, y: 0.25))
                .ignoresSafeArea()
            if let s = cloud.status, !s.available {
                RcloneMissing()
            } else if let s = cloud.status, s.accounts.isEmpty {
                CloudWelcome(cloud: cloud)
            } else if cloud.status == nil {
                ProgressView().controlSize(.small)
            } else {
                VStack(spacing: 0) {
                    topBar
                    HStack(spacing: 12) {
                        LocalPane(cloud: cloud)
                        RemotePane(cloud: cloud)
                    }
                    .padding(.horizontal, 22)
                    .padding(.bottom, cloud.transfers.isEmpty ? 22 : 12)
                    if !cloud.transfers.isEmpty { TransfersPanel(cloud: cloud) }
                }
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                TextField("", text: $cloud.filter, prompt: Text("Filter files").foregroundStyle(Theme.text3))
                    .textFieldStyle(.plain).font(.ui(13.5)).foregroundStyle(Theme.text)
                if !cloud.filter.isEmpty {
                    Button { cloud.filter = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.text3)
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 280, height: 34)
            .background(Capsule().fill(Theme.card))
            .overlay(Capsule().strokeBorder(Theme.stroke))
            Spacer()
        }
        .padding(.leading, 22)
        .padding(.trailing, 110)
        .padding(.top, 12)
        .frame(height: 64, alignment: .top)
    }
}

// MARK: - File rows

private func fileIcon(name: String, isDir: Bool, mime: String? = nil) -> String {
    if isDir { return "folder.fill" }
    let ext = (name as NSString).pathExtension.lowercased()
    if let m = mime, m.hasPrefix("application/vnd.google-apps") || m.contains("officedocument") { return "doc.text" }
    switch ext {
    case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff", "raw", "cr2", "nef", "arw", "dng", "psd": return "photo"
    case "mp4", "mov", "mkv", "avi", "m4v", "webm", "mxf", "braw", "r3d": return "film"
    case "mp3", "wav", "aac", "m4a", "flac", "aiff", "ogg": return "waveform"
    case "pdf": return "doc.richtext"
    case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
    case "txt", "md", "rtf", "doc", "docx", "pages": return "doc.text"
    case "xls", "xlsx", "csv", "numbers": return "tablecells"
    default: return "doc"
    }
}

private let shortDate: DateFormatter = {
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .none
    return f
}()

/// One file or folder, styled like a row in the Links downloads list.
struct FileRow: View {
    var name: String
    var isDir: Bool
    var size: Double?
    var date: Date?
    var mime: String? = nil
    var selected: Bool
    var actionIcon: String
    var actionHelp: String
    var action: () -> Void
    @Local private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: fileIcon(name: name, isDir: isDir, mime: mime))
                .font(.ui(13, .medium))
                .foregroundStyle(isDir ? Theme.accent : Theme.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isDir ? Theme.accent.opacity(0.10) : Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1).truncationMode(.middle)
                Text(meta).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1)
            }
            Spacer(minLength: 6)
            if hover || selected {
                Button(action: action) { Image(systemName: actionIcon) }
                    .buttonStyle(IconButtonStyle(size: 28, filled: true)).help(actionHelp)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(selected ? 0.09 : (hover ? 0.045 : 0))))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
        .help(name)
    }

    private var meta: String {
        var parts: [String] = [isDir ? "Folder" : formatBytes(size)]
        if let date { parts.append(shortDate.string(from: date)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Finder-style clicking: click selects, ⌘-click toggles, ⇧-click selects a range.
@MainActor
private func clickSelect(_ id: String, order: [String], selection: inout Set<String>, anchor: inout String?) {
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        anchor = id
    } else if flags.contains(.shift), let a = anchor, let i = order.firstIndex(of: a), let j = order.firstIndex(of: id) {
        selection = Set(order[min(i, j)...max(i, j)])
    } else {
        selection = [id]
        anchor = id
    }
}

private var isDoubleClick: Bool { (NSApp.currentEvent?.clickCount ?? 1) >= 2 }

// MARK: - Panes

/// The rounded card each pane sits in: header, path, list, footer.
private struct PaneCard<Header: View, Content: View, Footer: View>: View {
    @ViewBuilder var header: Header
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.stroke).frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            footer
        }
        .card(Theme.card, radius: 16)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct PaneTitle: View {
    var icon: AnyView
    var title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.ui(11.5)).foregroundStyle(Theme.text3).lineLimit(1).truncationMode(.middle)
                }
            }
        }
    }
}

struct LocalPane: View {
    @ObservedObject var cloud: CloudModel
    @Local private var target = false
    @Local private var anchor: String?

    private var shown: [LocalEntry] {
        let q = cloud.filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? cloud.localEntries : cloud.localEntries.filter { $0.name.lowercased().contains(q) }
    }
    private var selected: [LocalEntry] { cloud.localEntries.filter { cloud.localSelection.contains($0.id) } }

    var body: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PaneTitle(icon: AnyView(Image(systemName: "laptopcomputer").font(.ui(14, .medium))
                                                .foregroundStyle(Theme.text2).frame(width: 32, height: 32)
                                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                    .fill(Color.white.opacity(0.06)))),
                              title: "This Mac", subtitle: freeSpace)
                    Spacer(minLength: 4)
                    Button { cloud.localFolder = cloud.localFolder.deletingLastPathComponent() } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(IconButtonStyle(size: 28)).help("Enclosing Folder")
                    .disabled(cloud.localFolder.path == "/")
                    Button { cloud.chooseLocalFolder() } label: { Image(systemName: "folder") }
                        .buttonStyle(IconButtonStyle(size: 28)).help("Choose Folder…")
                }
                CrumbBar(crumbs: localCrumbs) { cloud.localFolder = $0 }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        } content: {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { e in
                        FileRow(name: e.name, isDir: e.isDir, size: e.size, date: e.date,
                                selected: cloud.localSelection.contains(e.id),
                                actionIcon: "arrow.up", actionHelp: "Upload to the cloud folder on the right") {
                            cloud.upload(cloud.localSelection.contains(e.id) ? selected.map(\.url.path) : [e.url.path])
                        }
                        .onTapGesture { tap(e) }
                        .onDrag { dragProvider(e) }
                        .contextMenu { menu(e) }
                    }
                }
                .padding(8)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { cloud.localSelection = [] })
            .overlay {
                if shown.isEmpty {
                    EmptyPaneText(text: cloud.filter.isEmpty ? "This folder is empty.\nDrag cloud files here to download them."
                                                             : "Nothing matches “\(cloud.filter)”")
                }
            }
        } footer: {
            PaneFooter(text: selected.isEmpty ? "\(cloud.localEntries.count) items" : "\(selected.count) selected")
        }
        .overlay { if target { DropHighlight(text: "Download here") } }
        .onDrop(of: [.plainText], isTargeted: $target) { providers in
            for p in providers where p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s, let drag = CloudDrag.parse(s) else { return }
                    Task { @MainActor in cloud.download(drag.items, from: drag.location) }
                }
            }
            return true
        }
    }

    private func tap(_ e: LocalEntry) {
        if isDoubleClick {
            if e.isDir { cloud.localFolder = e.url } else { NSWorkspace.shared.open(e.url) }
            return
        }
        clickSelect(e.id, order: shown.map(\.id), selection: &cloud.localSelection, anchor: &anchor)
    }

    private func dragProvider(_ e: LocalEntry) -> NSItemProvider {
        if cloud.localSelection.contains(e.id) && cloud.localSelection.count > 1 {
            return NSItemProvider(object: LocalDrag.string(Array(cloud.localSelection)) as NSString)
        }
        return NSItemProvider(object: e.url as NSURL)
    }

    @ViewBuilder private func menu(_ e: LocalEntry) -> some View {
        let paths = cloud.localSelection.contains(e.id) ? selected.map(\.url.path) : [e.url.path]
        Button("Upload to the Cloud") { cloud.upload(paths) }.disabled(cloud.location == nil)
        Button("Open") { paths.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) } }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(paths.map { URL(fileURLWithPath: $0) }) }
    }

    private var freeSpace: String? {
        let v = try? cloud.localFolder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage.map { formatBytes(Double($0)) + " free" }
    }

    /// The local folder as clickable steps, starting at the home folder when inside it.
    private var localCrumbs: [(String, URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        var url = cloud.localFolder.standardizedFileURL
        var out: [(String, URL)] = []
        while true {
            if url.path == home { out.append(("Home", url)); break }
            if url.path == "/" { out.append(("Mac", url)); break }
            out.append((url.lastPathComponent, url))
            url = url.deletingLastPathComponent().standardizedFileURL
        }
        return out.reversed()
    }
}

struct RemotePane: View {
    @ObservedObject var cloud: CloudModel
    @Local private var target = false
    @Local private var anchor: String?
    @Local private var newFolder = false
    @Local private var folderName = ""
    @Local private var confirmDelete = false

    private var acct: CloudAccount? { cloud.account(cloud.location?.account) }
    private var shown: [CloudEntry] {
        let q = cloud.filter.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? cloud.visibleEntries : cloud.visibleEntries.filter { $0.name.lowercased().contains(q) }
    }
    private var selected: [CloudEntry] { cloud.visibleEntries.filter { cloud.selection.contains($0.id) } }
    private var canWrite: Bool { cloud.location?.view == "files" || cloud.location?.view == "link" }

    var body: some View {
        PaneCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    PaneTitle(icon: AnyView(ServiceIcon(type: acct?.type ?? "", size: 32)),
                              title: acct?.service ?? "Cloud", subtitle: acct?.email)
                    Spacer(minLength: 4)
                    Button { cloud.goUp() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(IconButtonStyle(size: 28)).help("Enclosing Folder")
                        .disabled(cloud.location?.path.isEmpty != false && cloud.location?.owner == nil)
                    Button { cloud.reload(force: true) } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(IconButtonStyle(size: 28)).help("Refresh")
                    if canWrite {
                        Button { folderName = ""; newFolder = true } label: { Image(systemName: "folder.badge.plus") }
                            .buttonStyle(IconButtonStyle(size: 28)).help("New Folder")
                    }
                }
                CrumbBar(crumbs: cloud.crumbs) { cloud.navigate($0) }
            }
            .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 8)
        } content: {
            content
        } footer: {
            PaneFooter(text: footerText)
        }
        .overlay { if target { DropHighlight(text: canWrite ? "Upload here" : "Open My Drive to upload") } }
        .onDrop(of: [.fileURL, .plainText], isTargeted: $target) { handleDrop($0) }
        .alert("New Folder", isPresented: $newFolder) {
            TextField("Name", text: $folderName)
            Button("Create") { cloud.newFolder(folderName.trimmingCharacters(in: .whitespaces)) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(selected.count == 1 ? "Delete “\(selected.first?.name ?? "")”?" : "Delete \(selected.count) items?",
                            isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { cloud.deleteSelected() }
        } message: {
            Text("They go to the \(acct?.service ?? "cloud") trash, where you can restore them for a while.")
        }
    }

    @ViewBuilder private var content: some View {
        if let people = cloud.people {
            PeopleList(people: people, cloud: cloud)
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(shown) { e in
                        FileRow(name: e.name, isDir: e.isDir, size: e.size, date: e.date, mime: e.mime,
                                selected: cloud.selection.contains(e.id),
                                actionIcon: "arrow.down", actionHelp: "Download to the folder on the left") {
                            if let loc = cloud.location {
                                cloud.download(cloud.selection.contains(e.id) ? selected : [e], from: loc)
                            }
                        }
                        .onTapGesture { tap(e) }
                        .onDrag {
                            guard let loc = cloud.location else { return NSItemProvider() }
                            let items = cloud.selection.contains(e.id) ? selected : [e]
                            return NSItemProvider(object: CloudDrag(location: loc, items: items).string as NSString)
                        }
                        .contextMenu { menu(e) }
                    }
                }
                .padding(8)
            }
            .background(Color.clear.contentShape(Rectangle()).onTapGesture { cloud.selection = [] })
            .overlay { overlay }
        }
    }

    private func tap(_ e: CloudEntry) {
        if isDoubleClick {
            if e.isDir { cloud.enter(e) } else if let loc = cloud.location { cloud.download([e], from: loc) }
            return
        }
        clickSelect(e.id, order: shown.map(\.id), selection: &cloud.selection, anchor: &anchor)
    }

    @ViewBuilder private func menu(_ e: CloudEntry) -> some View {
        let items = cloud.selection.contains(e.id) ? selected : [e]
        if let loc = cloud.location {
            if e.isDir && items.count == 1 { Button("Open") { cloud.enter(e) } }
            Button("Download to This Mac") { cloud.download(items, from: loc) }
            Button("Download to…") {
                let p = NSOpenPanel()
                p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
                p.prompt = "Download Here"
                if p.runModal() == .OK, let u = p.url { cloud.download(items, from: loc, to: u) }
            }
            if canWrite {
                Divider()
                Button("Delete…", role: .destructive) { cloud.selection = Set(items.map(\.id)); confirmDelete = true }
            }
        }
    }

    @ViewBuilder private var overlay: some View {
        if cloud.loading {
            ProgressView().controlSize(.small)
        } else if let err = cloud.listError {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.ui(20)).foregroundStyle(Theme.warn)
                Text(err).font(.ui(12.5)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                    .textSelection(.enabled)
                Button("Try Again") { cloud.reload(force: true) }.buttonStyle(QuietButtonStyle(height: 30))
            }
            .padding(30)
        } else if shown.isEmpty && cloud.location != nil {
            EmptyPaneText(text: !cloud.filter.isEmpty ? "Nothing matches “\(cloud.filter)”"
                          : (canWrite ? "This folder is empty.\nDrag files here to upload them." : "Nothing here yet."))
        }
    }

    private var footerText: String {
        if let people = cloud.people { return people.count == 1 ? "1 person" : "\(people.count) people" }
        if !selected.isEmpty {
            let size = selected.compactMap(\.size).reduce(0, +)
            return "\(selected.count) selected" + (size > 0 ? " · \(formatBytes(size))" : "")
        }
        return "\(cloud.visibleEntries.count) items"
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let loc = cloud.location else { return false }
        for p in providers {
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url, url.isFileURL else { return }
                    Task { @MainActor in cloud.upload([url.path], to: loc) }
                }
            } else if p.canLoadObject(ofClass: String.self) {
                _ = p.loadObject(ofClass: String.self) { s, _ in
                    guard let s, let paths = LocalDrag.parse(s) else { return }
                    Task { @MainActor in cloud.upload(paths, to: loc) }
                }
            }
        }
        return true
    }
}

/// Item count under a pane. Copying is done by dragging between the panes.
private struct PaneFooter: View {
    var text: String
    var body: some View {
        HStack {
            Text(text).font(.ui(11.5)).foregroundStyle(Theme.text3)
            Spacer()
            Text("Drag to copy").font(.ui(11.5)).foregroundStyle(Theme.text3.opacity(0.7))
        }
        .padding(.horizontal, 14).frame(height: 36)
    }
}

private struct EmptyPaneText: View {
    var text: String
    var body: some View {
        Text(text).font(.ui(12.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
            .padding(24).allowsHitTesting(false)
    }
}

/// Clickable path steps under a pane's title.
struct CrumbBar<Target>: View {
    var crumbs: [(String, Target)]
    var go: (Target) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(crumbs.enumerated()), id: \.offset) { i, c in
                        let last = i == crumbs.count - 1
                        if i > 0 { Image(systemName: "chevron.right").font(.ui(9, .bold)).foregroundStyle(Theme.text3) }
                        Button { go(c.1) } label: {
                            Text(c.0).font(.ui(12, last ? .semibold : .medium)).lineLimit(1)
                                .foregroundStyle(last ? Theme.text : Theme.text2)
                                .padding(.horizontal, 8).frame(height: 24)
                                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(Color.white.opacity(last ? 0.09 : 0.045)))
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
            }
            .onAppear { proxy.scrollTo(crumbs.count - 1, anchor: .trailing) }
            .onChange(of: crumbs.count) { _, n in proxy.scrollTo(n - 1, anchor: .trailing) }
        }
        .frame(height: 24)
    }
}

/// "Shared with me" at the top: one row per person sharing with you.
struct PeopleList: View {
    var people: [(owner: String, count: Int)]
    @ObservedObject var cloud: CloudModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(people, id: \.owner) { p in
                    PersonRow(owner: p.owner, count: p.count) { cloud.showPerson(p.owner) }
                }
            }
            .padding(8)
        }
    }
}

private struct PersonRow: View {
    var owner: String
    var count: Int
    var action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(String(owner.prefix(1)).uppercased())
                    .font(.ui(13, .bold)).foregroundStyle(.black)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(color))
                VStack(alignment: .leading, spacing: 3) {
                    Text(owner).font(.ui(13, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Text(count == 1 ? "1 item shared with you" : "\(count) items shared with you")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.ui(11, .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(hover ? 0.045 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.12), value: hover)
    }

    private var color: Color {
        let palette: [Color] = [Theme.accent, Color(red: 0.55, green: 0.8, blue: 1), Color(red: 1, green: 0.75, blue: 0.5),
                                Color(red: 0.85, green: 0.7, blue: 1), Color(red: 0.6, green: 0.95, blue: 0.8)]
        let h = owner.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return palette[h % palette.count]
    }
}

struct DropHighlight: View {
    var text: String

    var body: some View {
        ZStack {
            Theme.bg.opacity(0.7)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [10, 8]))
            VStack(spacing: 12) {
                DropArrow().fill(Theme.accent).frame(width: 22, height: 32)
                Text(text).font(.ui(16, .bold)).foregroundStyle(Theme.text)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
    }
}

// MARK: - Transfers

struct TransfersPanel: View {
    @ObservedObject var cloud: CloudModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Transfers").font(.ui(12.5, .semibold)).foregroundStyle(Theme.text3)
                    .textCase(.uppercase).tracking(0.6)
                Spacer()
                if cloud.transfers.contains(where: { $0.state == "done" || $0.state == "cancelled" }) {
                    Button("Clear finished") { cloud.clearFinished() }
                        .buttonStyle(.plain).font(.ui(12.5, .medium)).foregroundStyle(Theme.text2)
                }
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cloud.transfers.reversed()) { TransferRow(t: $0, cloud: cloud) }
                }
            }
            .frame(height: min(150, CGFloat(cloud.transfers.count) * 74))
        }
        .padding(.horizontal, 22).padding(.bottom, 18)
    }
}

struct TransferRow: View {
    var t: CloudTransfer
    @ObservedObject var cloud: CloudModel

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: t.direction == "down" ? "arrow.down" : "arrow.up")
                .font(.ui(13, .bold))
                .foregroundStyle(t.state == "done" ? Color.black : Theme.text2)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(t.state == "done" ? Theme.accent : Color.white.opacity(0.06)))
            VStack(alignment: .leading, spacing: 6) {
                Text(t.name).font(.ui(13.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                if t.state == "running" || t.state == "queued" {
                    ProgressBar(value: t.fraction ?? 0, indeterminate: t.state == "queued" || t.fraction == nil)
                }
                Text(detail).font(.ui(11.5)).foregroundStyle(t.state == "failed" ? Theme.warn : Theme.text2)
                    .lineLimit(2).textSelection(.enabled)
            }
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                if t.isActive {
                    Button { cloud.transferAction(t, "cancel") } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Stop")
                } else {
                    if t.direction == "down", t.state == "done", let f = t.local {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Show in Finder")
                    }
                    if t.state != "done" || t.error != nil {
                        Button { cloud.transferAction(t, "retry") } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(IconButtonStyle(size: 30)).help("Try Again (skips files already copied)")
                    }
                    Button { cloud.transferAction(t, "dismiss") } label: { Image(systemName: "xmark") }
                        .buttonStyle(IconButtonStyle(size: 30)).help("Remove from List")
                }
            }
        }
        .padding(12)
        .card(Theme.card, radius: 16)
    }

    private var detail: String {
        switch t.state {
        case "queued": return "Waiting for a free slot"
        case "cancelled": return "Stopped"
        case "failed": return t.error ?? "Couldn't copy"
        case "done":
            var s = t.direction == "down" ? "Downloaded" : "Uploaded"
            if t.bytes > 0 { s += " · " + formatBytes(t.bytes) }
            if let n = t.filesTotal, n > 1 { s += " · \(n) files" }
            if let e = t.error { s += " · " + e }
            return s
        default:
            var parts: [String] = []
            if let total = t.total, total > 0 {
                parts.append("\(formatBytes(t.bytes)) of \(formatBytes(total))")
            } else {
                parts.append(t.bytes > 0 ? formatBytes(t.bytes) : "Starting")
            }
            if let s = t.speed, s > 0 { parts.append("\(formatBytes(s))/s") }
            if let e = t.eta, e > 0 { parts.append("\(Time.format(e)) left") }
            if t.isDir, let n = t.filesTotal, n > 0 { parts.append("\(t.files) of \(n) files") }
            return parts.joined(separator: " · ")
        }
    }
}

// MARK: - Sheets and empty states

struct CloudWelcome: View {
    @ObservedObject var cloud: CloudModel

    var body: some View {
        VStack(spacing: 16) {
            LogoMark(size: 64)
            VStack(spacing: 7) {
                Text("Download whole folders from the cloud").font(.ui(18, .bold)).foregroundStyle(Theme.text)
                Text("Connect Google Drive or Dropbox to browse your files and everything\nshared with you, then drag folders to your Mac. They arrive file by file,\nnever as split zips.")
                    .font(.ui(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
            }
            ServiceButtons(cloud: cloud).frame(width: 320).padding(.top, 6)
        }
        .padding(40)
    }
}

struct ServiceButtons: View {
    @ObservedObject var cloud: CloudModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(cloud.status?.services ?? [], id: \.type) { s in
                ServiceButton(service: s) { cloud.connect(s.type) }
                    .disabled(cloud.auth != nil && cloud.auth?.state != "failed")
            }
            if let a = cloud.auth { AuthStatus(auth: a, cloud: cloud).padding(.top, 8) }
        }
    }
}

private struct ServiceButton: View {
    var service: CloudService
    var action: () -> Void
    @Local private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ServiceIcon(type: service.type, size: 26)
                Text(service.name).font(.ui(13, .semibold)).foregroundStyle(Theme.text)
                Spacer()
                Image(systemName: "arrow.up.right").font(.ui(11, .semibold)).foregroundStyle(Theme.text3)
            }
            .padding(.horizontal, 10).frame(height: M.controlLarge)
            .controlFill(hover: hover)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

struct AuthStatus: View {
    var auth: CloudAuth
    @ObservedObject var cloud: CloudModel

    var body: some View {
        VStack(spacing: 10) {
            if auth.state == "failed" {
                Label(auth.error ?? "Sign-in didn't finish.", systemImage: "exclamationmark.triangle")
                    .font(.ui(12.5)).foregroundStyle(Theme.warn).multilineTextAlignment(.center)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").font(.ui(12.5)).foregroundStyle(Theme.text2)
                }
                if auth.type == "drive" {
                    Text("If Google says it hasn't verified Dwn, choose Advanced, then Go to Dwn.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).multilineTextAlignment(.center)
                }
                HStack(spacing: 8) {
                    if let u = auth.url, let url = URL(string: u) {
                        Button("Open sign-in page again") { NSWorkspace.shared.open(url) }
                            .buttonStyle(QuietButtonStyle(height: 30))
                    }
                    Button("Cancel") { cloud.cancelConnect() }.buttonStyle(QuietButtonStyle(height: 30))
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

struct ConnectSheet: View {
    @ObservedObject var cloud: CloudModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Add an account").font(.ui(17, .bold)).foregroundStyle(Theme.text)
                Spacer()
                Button { cloud.cancelConnect(); cloud.showConnect = false } label: { Image(systemName: "xmark") }
                    .buttonStyle(IconButtonStyle(size: 28))
            }
            Text("Your browser opens to sign in. Dwn keeps the sign-in on this Mac only.")
                .font(.ui(12.5)).foregroundStyle(Theme.text2)
            ServiceButtons(cloud: cloud)
            // Release builds carry Dwn's own Google app, so people never see
            // this. It's for builds without one, or to override it.
            if cloud.clients["drive"].map({ $0.id == nil || $0.mine }) ?? false {
                GoogleAppSection(cloud: cloud)
            }
        }
        .padding(22)
        .frame(width: 440)
        .background(Theme.sidebar)
    }
}

/// Dwn's own Google sign-in app (client ID), so Drive isn't slowed by the
/// rate limit on rclone's shared one.
struct GoogleAppSection: View {
    @ObservedObject var cloud: CloudModel
    @Local private var open = false
    @Local private var id = ""
    @Local private var secret = ""
    @Local private var message: String?
    @Local private var saving = false

    private var current: CloudClient? { cloud.clients["drive"] }
    private var drivesOnShared: [CloudAccount] { cloud.accounts.filter { $0.type == "drive" && $0.ownClient != true } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "key").font(.ui(M.icon, .medium)).foregroundStyle(Theme.text3).frame(width: M.iconColumn)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Use your own Google app").font(.ui(13, .medium)).foregroundStyle(Theme.text)
                        Text(current?.mine == true ? "On" : "Advanced, optional")
                            .font(.ui(11.5)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Image(systemName: "chevron.down").font(.ui(10, .semibold)).foregroundStyle(Theme.text3)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text("Create a Desktop app client in Google Cloud Console (enable the Google Drive API first), then paste its ID and secret here. Accounts you add afterwards use it.")
                    .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                Link("How to make one", destination: URL(string: "https://rclone.org/drive/#making-your-own-client-id")!)
                    .font(.ui(11.5, .medium)).foregroundStyle(Theme.accent)
                field("Client ID", text: $id, secure: false)
                field("Client secret", text: $secret, secure: true)
                if let message { Text(message).font(.ui(11.5)).foregroundStyle(Theme.warn) }
                HStack(spacing: 8) {
                    if current?.mine == true {
                        Button("Use rclone's app") { save(id: "", secret: "") }.buttonStyle(QuietButtonStyle(height: 30))
                    }
                    Spacer()
                    Button(saving ? "Saving…" : "Save") { save(id: id, secret: secret) }
                        .buttonStyle(PrimaryButtonStyle(height: 30)).frame(width: 80)
                        .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
                if current?.id != nil, !drivesOnShared.isEmpty {
                    Text("To move an account you already added onto this app, choose Sign In Again from its ••• menu.")
                        .font(.ui(11.5)).foregroundStyle(Theme.text3).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .card(Theme.card, radius: 14)
        .onAppear { id = current?.mine == true ? (current?.id ?? "") : ""; }
    }

    private func field(_ title: String, text: Binding<String>, secure: Bool) -> some View {
        Group {
            if secure {
                SecureField("", text: text, prompt: Text(title).foregroundStyle(Theme.text3))
            } else {
                TextField("", text: text, prompt: Text(title).foregroundStyle(Theme.text3))
            }
        }
        .textFieldStyle(.plain).font(.ui(12.5)).foregroundStyle(Theme.text)
        .padding(.horizontal, 10).frame(height: 32).controlFill()
    }

    private func save(id: String, secret: String) {
        saving = true
        Task {
            message = await cloud.saveClient("drive", id: id, secret: secret)
            saving = false
            if message == nil && id.isEmpty { self.id = ""; self.secret = "" }
        }
    }
}

struct LinkSheet: View {
    @ObservedObject var cloud: CloudModel
    @Local private var link = ""
    @Local private var account = ""

    private var drives: [CloudAccount] { cloud.accounts.filter { $0.type == "drive" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Open a shared Google Drive folder").font(.ui(17, .bold)).foregroundStyle(Theme.text)
            Text("Paste a folder link someone sent you. You can browse it and download all of it, without it being split into zips.")
                .font(.ui(12.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: "link").font(.ui(M.icon, .medium)).foregroundStyle(Theme.text3)
                TextField("", text: $link, prompt: Text("https://drive.google.com/drive/folders/…").foregroundStyle(Theme.text3))
                    .textFieldStyle(.plain).font(.ui(13)).foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 12).frame(height: M.controlLarge).controlFill()
            if drives.count > 1 {
                DwnDropdown(options: drives.map { ($0.name, $0.email ?? $0.label, nil) }, selection: $account,
                            icon: "person.crop.circle")
            }
            HStack {
                Spacer()
                Button("Cancel") { cloud.showLink = false }.buttonStyle(QuietButtonStyle(height: 34))
                Button("Open") {
                    cloud.addLink(link, account: account.isEmpty ? (drives.first?.name ?? "") : account)
                    cloud.showLink = false
                }
                .buttonStyle(PrimaryButtonStyle(height: 34)).frame(width: 96)
                .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || drives.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(Theme.sidebar)
        .onAppear {
            account = drives.first?.name ?? ""
            if let s = NSPasteboard.general.string(forType: .string), s.contains("drive.google.com") { link = s }
        }
    }
}

struct RcloneMissing: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "cloud.bolt").font(.system(size: 36, weight: .light)).foregroundStyle(Theme.warn)
            Text("Cloud drives aren't available").font(.ui(18, .bold)).foregroundStyle(Theme.text)
            Text("This copy of Dwn doesn't include rclone, which it uses to talk to Google Drive and Dropbox.\nInstall it with Homebrew (brew install rclone), then restart Dwn.")
                .font(.ui(14)).foregroundStyle(Theme.text2).multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
        .padding(40)
    }
}
