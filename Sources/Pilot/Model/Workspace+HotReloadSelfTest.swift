import Foundation

/// Проверка горячей перезагрузки без рук, но тем же путём, что ⌘S:
/// `PILOT_HOT_RELOAD_SELFTEST="<путь от проекта>|<текст, после которого
/// вставить строку>"`. Когда горячая перезагрузка включилась, файл
/// открывается в редакторе, в буфер вставляется строка с `Debug.Log`,
/// буфер сохраняется, через 10 секунд правка снимается и буфер сохраняется
/// снова. Что из этого вышло — в окне Pilot Hot Reload и в журнале `[hot]`.
extension Workspace {
    func scheduleHotReloadSelfTest() {
        guard let spec = ProcessInfo.processInfo.environment["PILOT_HOT_RELOAD_SELFTEST"] else { return }
        let parts = spec.components(separatedBy: "|")
        guard parts.count == 2 else { return }
        Task { @MainActor [weak self] in
            // Ждём, пока перезагрузка включится: старт — минута-другая.
            for _ in 0..<600 {
                guard let self else { return }
                if self.unityHotReload.isOn { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.runHotReloadSelfTest(path: parts[0], anchor: parts[1].replacingOccurrences(of: "\\n", with: "\n"))
        }
    }

    private func runHotReloadSelfTest(path: String, anchor: String) {
        guard let root = unity.project?.root else { return }
        let url = root.appendingPathComponent(path)
        open(file: url) { [weak self] in
            guard let self, let buffer = self.buffer, buffer.url.standardizedFileURL == url.standardizedFileURL else {
                NSLog("[hot] самопроверка: файл не открылся")
                return
            }
            let text = buffer.storage.string as NSString
            let found = text.range(of: anchor)
            guard found.location != NSNotFound else {
                NSLog("[hot] самопроверка: нет «%@» в файле", anchor)
                return
            }
            let line = "            UnityEngine.Debug.Log(\"Pilot self-test\");\n"
            let undo = buffer.applyEdits([(NSRange(location: NSMaxRange(found), length: 0), line)],
                                         actionName: "Self-test")
            NSLog("[hot] самопроверка: правка в буфере, сохраняю")
            self.save()
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard let self, let buffer = self.buffer else { return }
                _ = buffer.applyEdits(undo, actionName: "Self-test")
                NSLog("[hot] самопроверка: правка снята, сохраняю")
                self.save()
            }
        }
    }
}
