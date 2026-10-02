import CryptoKit
import Foundation

/// Что горячей перезагрузке нужно кроме Rustlyn: `gend` и `minigen` —
/// генераторы исходников Unity, запущенные тем же Roslyn, что у редактора
/// (весь `Assembly-CSharp` и один файл), — и `PilotRuntime.dll`, который
/// заплатки зовут в редакторе.
///
/// Исходники их живут в Rustlyn (`tools/unity`) и приезжают в бандл
/// (`Resources/HotReload`). Собираются здесь, под установленную Unity: один
/// раз на версию исходников и редактора, в `~/Library/Caches/Pilot/HotReload`.
enum UnityHotReloadTools {
    struct Built: Sendable {
        let dotnet: URL
        let gend: URL
        let minigen: URL
        let runtime: URL
        /// `libpilotpatch.dylib`: пишет переходы в код, скомпилированный Mono.
        let plugin: URL

        var json: [String: String] {
            ["dotnet": dotnet.path, "gend": gend.path, "minigen": minigen.path, "runtime": runtime.path]
        }
    }

    struct Failure: Error {
        let message: String
    }

    /// Папка с исходниками: в бандле, рядом в `.build` (сборка из
    /// исходников) или Rustlyn рядом с репозиторием.
    static func sources() -> URL? {
        var candidates: [URL] = []
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("HotReload")) }
        let beside = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(beside.appendingPathComponent(".build/rustlyn/unity"))
        if let path = ProcessInfo.processInfo.environment["RUSTLYN_PATH"] {
            candidates.append(URL(fileURLWithPath: path).appendingPathComponent("tools/unity"))
        }
        candidates.append(beside.deletingLastPathComponent().appendingPathComponent("rustlyn/tools/unity"))
        return candidates.first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("gend/Program.cs").path)
        }
    }

    static let files = ["gend/Program.cs", "gend/gend.csproj", "minigen/Program.cs", "minigen/minigen.csproj", "PilotRuntime.cs",
                        "pilotpatch.c"]
    /// Что лежит в проекте, в `Assets/PilotProbe/Editor`, кроме библиотеки.
    static let probeFiles = ["PilotProbe.cs", "PilotHud.cs", "PilotProbe.asmdef"]

    static func prepare(contents: URL, progress: (String) -> Void) -> Result<Built, Failure> {
        guard let sources = sources() else { return .failure(Failure(message: "hot reload tools are not in this build of Pilot")) }
        guard let dotnet = NetcoredbgDebugger.locateDotnet() else { return .failure(Failure(message: "the .NET SDK (dotnet) is not installed")) }
        guard let compiler = UnityGenerators.compiler(in: contents),
              let managed = UnityProjectInfo.managed(in: contents) else {
            return .failure(Failure(message: "Unity's compiler is not in \(contents.path)"))
        }
        // Своя папка на каждые исходники и редактор: старая сборка не
        // путается с новой, и проверять, свежая ли, не нужно.
        var hash = SHA256()
        hash.update(data: Data(contents.path.utf8))
        for file in files {
            hash.update(data: (try? Data(contentsOf: sources.appendingPathComponent(file))) ?? Data())
        }
        let key = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let out = caches.appendingPathComponent("Pilot/HotReload/\(key)")
        let built = Built(dotnet: dotnet, gend: out.appendingPathComponent("gend/gend.dll"),
                          minigen: out.appendingPathComponent("minigen/minigen.dll"),
                          runtime: out.appendingPathComponent("PilotRuntime.dll"),
                          plugin: out.appendingPathComponent("libpilotpatch.dylib"))
        let fm = FileManager.default
        if [built.gend, built.minigen, built.runtime, built.plugin].allSatisfy { (url: URL) in fm.fileExists(atPath: url.path) } {
            return .success(built)
        }
        try? fm.removeItem(at: out)
        let source = out.appendingPathComponent("src")
        for file in files {
            let target = source.appendingPathComponent(file)
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.copyItem(at: sources.appendingPathComponent(file), to: target)
        }
        for tool in ["gend", "minigen"] {
            progress(L("Собираю \(tool)…"))
            let result = run(dotnet, ["build", source.appendingPathComponent("\(tool)/\(tool).csproj").path,
                                      "-c", "Release", "-nologo", "-v:q",
                                      "-o", out.appendingPathComponent(tool).path,
                                      "-p:UnityContents=\(contents.path)"])
            if let result { return .failure(Failure(message: "\(tool) did not build: \(result)")) }
        }
        progress(L("Собираю PilotRuntime…"))
        let netstandard = [contents, contents.appendingPathComponent("Resources/Scripting")]
            .map { $0.appendingPathComponent("NetStandard/ref/2.1.0/netstandard.dll") }
            .first { fm.fileExists(atPath: $0.path) }
        guard let netstandard else { return .failure(Failure(message: "netstandard.dll is not in \(contents.path)")) }
        let result = run(compiler.dotnet, [
            compiler.csc.path, "-nologo", "-noconfig", "-nostdlib", "-target:library", "-optimize",
            "-out:\(built.runtime.path)", "-r:\(netstandard.path)",
            "-r:\(managed.appendingPathComponent("UnityEngine/UnityEngine.CoreModule.dll").path)",
            source.appendingPathComponent("PilotRuntime.cs").path,
        ])
        if let result { return .failure(Failure(message: "PilotRuntime did not build: \(result)")) }
        progress(L("Собираю pilotpatch…"))
        let plugin = run(URL(fileURLWithPath: "/usr/bin/xcrun"), [
            "clang", "-O2", "-dynamiclib", "-arch", "arm64", "-arch", "x86_64",
            "-o", built.plugin.path, source.appendingPathComponent("pilotpatch.c").path,
        ])
        if let plugin { return .failure(Failure(message: "pilotpatch did not build (Command Line Tools?): \(plugin)")) }
        return .success(built)
    }

    /// Что поменялось в проекте: скрипты пробы Unity компилирует (и
    /// перезагружается), библиотеку только импортирует.
    struct Installed {
        var scripts = false
        var plugin = false
    }

    /// Кладёт пробу в проект или обновляет её.
    static func installProbe(project: URL, built: Built) -> Result<Installed, Failure> {
        guard let sources = sources() else { return .failure(Failure(message: "the probe is not in this build of Pilot")) }
        let fm = FileManager.default
        let folder = project.appendingPathComponent("Assets/PilotProbe/Editor")
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var installed = Installed()
            let pairs = probeFiles.map { (sources.appendingPathComponent($0), folder.appendingPathComponent($0)) }
                + [(built.plugin, folder.appendingPathComponent("libpilotpatch.dylib"))]
            for (from, to) in pairs {
                let fresh = try Data(contentsOf: from)
                if (try? Data(contentsOf: to)) == fresh { continue }
                try fresh.write(to: to, options: .atomic)
                if to.pathExtension == "dylib" { installed.plugin = true } else { installed.scripts = true }
            }
            return .success(installed)
        } catch {
            return .failure(Failure(message: "the probe could not be put in the project: \(error.localizedDescription)"))
        }
    }

    /// `nil` — получилось; иначе хвост вывода.
    private static func run(_ executable: URL, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["DOTNET_CLI_TELEMETRY_OPTOUT"] = "1"
        environment["DOTNET_NOLOGO"] = "1"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return error.localizedDescription }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        return String(String(decoding: data, as: UTF8.self).suffix(600))
    }
}
