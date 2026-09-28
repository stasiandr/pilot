import Combine

/// Набранное в палитре и найденное — отдельно от воркспейса.
///
/// На каждую букву меняются запрос, выдача, выделенная строка и спиннер.
/// Будь они @Published у Workspace, каждая буква будила бы всех, кто его
/// наблюдает: окно целиком — тулбар, навигатор, вкладки, редактор — и главное
/// меню (`@FocusedObject` в PilotApp), и с каждой порцией выдачи ещё раз. На
/// clm-client это была треть работы главного потока на букву. Этот объект
/// наблюдает только палитра; воркспейс отдаёт те же свойства переходниками.
@MainActor
final class PaletteState: ObservableObject {
    @Published var query = ""
    @Published var items: [PaletteItem] = []
    @Published var selection = 0
    @Published var busy = false
}
