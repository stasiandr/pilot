import Foundation

// `⌘B` и `⌥⌘B` через Rustlyn.
//
// Быстрый навигатор ниже разбирает `a.b().c` по объявленным типам из
// собственного индекса и на реальном проекте сразу прыгает примерно в
// половине случаев. Промахи у него двух видов, и второй хуже первого:
// не нашёл — видно; нашёл не то — не видно.
//
// Не видно там, где короткое имя встречается дважды. У Unity-проекта свой
// `Vector3` рядом с движковым, свой `Config` рядом с чужим, и выбор между
// ними — это область видимости на месте обращения: какой `namespace` у файла,
// какие у него `using`, какой псевдоним объявлен. Rustlyn это и делает: имя
// разрешается так, как его разрешает C#, а когда область видимости не
// разрешает — он возвращает всех кандидатов и говорит, что не разрешила.
//
// Здесь только перевод ответа. Когда Rustlyn отвечает — берём его ответ;
// когда нет (сессия не поднята, индекс ещё не собран, файл правят прямо
// сейчас) — работает навигатор ниже, как работал.

extension LocalNavigator {

    /// Ответ Rustlyn на `⌘B`, или `nil` — тогда отвечает навигатор по
    /// собственному индексу.
    func rustlynDefinition(at offset: Int) -> Answer? {
        guard let rustlyn = Rustlyn.shared,
              let file = document.model.settledFile else { return nil }
        return answer(from: rustlyn.definition(file, offset: offset))
    }

    /// То же для `⌥⌘B`: кто наследует тип или переопределяет метод.
    func rustlynImplementations(at offset: Int) -> Answer? {
        guard let rustlyn = Rustlyn.shared,
              let file = document.model.settledFile else { return nil }
        return answer(from: rustlyn.implementations(file, offset: offset))
    }

    private func answer(from definition: RustlynDefinition) -> Answer? {
        switch definition.refusal {
        case .none:
            break
        case .notAName:
            // Курсор на скобке, ключевом слове или внутри строки. Это не
            // «Rustlyn не смог» — это «идти некуда», и навигатору ниже тоже
            // некуда. Отвечаем пустотой, а не отказом.
            return .none
        case .notInProject, .receiverUnknown:
            // Имя есть, но оно не отсюда: тип из сборки, или слева от точки
            // то, чей тип неизвестен. Пусть попробует свой навигатор — у него
            // другие догадки, и иногда они срабатывают.
            return nil
        default:
            // Индекс ещё не собран, файл не открыт на той стороне, сломалась
            // сборка. Всё это временно или чинится; свой навигатор работает.
            return nil
        }

        guard !definition.targets.isEmpty else { return nil }
        let declarations = definition.targets.map { target in
            FoundDeclaration(
                target: target.navTarget,
                name: target.shortName,
                kind: target.kind.outlineKind,
                container: target.container,
                path: relativePath(of: target.url, from: rustlynRoot)
            )
        }
        // `isExact` означает «можно прыгать сразу». У Rustlyn это ровно
        // `certain`: одно объявление, и область видимости его выбрала. Всё
        // остальное показывается списком — наугад выбранный из двух
        // одноимённых типов уводит молча, и это худший из возможных ответов.
        return Answer(declarations: declarations, isExact: definition.certain)
    }

    private var rustlynRoot: URL? { Rustlyn.shared?.root }

    /// Путь для показа в списке: от корня проекта, если файл под ним.
    private func relativePath(of url: URL, from root: URL?) -> String {
        guard let root else { return url.lastPathComponent }
        let path = url.path
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : url.lastPathComponent
    }
}
