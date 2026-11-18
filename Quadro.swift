// Quadro.swift — macOS 多窗格文件管理器
// 品牌配色: 暗夜黑曜石 + 电光钛蓝 + 极光青(对标 Raycast / Linear 的暗色生产力美学)
// 支持 1/2/3/4 窗格布局、焦点高亮、跨窗格复制/移动、拖拽、后退/前进导航。
//
// 构建: bash build.sh(需 Xcode 命令行工具)
// 打包 DMG: bash make-dmg.sh

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 品牌配色

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0
        )
    }
}

enum QuadroTheme {
    static let background = Color(hex: 0x0B0D10)    // 暗夜黑曜石
    static let panel = Color(hex: 0x1C2028)         // 钛金深灰
    static let border = Color(hex: 0x2E3646)        // 结构分隔线
    static let accent = Color(hex: 0x0A84FF)        // 电光钛蓝
    static let cyan = Color(hex: 0x00F2FE)          // 极光青
    static let textPrimary = Color(hex: 0xF2F5F8)   // 冷银白
    static let textSecondary = Color(hex: 0x4E5D78) // 雾面灰蓝
}

// MARK: - 文件条目模型

struct FileEntry: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modified: Date?

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

// MARK: - 布局模式

enum LayoutMode: Int, CaseIterable, Identifiable {
    case single = 1
    case dual = 2
    case triple = 3
    case quad = 4

    var id: Int { rawValue }
    var title: String { "\(rawValue)窗" }
}

// MARK: - 焦点方向

enum FocusDirection {
    case up, down, left, right
}

// MARK: - 错误处理辅助

func isPermissionError(_ error: Error) -> Bool {
    let ns = error as NSError
    if ns.domain == NSCocoaErrorDomain && (ns.code == 257 || ns.code == 513) {
        return true
    }
    let desc = error.localizedDescription.lowercased()
    return desc.contains("permission") || desc.contains("权限")
}

func friendlyErrorMessage(_ error: Error) -> String {
    if isPermissionError(error) {
        return "没有权限访问此目录。请点右侧「打开系统设置」,在 完全磁盘访问权限 中添加 Quadro 并勾选;或下次访问该目录时在弹窗中点「允许」。"
    }
    return error.localizedDescription
}

// MARK: - 单个窗格状态

final class PaneState: ObservableObject, Identifiable {
    let id = UUID()
    let index: Int

    @Published var currentURL: URL
    @Published var entries: [FileEntry] = []
    @Published var selection = Set<UUID>()
    @Published var errorMessage: String?
    @Published var isPermissionDenied = false
    @Published var backStack: [URL] = []
    @Published var forwardStack: [URL] = []

    var selectionAnchor: UUID?  // ⇧ 范围选择锚点

    var label: String { "窗口 \(index + 1)" }

    private let fm = FileManager.default

    init(index: Int, root: URL) {
        self.index = index
        self.currentURL = root
        load()
    }

    func setError(_ error: Error) {
        errorMessage = friendlyErrorMessage(error)
        isPermissionDenied = isPermissionError(error)
    }

    func load(preserveSelection: Bool = false) {
        let previous = preserveSelection ? selectedEntries().map(\.url) : []
        do {
            let urls = try fm.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            var list: [FileEntry] = []
            for url in urls {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                let isDir = values?.isDirectory ?? false
                list.append(FileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    isDirectory: isDir,
                    size: values?.fileSize.map(Int64.init),
                    modified: values?.contentModificationDate
                ))
            }
            list.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            entries = list
            errorMessage = nil
            isPermissionDenied = false
            if preserveSelection {
                selection = Set(list.filter { previous.contains($0.url) }.map(\.id))
            } else {
                selection = []
            }
        } catch {
            entries = []
            selection = []
            setError(error)
        }
    }

    func navigate(to path: String) {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir) {
            if !isDir.boolValue {
                url = url.deletingLastPathComponent()
            }
            setDirectory(url, record: true)
        } else {
            errorMessage = "路径不存在: \(trimmed)"
            isPermissionDenied = false
        }
    }

    func goUp() {
        let parent = currentURL.deletingLastPathComponent()
        guard parent.path != currentURL.path else { return }
        setDirectory(parent, record: true)
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(currentURL)
        setDirectory(prev, record: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(currentURL)
        setDirectory(next, record: false)
    }

    private func setDirectory(_ url: URL, record: Bool) {
        if record {
            backStack.append(currentURL)
            forwardStack.removeAll()
        }
        currentURL = url.standardizedFileURL
        load()
    }

    func open(_ entry: FileEntry) {
        if entry.isDirectory {
            setDirectory(entry.url, record: true)
        } else {
            NSWorkspace.shared.open(entry.url)
        }
    }

    func refresh() { load() }

    func createFolder(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let url = currentURL.appendingPathComponent(trimmed)
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            load()
        } catch {
            setError(error)
        }
    }

    func rename(_ entry: FileEntry, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != entry.name else { return }
        let newURL = entry.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try fm.moveItem(at: entry.url, to: newURL)
            load()
        } catch {
            setError(error)
        }
    }

    func delete(_ entry: FileEntry) {
        do {
            try fm.trashItem(at: entry.url, resultingItemURL: nil)
            load()
        } catch {
            setError(error)
        }
    }

    func copy(_ entry: FileEntry, to dest: PaneState) {
        let destURL = dest.currentURL.appendingPathComponent(entry.name)
        do {
            try fm.copyItem(at: entry.url, to: destURL)
            dest.load()
        } catch {
            setError(error)
        }
    }

    func move(_ entry: FileEntry, to dest: PaneState) {
        let destURL = dest.currentURL.appendingPathComponent(entry.name)
        do {
            try fm.moveItem(at: entry.url, to: destURL)
            load()
            dest.load()
        } catch {
            setError(error)
        }
    }

    func receiveDrop(urls: [URL], move: Bool) {
        for u in urls {
            let destURL = currentURL.appendingPathComponent(u.lastPathComponent)
            do {
                if move {
                    try fm.moveItem(at: u, to: destURL)
                } else {
                    try fm.copyItem(at: u, to: destURL)
                }
            } catch {
                setError(error)
            }
        }
        load()
    }

    func selectedEntries() -> [FileEntry] {
        entries.filter { selection.contains($0.id) }
    }
}

// MARK: - 全局模型

final class AppModel: ObservableObject {
    @Published var layout: LayoutMode = .quad
    @Published var activePaneID: UUID?
    @Published var panes: [PaneState] = []
    @Published var isClipboardCut = false
    @Published var statusMessage: String?

    private var cutSourceURLs: [URL] = []
    private var refreshTimer: Timer?
    private let fm = FileManager.default

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        panes = (0..<4).map { PaneState(index: $0, root: home) }
        activePaneID = panes.first?.id

        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.autoRefresh()
        }
        timer.tolerance = 1.0
        refreshTimer = timer
    }

    var activePanes: [PaneState] {
        Array(panes.prefix(layout.rawValue))
    }

    func isActive(_ pane: PaneState) -> Bool { activePaneID == pane.id }

    func activate(_ pane: PaneState) {
        guard activePaneID != pane.id else { return }
        activePaneID = pane.id
    }

    func activatePane(index: Int) {
        guard index >= 0, index < panes.count else { return }
        activate(panes[index])
    }

    /// 定时刷新所有可见窗格的目录
    func autoRefresh() {
        for pane in activePanes {
            pane.load(preserveSelection: true)
        }
    }

    /// 重新打开应用时回到默认状态(默认目录 + 四窗格)
    func resetToDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        panes = (0..<4).map { PaneState(index: $0, root: home) }
        layout = .quad
        activePaneID = panes.first?.id
    }

    func activePane() -> PaneState? {
        panes.first { $0.id == activePaneID } ?? activePanes.first
    }

    /// Tab 循环顺序(四窗格为 Q1→Q2→Q4→Q3)
    var focusOrder: [PaneState] {
        switch layout {
        case .single: return [panes[0]]
        case .dual: return [panes[0], panes[1]]
        case .triple: return [panes[0], panes[1], panes[2]]
        case .quad: return [panes[0], panes[1], panes[3], panes[2]]
        }
    }

    func cycleFocus(forward: Bool) {
        let order = focusOrder
        guard !order.isEmpty else { return }
        guard let cur = activePane(),
              let idx = order.firstIndex(where: { $0.id == cur.id }) else {
            if let first = order.first { activate(first) }
            return
        }
        let n = order.count
        let next = forward ? (idx + 1) % n : (idx - 1 + n) % n
        activate(order[next])
    }

    func moveFocus(direction: FocusDirection) {
        guard let cur = activePane() else { return }
        guard let ci = panes.firstIndex(where: { $0.id == cur.id }) else { return }
        var target: Int?
        switch layout {
        case .single:
            target = ci
        case .dual:
            switch direction {
            case .left: target = ci == 1 ? 0 : ci
            case .right: target = ci == 0 ? 1 : ci
            default: target = ci
            }
        case .triple:
            switch direction {
            case .left: target = (ci == 1 || ci == 2) ? 0 : ci
            case .right: target = ci == 0 ? 1 : ci
            case .up: target = ci == 2 ? 1 : ci
            case .down: target = ci == 1 ? 2 : ci
            }
        case .quad:
            switch direction {
            case .left: target = ci == 1 ? 0 : (ci == 3 ? 2 : ci)
            case .right: target = ci == 0 ? 1 : (ci == 2 ? 3 : ci)
            case .up: target = ci == 2 ? 0 : (ci == 3 ? 1 : ci)
            case .down: target = ci == 0 ? 2 : (ci == 1 ? 3 : ci)
            }
        }
        if let t = target { activate(panes[t]) }
    }

    func nextPane(after pane: PaneState) -> PaneState? {
        let order = focusOrder
        guard let idx = order.firstIndex(where: { $0.id == pane.id }) else { return nil }
        return order[(idx + 1) % order.count]
    }

    func otherPanes(than pane: PaneState) -> [PaneState] {
        activePanes.filter { $0.id != pane.id }
    }

    func copySelectionToNext(move: Bool) {
        guard let src = activePane(),
              let dest = nextPane(after: src),
              src.id != dest.id else { return }
        let entries = src.selectedEntries()
        guard !entries.isEmpty else { return }
        for entry in entries {
            if move {
                src.move(entry, to: dest)
            } else {
                src.copy(entry, to: dest)
            }
        }
    }

    // MARK: 剪贴板(复制/剪切/粘贴/删除,支持文件和文件夹,可跨窗格)

    func registerClipboard(cut: Bool, urls: [URL]) {
        isClipboardCut = cut
        cutSourceURLs = cut ? urls : []
    }

    func writeClipboard(urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        registerClipboard(cut: cut, urls: urls)
        statusMessage = cut ? "已剪切 \(urls.count) 项(到目标窗格 ⌘V 粘贴)" : "已复制 \(urls.count) 项"
        clearStatusLater()
    }

    func pasteFromPasteboard(into pane: PaneState) {
        paste(into: pane, urls: pasteboardFileURLs())
    }

    func pasteboardFileURLs() -> [URL] {
        let pb = NSPasteboard.general
        guard let objs = pb.readObjects(forClasses: [NSURL.self],
                                        options: [.urlReadingFileURLsOnly: true]) else { return [] }
        return objs.compactMap { obj -> URL? in
            if let u = obj as? URL { return u }
            if let nsu = obj as? NSURL { return nsu as URL }
            return nil
        }
    }

    func deleteSelection(in pane: PaneState) {
        let entries = pane.selectedEntries()
        guard !entries.isEmpty else { return }
        for entry in entries {
            pane.delete(entry)
        }
        statusMessage = "已删除 \(entries.count) 项"
        clearStatusLater()
    }

    func paste(into pane: PaneState, urls: [URL]) {
        guard !urls.isEmpty else { return }
        // 仅当粘贴内容与最近一次“剪切”的内容一致时才按移动处理
        let move = isClipboardCut
            && Set(urls.map { $0.standardizedFileURL }) == Set(cutSourceURLs.map { $0.standardizedFileURL })
        isClipboardCut = false
        cutSourceURLs = []

        let destDir = pane.currentURL
        var count = 0
        for url in urls {
            let sameDir = url.deletingLastPathComponent().standardizedFileURL == destDir.standardizedFileURL
            if move && sameDir { continue } // 同目录移动 = 无操作
            let base = destDir.appendingPathComponent(url.lastPathComponent)
            let dest = uniqueDestination(base)
            do {
                if move {
                    try fm.moveItem(at: url, to: dest)
                } else {
                    try fm.copyItem(at: url, to: dest)
                }
                count += 1
            } catch {
                pane.setError(error)
            }
        }
        pane.load()
        if move {
            for p in panes where p.id != pane.id { p.load() }
        }

        if count == 0 && move {
            statusMessage = "文件已在同一目录,未移动"
        } else if count > 0 {
            statusMessage = (move ? "已移动 \(count) 项到 \(destDir.lastPathComponent)"
                                  : "已复制 \(count) 项到 \(destDir.lastPathComponent)")
        }
        clearStatusLater()
    }

    private func uniqueDestination(_ base: URL) -> URL {
        guard fm.fileExists(atPath: base.path) else { return base }
        let dir = base.deletingLastPathComponent()
        let ext = base.pathExtension
        let stem = base.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            let name = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            let candidate = dir.appendingPathComponent(name)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    private func clearStatusLater() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.statusMessage = nil
        }
    }
}

// MARK: - 应用入口

@main
struct QuadroApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("Quadro") {
            ContentView()
                .environmentObject(model)
        }
        .windowToolbarStyle(.unified)
        .commands {
            QuadroCommands(model: model)
        }
    }
}

// MARK: - 菜单与快捷键

struct QuadroCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu("布局") {
            Button("单窗格") { model.layout = .single }
                .keyboardShortcut("1", modifiers: .command)
            Button("双窗格") { model.layout = .dual }
                .keyboardShortcut("2", modifiers: .command)
            Button("三窗格") { model.layout = .triple }
                .keyboardShortcut("3", modifiers: .command)
            Button("四窗格") { model.layout = .quad }
                .keyboardShortcut("4", modifiers: .command)
        }

        CommandMenu("窗格") {
            Button("聚焦下一个窗格") { model.cycleFocus(forward: true) }
                .keyboardShortcut(.tab, modifiers: [])
            Button("聚焦上一个窗格") { model.cycleFocus(forward: false) }
                .keyboardShortcut(.tab, modifiers: .shift)
            Divider()
            Button("聚焦 窗口 1") { model.activatePane(index: 0) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("聚焦 窗口 2") { model.activatePane(index: 1) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("聚焦 窗口 3") { model.activatePane(index: 2) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("聚焦 窗口 4") { model.activatePane(index: 3) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Divider()
            Button("焦点上移") { model.moveFocus(direction: .up) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("焦点下移") { model.moveFocus(direction: .down) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button("焦点左移") { model.moveFocus(direction: .left) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("焦点右移") { model.moveFocus(direction: .right) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }

        CommandMenu("文件") {
            Button("复制到下一个窗格") { model.copySelectionToNext(move: false) }
                .keyboardShortcut(fKey(Int(NSF5FunctionKey)), modifiers: [])
            Button("移动到下一个窗格") { model.copySelectionToNext(move: true) }
                .keyboardShortcut(fKey(Int(NSF6FunctionKey)), modifiers: [])
            Divider()
            Button("移到废纸篓") {
                if let p = model.activePane() { model.deleteSelection(in: p) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    private func fKey(_ code: Int) -> KeyEquivalent {
        KeyEquivalent(Character(UnicodeScalar(code)!))
    }
}

// MARK: - 主视图

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            layout
            Rectangle().fill(QuadroTheme.border).frame(height: 1)
            StatusBar(pane: model.activePane() ?? model.panes[0])
        }
        .background(QuadroTheme.background.ignoresSafeArea())
        .frame(minWidth: 960, minHeight: 600)
        .preferredColorScheme(.dark)
        .onAppear {
            // 每次打开窗口都回到默认状态(不保存上次退出时的目录)
            DispatchQueue.main.async { model.resetToDefaults() }
        }
        .toolbar {
            ToolbarItemGroup {
                Picker("布局", selection: $model.layout) {
                    ForEach(LayoutMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("切换 1/2/3/4 窗格布局(⌘1~⌘4)")
            }
        }
    }

    @ViewBuilder
    private var layout: some View {
        switch model.layout {
        case .single:
            PaneView(pane: model.panes[0])
        case .dual:
            HSplitView {
                PaneView(pane: model.panes[0])
                PaneView(pane: model.panes[1])
            }
        case .triple:
            HSplitView {
                PaneView(pane: model.panes[0])
                VSplitView {
                    PaneView(pane: model.panes[1])
                    PaneView(pane: model.panes[2])
                }
            }
        case .quad:
            HSplitView {
                VSplitView {
                    PaneView(pane: model.panes[0])
                    PaneView(pane: model.panes[2])
                }
                VSplitView {
                    PaneView(pane: model.panes[1])
                    PaneView(pane: model.panes[3])
                }
            }
        }
    }
}

// MARK: - 底部状态栏

struct StatusBar: View {
    @ObservedObject var pane: PaneState
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            if let msg = model.statusMessage {
                Image(systemName: "checkmark.circle")
                    .foregroundColor(QuadroTheme.cyan)
                Text(msg)
                    .foregroundColor(QuadroTheme.cyan)
            } else {
                Text("激活: \(pane.label)")
                    .foregroundColor(QuadroTheme.cyan)
                Text("选中 \(pane.selection.count) 项")
                    .foregroundColor(QuadroTheme.textSecondary)
            }
            Spacer()
            Text(pane.currentURL.path)
                .foregroundColor(QuadroTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(QuadroTheme.panel)
    }
}

// MARK: - 单个窗格视图

struct PaneView: View {
    @ObservedObject var pane: PaneState
    @EnvironmentObject var model: AppModel

    @State private var pathText = ""
    @State private var showNewFolder = false
    @State private var renameTarget: FileEntry?
    @State private var isDropTarget = false

    private var isActive: Bool { model.isActive(pane) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(QuadroTheme.border).frame(height: 1)
            fileList
            if let err = pane.errorMessage {
                errorBar(err)
            }
        }
        .background(QuadroTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isActive ? QuadroTheme.accent : QuadroTheme.border,
                        lineWidth: isActive ? 1.5 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .fill(isDropTarget ? QuadroTheme.accent.opacity(0.15) : Color.clear)
        )
        .shadow(color: isActive ? QuadroTheme.accent.opacity(0.35) : .clear,
                radius: isActive ? 7 : 0)
        .padding(5)
        .frame(minWidth: 260, minHeight: 160)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { model.activate(pane) })
        .focusable()
        .onPasteCommand(of: [.fileURL, .url]) { providers in
            pasteProviders(providers, into: pane)
        }
        .contextMenu { paneContextMenu }
        .onAppear { pathText = pane.currentURL.path }
        .onChange(of: pane.currentURL) { newURL in
            pathText = newURL.path
        }
        .onChange(of: model.activePaneID) { newID in
            // 切换到本窗格时刷新目录(此时选中已生效,刷新会按 URL 保留选中)
            if newID == pane.id {
                pane.load(preserveSelection: true)
            }
        }
        .sheet(isPresented: $showNewFolder) {
            NewFolderSheet(pane: pane)
        }
        .sheet(item: $renameTarget) { entry in
            RenameSheet(pane: pane, entry: entry)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(isActive ? QuadroTheme.accent : QuadroTheme.border)
                .frame(height: 3)
            HStack(spacing: 6) {
                Text(pane.label)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(isActive ? QuadroTheme.cyan : QuadroTheme.textSecondary)

                Button(action: pane.goBack) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                .foregroundColor(QuadroTheme.textSecondary)
                .disabled(pane.backStack.isEmpty)
                .help("后退")

                Button(action: pane.goForward) {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
                .foregroundColor(QuadroTheme.textSecondary)
                .disabled(pane.forwardStack.isEmpty)
                .help("前进")

                Button(action: pane.goUp) {
                    Image(systemName: "arrow.up")
                }
                .buttonStyle(.borderless)
                .foregroundColor(QuadroTheme.textSecondary)
                .help("上一级")

                TextField("路径", text: $pathText)
                    .textFieldStyle(.plain)
                    .foregroundColor(QuadroTheme.textPrimary)
                    .padding(.vertical, 3)
                    .padding(.horizontal, 7)
                    .background(QuadroTheme.background.opacity(0.7))
                    .cornerRadius(5)
                    .onSubmit { pane.navigate(to: pathText) }

                Button(action: pane.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .foregroundColor(QuadroTheme.textSecondary)
                .help("刷新")

                Button(action: { showNewFolder = true }) {
                    Image(systemName: "folder.badge.plus")
                }
                .buttonStyle(.borderless)
                .foregroundColor(QuadroTheme.textSecondary)
                .help("新建文件夹")
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .background(QuadroTheme.panel)
        }
    }

    private var paneContextMenu: some View {
        Group {
            Button("粘贴") { model.pasteFromPasteboard(into: pane) }
            Button("新建文件夹") { showNewFolder = true }
            Button("刷新") { pane.refresh() }
        }
    }

    private var fileList: some View {
        List {
            ForEach(pane.entries) { entry in
                let selected = pane.selection.contains(entry.id)
                FileRow(entry: entry, selected: selected)
                    .listRowBackground(selected ? QuadroTheme.accent.opacity(0.24) : QuadroTheme.panel)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { select(entry) })
                    .simultaneousGesture(TapGesture(count: 2).onEnded { pane.open(entry) })
                    .contextMenu { contextMenu(for: entry) }
                    .onDrag { NSItemProvider(contentsOf: entry.url) ?? NSItemProvider() }
            }
        }
        .listStyle(.inset)
        .onDrop(of: [.fileURL, .url], delegate: PaneDropDelegate(pane: pane, onHover: { hovering in
            isDropTarget = hovering
        }))
        .onCopyCommand {
            let urls = pane.selectedEntries().map(\.url)
            model.registerClipboard(cut: false, urls: urls)
            return urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
        }
        .onCutCommand {
            let urls = pane.selectedEntries().map(\.url)
            model.registerClipboard(cut: true, urls: urls)
            return urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() }
        }
        .onPasteCommand(of: [.fileURL, .url]) { providers in
            pasteProviders(providers, into: pane)
        }
    }

    private func pasteProviders(_ providers: [NSItemProvider], into pane: PaneState) {
        let queue = DispatchQueue(label: "quadro.paste")
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = itemURL(from: item) {
                    queue.sync { urls.append(url) }
                    group.leave()
                } else {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item2, _ in
                        if let url = itemURL(from: item2) {
                            queue.sync { urls.append(url) }
                        }
                        group.leave()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            model.paste(into: pane, urls: urls)
        }
    }

    private func select(_ entry: FileEntry) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) {
            // ⌘ 点击:切换选中
            if pane.selection.contains(entry.id) {
                pane.selection.remove(entry.id)
            } else {
                pane.selection.insert(entry.id)
            }
            pane.selectionAnchor = entry.id
        } else if flags.contains(.shift),
                  let anchor = pane.selectionAnchor,
                  let anchorIdx = pane.entries.firstIndex(where: { $0.id == anchor }),
                  let idx = pane.entries.firstIndex(where: { $0.id == entry.id }) {
            // ⇧ 点击:范围选中
            let lo = min(anchorIdx, idx)
            let hi = max(anchorIdx, idx)
            pane.selection = Set(pane.entries[lo...hi].map(\.id))
        } else {
            // 普通左键:单选
            pane.selection = [entry.id]
            pane.selectionAnchor = entry.id
        }
        // 激活该窗格(切换到其他窗格时会刷新目录)
        model.activate(pane)
    }

    private func contextMenu(for entry: FileEntry) -> some View {
        // 若右键的条目在选中集合里,则对整个选区操作,否则仅对该条目操作
        let targets: [FileEntry] = pane.selection.contains(entry.id) ? pane.selectedEntries() : [entry]
        let urls = targets.map(\.url)
        return Group {
            Button("打开") { pane.open(entry) }
            Divider()
            Button("复制") { model.writeClipboard(urls: urls, cut: false) }
            Button("剪切") { model.writeClipboard(urls: urls, cut: true) }
            Button("粘贴") { model.pasteFromPasteboard(into: pane) }
            Divider()
            Button("删除(移到废纸篓)") {
                if pane.selection.contains(entry.id) {
                    model.deleteSelection(in: pane)
                } else {
                    pane.delete(entry)
                }
            }
            Divider()
            Button("重命名") { renameTarget = entry }
        }
    }

    private func errorBar(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
            Text(message)
                .lineLimit(3)
            Spacer()
            if pane.isPermissionDenied {
                Button("打开系统设置") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.borderless)
            }
            Button("关闭") { pane.errorMessage = nil }
                .buttonStyle(.borderless)
        }
        .font(.caption)
        .foregroundColor(Color(hex: 0xFF6B6B))
        .padding(6)
        .background(Color(hex: 0xFF6B6B).opacity(0.12))
    }
}

// MARK: - 文件行

struct FileRow: View {
    let entry: FileEntry
    let selected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(nsImage: entry.icon)
                .resizable()
                .frame(width: 16, height: 16)
            Text(entry.name)
                .foregroundColor(selected ? Color.white : QuadroTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if !entry.isDirectory {
                Text(Self.sizeString(entry.size))
                    .font(.caption)
                    .foregroundColor(QuadroTheme.textSecondary)
            }
        }
        .padding(.vertical, 1)
    }

    private static func sizeString(_ bytes: Int64?) -> String {
        guard let b = bytes else { return "" }
        return ByteCountFormatter.string(fromByteCount: b, countStyle: .file)
    }
}

// MARK: - 工具:从拖拽/粘贴的 item 提取 URL

func itemURL(from item: NSSecureCoding?) -> URL? {
    if let url = item as? URL { return url }
    if let nsurl = item as? NSURL { return nsurl as URL }
    if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
    if let str = item as? String { return URL(string: str) }
    return nil
}

// MARK: - 拖拽接收(拖到本窗格 = 复制,按住 ⌘ 或 ⌥ = 移动)

struct PaneDropDelegate: DropDelegate {
    let pane: PaneState
    var onHover: ((Bool) -> Void)?

    func dropEntered(info: DropInfo) { onHover?(true) }
    func dropExited(info: DropInfo) { onHover?(false) }

    func performDrop(info: DropInfo) -> Bool {
        onHover?(false)
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        let move = flags.contains(.option) || flags.contains(.command)
        let providers = info.itemProviders(for: [.fileURL, .url])
        guard !providers.isEmpty else { return false }

        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = itemURL(from: item) {
                    DispatchQueue.main.async {
                        pane.receiveDrop(urls: [url], move: move)
                    }
                } else {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item2, _ in
                        if let url = itemURL(from: item2) {
                            DispatchQueue.main.async {
                                pane.receiveDrop(urls: [url], move: move)
                            }
                        }
                    }
                }
            }
        }
        return true
    }
}

// MARK: - 新建文件夹弹窗

struct NewFolderSheet: View {
    let pane: PaneState
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新建文件夹")
                .font(.headline)
                .foregroundColor(QuadroTheme.textPrimary)
            Text("位置: \(pane.currentURL.path)")
                .font(.caption)
                .foregroundColor(QuadroTheme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("文件夹名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("创建") {
                    pane.createFolder(named: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(QuadroTheme.panel)
        .preferredColorScheme(.dark)
    }
}

// MARK: - 重命名弹窗

struct RenameSheet: View {
    let pane: PaneState
    let entry: FileEntry
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(pane: PaneState, entry: FileEntry) {
        self.pane = pane
        self.entry = entry
        _name = State(initialValue: entry.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("重命名")
                .font(.headline)
                .foregroundColor(QuadroTheme.textPrimary)
            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("确定") {
                    pane.rename(entry, to: name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .background(QuadroTheme.panel)
        .preferredColorScheme(.dark)
    }
}
