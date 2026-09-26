import Foundation

/// Что показывает инспектор для объекта под курсором — как в Unity:
/// GameObject со всеми компонентами, вложенный префаб с его
/// переопределениями или самостоятельный объект ассета (ScriptableObject,
/// материал, состояние аниматора).
struct UnityInspectorContent {
    enum Kind { case gameObject, prefabInstance, asset }

    var kind: Kind
    /// Объект, который описывает шапка: GameObject, PrefabInstance или сам ассет.
    var objectIndex: Int
    var title: String
    var name: UnityProperty?
    var active: UnityProperty?
    var tag: UnityProperty?
    var layer: UnityProperty?
    /// Предки в иерархии — для хлебных крошек, от корня.
    var path: [Link] = []
    var children: [Link] = []
    /// Исходный префаб вложенного префаба; скрипт ScriptableObject'а.
    var source: UnityGUID?
    var sections: [Section] = []
    /// Секция, в которой стоит курсор.
    var focusedSection: Int?

    struct Link: Identifiable {
        var id: Int64 { fileID }
        var name: String
        var fileID: Int64
        var isPrefab = false
    }

    struct Section: Identifiable {
        var id: Int64 { fileID }
        var fileID: Int64
        var objectIndex: Int
        var title: String
        var typeName: String
        var script: UnityGUID?
        var enabled: UnityProperty?
        /// Поля, которые показал бы инспектор Unity.
        var properties: [UnityProperty]
        /// Все поля — для режима отладки.
        var allProperties: [UnityProperty]
        var isTransform: Bool { typeName == "Transform" || typeName == "RectTransform" }
    }
}

enum UnityInspector {

    /// Служебные поля: Unity их в инспекторе не показывает.
    static let hiddenKeys: Set<String> = [
        "m_ObjectHideFlags", "m_CorrespondingSourceObject", "m_PrefabInstance", "m_PrefabAsset",
        "m_PrefabInternal", "m_PrefabParentObject", "m_GameObject", "serializedVersion",
        "m_EditorHideFlags", "m_EditorClassIdentifier", "m_Script", "m_Name", "m_Enabled",
        "m_Component", "m_Children", "m_Father", "m_LocalEulerAnglesHint", "m_RootOrder",
        "m_IsActive", "m_TagString", "m_Layer",
    ]

    static func content(file: UnityYAMLFile, model: SyntaxModel, caret: Int,
                        resolve: (UnityGUID) -> String?) -> UnityInspectorContent? {
        guard var index = file.objectIndex(containing: caret) else {
            return file.objects.isEmpty ? nil : content(file: file, model: model, caret: file.objects[0].start,
                                                        resolve: resolve)
        }
        var object = file.objects[index]

        // Заглушка вложенного префаба — показываем сам префаб.
        if object.stripped, let instance = object.prefabInstance, let i = file.index(ofFileID: instance) {
            index = i
            object = file.objects[i]
        }
        if object.isPrefabInstance {
            return prefabInstance(file: file, model: model, index: index, resolve: resolve)
        }
        if let go = object.gameObject, go != 0, let goIndex = file.index(ofFileID: go) {
            if file.objects[goIndex].stripped, let instance = file.objects[goIndex].prefabInstance,
               let i = file.index(ofFileID: instance) {
                // Компонент, добавленный к вложенному префабу.
                return prefabInstance(file: file, model: model, index: i, resolve: resolve)
            }
            return gameObject(file: file, model: model, index: goIndex, focus: object.fileID, resolve: resolve)
        }
        if object.isGameObject {
            return gameObject(file: file, model: model, index: index, focus: nil, resolve: resolve)
        }
        return asset(file: file, model: model, index: index, resolve: resolve)
    }

    // MARK: - GameObject

    private static func gameObject(file: UnityYAMLFile, model: SyntaxModel, index: Int, focus: Int64?,
                                   resolve: (UnityGUID) -> String?) -> UnityInspectorContent {
        let object = file.objects[index]
        let props = file.properties(ofObjectAt: index, in: model)
        var content = UnityInspectorContent(kind: .gameObject, objectIndex: index,
                                            title: object.name ?? "GameObject")
        content.name = props.first { $0.key == "m_Name" }
        content.active = props.first { $0.key == "m_IsActive" }
        content.tag = props.first { $0.key == "m_TagString" }
        content.layer = props.first { $0.key == "m_Layer" }

        // Компоненты — в порядке m_Component, как в инспекторе Unity.
        var componentIDs: [Int64] = []
        if case .sequence(let items)? = props.first(where: { $0.key == "m_Component" })?.value {
            for item in items {
                if let ref = item.child("component")?.value.reference ?? item.value.reference {
                    componentIDs.append(ref.fileID)
                }
            }
        }
        if componentIDs.isEmpty {
            componentIDs = file.objects.filter { $0.gameObject == object.fileID }.map(\.fileID)
        }

        var transformProps: [UnityProperty] = []
        for id in componentIDs {
            guard let i = file.index(ofFileID: id) else { continue }
            let section = self.section(file: file, model: model, index: i, resolve: resolve)
            if section.isTransform { transformProps = section.allProperties }
            if id == focus { content.focusedSection = content.sections.count }
            content.sections.append(section)
        }

        // Иерархия: предки по m_Father, дети — по m_Children трансформа.
        let father = transform(of: object.fileID, in: file).flatMap { file.object($0)?.father }
        content.path = ancestors(file: file, fromTransform: father, resolve: resolve)
        if case .sequence(let items)? = transformProps.first(where: { $0.key == "m_Children" })?.value {
            for item in items {
                guard let child = item.value.reference?.fileID else { continue }
                if let link = owner(ofTransform: child, file: file, resolve: resolve) { content.children.append(link) }
            }
        }
        return content
    }

    /// Цепочка предков, начиная с Transform'а родителя. Через вложенные
    /// префабы идём по их `m_TransformParent`.
    private static func ancestors(file: UnityYAMLFile, fromTransform start: Int64?,
                                  resolve: (UnityGUID) -> String?) -> [UnityInspectorContent.Link] {
        var chain: [UnityInspectorContent.Link] = []
        var current = start
        var budget = 128
        while let id = current, id != 0, budget > 0, let t = file.object(id) {
            budget -= 1
            if t.stripped, let instance = t.prefabInstance, let p = file.object(instance) {
                chain.insert(.init(name: file.displayName(of: p, resolve: resolve), fileID: instance,
                                   isPrefab: true), at: 0)
                current = p.transformParent
            } else if let go = t.gameObject, let g = file.object(go) {
                chain.insert(.init(name: g.name ?? "GameObject", fileID: go), at: 0)
                current = t.father
            } else {
                break
            }
        }
        return chain
    }

    private static func transform(of gameObject: Int64, in file: UnityYAMLFile) -> Int64? {
        file.objects.first { $0.gameObject == gameObject && $0.father != nil && !$0.stripped }?.fileID
    }

    /// Чей это Transform: GameObject'а или вложенного префаба.
    private static func owner(ofTransform id: Int64, file: UnityYAMLFile,
                              resolve: (UnityGUID) -> String?) -> UnityInspectorContent.Link? {
        guard let t = file.object(id) else { return nil }
        if t.stripped, let instance = t.prefabInstance, let p = file.object(instance) {
            return .init(name: file.displayName(of: p, resolve: resolve), fileID: instance, isPrefab: true)
        }
        guard let go = t.gameObject, let g = file.object(go) else { return nil }
        return .init(name: g.name ?? "GameObject", fileID: go)
    }

    // MARK: - Вложенный префаб

    private static func prefabInstance(file: UnityYAMLFile, model: SyntaxModel, index: Int,
                                       resolve: (UnityGUID) -> String?) -> UnityInspectorContent {
        let object = file.objects[index]
        let props = file.properties(ofObjectAt: index, in: model)
        var content = UnityInspectorContent(kind: .prefabInstance, objectIndex: index,
                                            title: file.displayName(of: object, resolve: resolve))
        content.source = object.sourcePrefab

        // Переопределения: `propertyPath` → `value` (или ссылка в objectReference).
        var overrides: [UnityProperty] = []
        if case .sequence(let items)? = props.first(where: { $0.key == "m_Modification" })?
            .child("m_Modifications")?.value {
            for item in items {
                guard let path = item.child("propertyPath")?.value.scalar?.text else { continue }
                if path == "m_Name", let value = item.child("value") { content.name = value }
                let reference = item.child("objectReference")
                if let ref = reference?.value.reference, ref.fileID != 0 || ref.guid != nil, let reference {
                    overrides.append(UnityProperty(key: path, line: item.line, value: reference.value))
                } else if let value = item.child("value") {
                    overrides.append(UnityProperty(key: path, line: item.line, value: value.value))
                }
            }
        }
        content.sections = [UnityInspectorContent.Section(
            fileID: object.fileID, objectIndex: index, title: L("Переопределения"), typeName: "PrefabInstance",
            script: nil, enabled: nil, properties: overrides, allProperties: props)]
        content.path = ancestors(file: file, fromTransform: object.transformParent, resolve: resolve)
        return content
    }

    // MARK: - Самостоятельный объект

    private static func asset(file: UnityYAMLFile, model: SyntaxModel, index: Int,
                              resolve: (UnityGUID) -> String?) -> UnityInspectorContent {
        let object = file.objects[index]
        let section = self.section(file: file, model: model, index: index, resolve: resolve)
        var content = UnityInspectorContent(kind: .asset, objectIndex: index,
                                            title: object.name.flatMap { $0.isEmpty ? nil : $0 } ?? section.title)
        content.name = section.allProperties.first { $0.key == "m_Name" }
        content.source = object.script
        content.sections = [section]
        content.focusedSection = 0
        return content
    }

    private static func section(file: UnityYAMLFile, model: SyntaxModel, index: Int,
                                resolve: (UnityGUID) -> String?) -> UnityInspectorContent.Section {
        let object = file.objects[index]
        let props = file.properties(ofObjectAt: index, in: model)
        return UnityInspectorContent.Section(
            fileID: object.fileID, objectIndex: index,
            title: file.componentName(of: object, resolve: resolve),
            typeName: object.typeName, script: object.script,
            enabled: props.first { $0.key == "m_Enabled" },
            properties: props.filter { !hiddenKeys.contains($0.key) },
            allProperties: props)
    }

    // MARK: - Подсказки для полей без скрипта

    /// Встроенные компоненты скрипта не имеют, но их bool-поля узнаются по имени.
    static func looksBoolean(_ key: String, _ scalar: UnityScalar) -> Bool {
        guard scalar.raw == "0" || scalar.raw == "1" else { return false }
        let name = key.hasPrefix("m_") ? String(key.dropFirst(2)) : key
        for prefix in ["Is", "Use", "Enable", "Has", "Allow", "Can", "Should", "Show", "Auto", "Receive",
                       "Cast", "Freeze", "Play", "Loop", "Mute", "Bypass", "Raycast", "Maskable",
                       "Interactable", "Convex", "Constrain", "Occlusion", "HDR", "Dynamic", "Static"]
        where name.hasPrefix(prefix) {
            return true
        }
        return ["orthographic", "m_Enabled", "m_IsActive", "m_Interactable", "m_HDR"].contains(key)
    }
}
