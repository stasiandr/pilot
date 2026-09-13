using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Reflection;
using Unity.CodeEditor;
using UnityEditor;
using UnityEngine;
using Debug = UnityEngine.Debug;

namespace Pilot.Editor
{
    /// <summary>
    /// Pilot как внешний редактор скриптов: Preferences → External Tools →
    /// External Script Editor. Файл уходит в уже запущенный Pilot адресом
    /// <c>pilot://open?file=…&amp;line=…&amp;project=…</c> — со строкой и столбцом,
    /// без перезапуска.
    ///
    /// .sln и .csproj сам пакет не пишет: это умеет пакет Rider, и он делает
    /// это, даже когда текущий редактор не Rider. Без него Unity файлы проекта
    /// не обновляет, и языковой сервер в Pilot не видит новых скриптов.
    /// </summary>
    [InitializeOnLoad]
    public class PilotCodeEditor : IExternalCodeEditor
    {
        const string BundleId = "dev.local.pilot";

        /// Кто генерирует файлы проекта. Пакет Visual Studio не подходит:
        /// он синхронизирует, только когда текущий редактор — Visual Studio.
        static readonly string[] k_Generators =
        {
            "Packages.Rider.Editor.RiderScriptEditor",
            "VSCodeEditor.VSCodeScriptEditor",
        };

        /// Что Unity открывает во внешнем редакторе — как у Rider: остальное
        /// (сцены, текстуры) Unity открывает сама.
        static readonly HashSet<string> k_Extensions = new HashSet<string>(StringComparer.OrdinalIgnoreCase)
        {
            ".cs", ".uxml", ".uss", ".shader", ".compute", ".cginc", ".hlsl", ".glslinc", ".template",
            ".raytrace", ".json", ".rsp", ".asmdef", ".asmref", ".xaml", ".tt", ".t4", ".ttinclude",
        };

        static PilotCodeEditor()
        {
            if (Application.platform != RuntimePlatform.OSXEditor || AssetDatabase.IsAssetImportWorkerProcess())
                return;
            CodeEditor.Register(new PilotCodeEditor());
        }

        static string ProjectDirectory => Directory.GetParent(Application.dataPath).FullName;

        public CodeEditor.Installation[] Installations =>
            new[]
                {
                    "/Applications/Pilot.app",
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Personal), "Applications/Pilot.app"),
                }
                .Where(IsPilot)
                .Select(Installation)
                .ToArray();

        public bool TryGetInstallationForPath(string editorPath, out CodeEditor.Installation installation)
        {
            installation = default;
            if (!IsPilot(editorPath)) return false;
            installation = Installation(editorPath);
            return true;
        }

        static CodeEditor.Installation Installation(string path) => new CodeEditor.Installation
        {
            Name = path.StartsWith("/Applications/") ? "Pilot" : $"Pilot ({Path.GetDirectoryName(path)})",
            Path = path,
        };

        /// Pilot.app узнаём по идентификатору бандла: тестовые сборки
        /// с суффиксом (dev.local.pilot.test) тоже подходят.
        static bool IsPilot(string path)
        {
            if (string.IsNullOrEmpty(path)) return false;
            var plist = Path.Combine(path, "Contents/Info.plist");
            try
            {
                return File.Exists(plist) && File.ReadAllText(plist).Contains(BundleId);
            }
            catch (IOException)
            {
                return false;
            }
        }

        public void Initialize(string editorInstallationPath)
        {
            // Пакет Rider мог ещё не зарегистрироваться — порядок InitializeOnLoad не задан.
            EditorApplication.delayCall += () =>
            {
                if (!HasSolution()) SyncAll();
            };
        }

        public bool OpenProject(string filePath = "", int line = -1, int column = -1)
        {
            // «Assets → Open C# Project» присылает пустой путь.
            if (filePath != "" && !IsCodeFile(filePath)) return false;
            var app = CodeEditor.CurrentEditorInstallation;
            if (!IsPilot(app)) return false;
            if (!HasSolution()) SyncAll();

            var query = new List<string> { Parameter("project", ProjectDirectory) };
            if (filePath != "")
            {
                query.Add(Parameter("file", PhysicalPath(filePath)));
                if (line > 0) query.Add(Parameter("line", line.ToString()));
                if (column > 0) query.Add(Parameter("column", column.ToString()));
            }
            return Launch(app, "pilot://open?" + string.Join("&", query));
        }

        static string Parameter(string name, string value) => name + "=" + Uri.EscapeDataString(value);

        /// <c>open -a</c> отдаёт адрес запущенному Pilot Apple Event'ом,
        /// а незапущенный запускает — и адрес приходит сразу после старта.
        static bool Launch(string app, string url)
        {
            try
            {
                using (var process = Process.Start(new ProcessStartInfo
                       {
                           FileName = "/usr/bin/open",
                           Arguments = $"-a \"{app}\" \"{url}\"",
                           UseShellExecute = false,
                           CreateNoWindow = true,
                       }))
                {
                    return process != null;
                }
            }
            catch (Exception e)
            {
                Debug.LogException(e);
                return false;
            }
        }

        static bool IsCodeFile(string path)
        {
            var extension = Path.GetExtension(path);
            if (k_Extensions.Contains(extension)) return true;
            // Project Settings → Editor → Additional extensions to include.
            return EditorSettings.projectGenerationUserExtensions
                .Any(e => string.Equals("." + e.TrimStart('.'), extension, StringComparison.OrdinalIgnoreCase));
        }

        /// Скрипты пакетов из Library/PackageCache Unity называет Packages/имя/…,
        /// а такой папки на диске нет.
        static string PhysicalPath(string path)
        {
            var full = Path.GetFullPath(path);
            if (File.Exists(full)) return full;
            var prefix = ProjectDirectory + Path.DirectorySeparatorChar;
            var logical = full.StartsWith(prefix) ? full.Substring(prefix.Length) : path;
            var physical = FileUtil.GetPhysicalPath(logical);
            return string.IsNullOrEmpty(physical) ? full : Path.GetFullPath(physical);
        }

        static bool HasSolution() => Directory.GetFiles(ProjectDirectory, "*.sln").Length > 0;

        static IExternalCodeEditor Generator
        {
            get
            {
                var field = typeof(CodeEditor).GetField("m_ExternalCodeEditors", BindingFlags.Instance | BindingFlags.NonPublic);
                if (!(field?.GetValue(CodeEditor.Editor) is IEnumerable<IExternalCodeEditor> registered)) return null;
                var editors = registered.ToList();
                return k_Generators
                    .Select(name => editors.FirstOrDefault(e => e.GetType().FullName == name))
                    .FirstOrDefault(e => e != null);
            }
        }

        public void SyncIfNeeded(string[] addedFiles, string[] deletedFiles, string[] movedFiles, string[] movedFromFiles,
            string[] importedFiles)
        {
            Generator?.SyncIfNeeded(addedFiles, deletedFiles, movedFiles, movedFromFiles, importedFiles);
        }

        public void SyncAll()
        {
            Generator?.SyncAll();
        }

        /// Под выбором редактора — настройки генерации того пакета, что пишет
        /// .csproj: для каких пакетов их делать, кнопка «Regenerate project files».
        public void OnGUI()
        {
            var generator = Generator;
            if (generator == null)
            {
                EditorGUILayout.HelpBox(
                    "Файлы решения (.sln, .csproj) Pilot получает от пакета Rider — добавьте com.unity.ide.rider. " +
                    "Без него языковой сервер в Pilot не увидит новые скрипты.",
                    MessageType.Warning);
                return;
            }
            EditorGUILayout.LabelField("Файлы решения генерирует пакет " + generator.GetType().Assembly.GetName().Name,
                EditorStyles.miniLabel);
            generator.OnGUI();
        }
    }
}
