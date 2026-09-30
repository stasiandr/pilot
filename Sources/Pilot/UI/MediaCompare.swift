import SwiftUI
import AppKit

/// Две версии картинки, модели, шрифта или PDF — рядом, тем же
/// просмотрщиком, что открывает файл в редакторе. Картинки — ещё и
/// наложением: ползунок плавно переводит «было» в «стало», и видно, что
/// поменялось. Версии достаются из git (и из LFS) в фоне.
struct MediaCompareView: View {
    struct Side: Equatable {
        var title: String
        var revision: GitBlobs.Revision
    }

    let repository: URL
    let path: String
    /// Откуда: для переименованного — старый путь.
    var originalPath: String? = nil
    let before: Side
    let after: Side

    @State private var urls: (before: URL?, after: URL?)?
    @State private var overlay = false
    @State private var mix = 1.0

    private var kind: MediaKind? { MediaKind(filename: path) }

    var body: some View {
        VStack(spacing: 0) {
            if kind == .image, let urls, urls.before != nil, urls.after != nil {
                HStack {
                    Picker("", selection: $overlay) {
                        Text(L("Рядом")).tag(false)
                        Text(L("Наложением")).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    if overlay {
                        Text(before.title).font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $mix, in: 0...1).frame(maxWidth: 220)
                        Text(after.title).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 30)
                Divider()
            }
            content
        }
        .task(id: before.title + after.title + path) { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let kind, let urls {
            if overlay, kind == .image, let old = urls.before, let new = urls.after {
                ZStack {
                    OverlayImage(url: old)
                    OverlayImage(url: new).opacity(mix)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    pane(before.title, url: urls.before, kind: kind, missing: L("Файла не было"))
                    Rectangle().fill(Color(nsColor: Theme.separator)).frame(width: 1)
                    pane(after.title, url: urls.after, kind: kind, missing: L("Файл удалён"))
                }
            }
        } else if kind == nil {
            Text(L("Двоичный файл — показать нечего")).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func pane(_ title: String, url: URL?, kind: MediaKind, missing: String) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .frame(height: 22)
            if let url {
                MediaView(url: url, kind: kind)
                    .id(url)
            } else {
                Text(missing).foregroundStyle(.tertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        urls = nil
        let repository = repository, path = path, original = originalPath ?? path
        let before = before.revision, after = after.revision
        urls = await Task.detached(priority: .userInitiated) {
            (GitBlobs.file(original, at: before, in: repository), GitBlobs.file(path, at: after, in: repository))
        }.value
    }
}

/// Картинка целиком, вписанная в место, — для наложения двух версий.
private struct OverlayImage: View {
    let url: URL

    var body: some View {
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.none)
                .aspectRatio(contentMode: .fit)
        } else {
            Text(url.lastPathComponent).foregroundStyle(.tertiary)
        }
    }
}

/// Окно сравнения версий из истории: картинка или модель в коммите и до него.
struct MediaCompareWindow: View {
    static let sceneID = "media-compare"
    /// `корень проекта` + `\n` + ключ сравнения в воркспейсе.
    let target: String?

    var body: some View {
        Group {
            if let target, let found = resolve(target), let repository = found.workspace.git.repository {
                MediaCompareView(repository: repository, path: found.comparison.path,
                                 originalPath: found.comparison.originalPath,
                                 before: found.comparison.before, after: found.comparison.after)
                    .navigationTitle((found.comparison.path as NSString).lastPathComponent)
            } else {
                Text(L("Проект этого окна закрыт")).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 700, minHeight: 420)
        .background(Color(nsColor: Theme.swiftUIEditorBackground))
        .preferredColorScheme(Theme.current.isDark ? .dark : .light)
    }

    private func resolve(_ target: String) -> (workspace: Workspace, comparison: MediaComparison)? {
        let parts = target.split(separator: "\n", maxSplits: 1).map(String.init)
        guard parts.count == 2, let workspace = ProjectWindows.shared.workspaces.first(where: { $0.root?.path == parts[0] }),
              let comparison = workspace.mediaComparisons[parts[1]] else { return nil }
        return (workspace, comparison)
    }
}
