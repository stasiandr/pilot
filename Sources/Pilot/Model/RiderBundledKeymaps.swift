import Foundation

/// Встроенные раскладки Rider — только действия, которые Pilot сопоставляет
/// своим командам. Собрано `bin/rider-keymaps.py` из intellij-community
/// 2614de3ca255 (Apache 2.0); руками не правится.
///
/// Строка `keymap<TAB>имя<TAB>родитель` открывает раскладку, дальше
/// `действие<TAB>сочетание<TAB>…`; у аккорда второе нажатие через запятую.
/// Действие без сочетаний — «в этой раскладке без сочетания».
enum RiderBundledKeymaps {
    static let all = parse(table)

    static func parse(_ text: String) -> RiderKeymaps {
        var keymaps: [String: RiderKeymap] = [:]
        var current: RiderKeymap?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            if fields[0] == "keymap" {
                if let done = current { keymaps[done.name] = done }
                current = RiderKeymap(name: fields[1], parent: fields.count > 2 ? fields[2] : nil, actions: [:])
            } else {
                current?.actions[fields[0]] = fields.dropFirst().map { stroke in
                    let parts = stroke.components(separatedBy: ", ")
                    return RiderKeystroke(first: parts[0], second: parts.count > 1 ? parts[1] : nil)
                }
            }
        }
        if let done = current { keymaps[done.name] = done }
        return RiderKeymaps(keymaps: keymaps)
    }

    private static let table = """
keymap	$default
StepInto	F7
FindUsages	alt F7
FindWordAtCaret	control F3
GotoDeclaration	control B
GotoClass	control N
GotoSymbol	control shift alt N
FileStructurePopup	control F12
Back	control alt LEFT
PreviousTab	alt LEFT
RecentLocations	control shift E
QuickJavaDoc	control Q
GotoFile	control shift N
CloseContent	control F4
Replace	control R
ExpandRegion	control ADD	control EQUALS
ParameterInfo	control P
ShowIntentionActions	alt ENTER
ExpandAllRegions	control shift ADD	control shift EQUALS
CollapseRegion	control SUBTRACT	control MINUS
FindPrevious	shift F3	control shift L
EditorDuplicate	control D
FindInPath	control shift F
Stop	control F2
Find	control F	alt F3
Run	shift F10
GotoImplementation	control alt B
StepOut	shift F8
Resume	F9
EditorDeleteLine	control Y
MethodDown	alt DOWN
GotoNextError	F2
GotoPreviousError	shift F2
FindNext	F3	control L
MethodUp	alt UP
NextTab	alt RIGHT
CodeCompletion	control SPACE
JumpToLastChange	control shift BACK_SPACE
EditorUnSelectWord	control shift W
ToggleLineBreakpoint	control F8
MoveLineDown	alt shift DOWN
MoveLineUp	alt shift UP
EditorSelectWord	control W
StepOver	F8
SaveAll	control S
Forward	control alt RIGHT
CollapseAllRegions	control shift SUBTRACT	control shift MINUS
ActivateProjectToolWindow	alt 1
ActivateRunToolWindow	alt 4
Debug	shift F9
CommentByLineComment	control SLASH	control DIVIDE
RenameElement	shift F6
VcsShowNextChangeMarker	shift control alt DOWN
VcsShowPrevChangeMarker	shift control alt UP
keymap	Mac OS X	$default
CodeCompletion	control SPACE
PreviousTab	control LEFT
QuickJavaDoc	control J
MethodDown	control DOWN
MethodUp	control UP
NextTab	control RIGHT
ActivateProjectToolWindow	meta 1
ActivateRunToolWindow	meta 4
GotoDeclaration	meta B
FindNext	F3	control L
FindPrevious	shift F3	control shift L
VcsShowNextChangeMarker	shift control alt DOWN
VcsShowPrevChangeMarker	shift control alt UP
FindInPath	control shift F
GotoNextElementUnderCaretUsage	ctrl alt DOWN
GotoPrevElementUnderCaretUsage	ctrl alt UP
keymap	Mac OS X 10.5+	$default
CodeCompletion	control SPACE
QuickJavaDoc	F1	control J
MethodDown	ctrl shift DOWN
MethodUp	ctrl shift UP
ActivateProjectToolWindow	meta 1
ActivateRunToolWindow	meta 4
GotoDeclaration	meta B
FindNext	F3	control L
FindPrevious	shift F3	control shift L
VcsShowNextChangeMarker	shift control alt DOWN
VcsShowPrevChangeMarker	shift control alt UP
EditorSelectWord	alt UP
EditorUnSelectWord	alt DOWN
EditorDeleteLine	meta BACK_SPACE
CloseContent	meta W
FindInPath	meta shift F
Find	meta F
FindNext	meta G
FindPrevious	meta shift G
Run	control R
Debug	control D
Resume	meta alt R	F9
GotoClass	meta O
GotoSymbol	meta alt O
GotoFile	meta shift O
FindWordAtCaret
PreviousTab	meta shift OPEN_BRACKET	control LEFT
NextTab	meta shift CLOSE_BRACKET	control RIGHT
Back	meta OPEN_BRACKET	meta alt LEFT
Forward	meta CLOSE_BRACKET	meta alt RIGHT
GotoNextElementUnderCaretUsage	ctrl alt DOWN
GotoPrevElementUnderCaretUsage	ctrl alt UP
keymap	VSCode OSX	Mac OS X 10.5+
ActivateProjectToolWindow	shift meta e
ActivateRunToolWindow	shift meta u
Back	ctrl minus
EditorUnSelectWord
CloseProject	meta k, f	meta shift w
CollapseAllRegions	meta k, meta 0
CollapseRegion	meta alt open_bracket
CommentByLineComment	meta k, meta c	meta k, meta u	meta slash
Debug	f5
EditorDeleteLine	shift meta k
EditorDuplicate
EditorDuplicateLines	shift alt down
EditorSelectWord	shift ctrl meta right	ctrl shift right
EditorUnSelectWord	shift ctrl meta left
ExpandAllRegions	meta k, meta j
ExpandRegion	meta alt close_bracket
FileStructurePopup	meta alt o	shift meta o
FindNext	meta g	f3	meta k, meta d
FindPrevious	shift meta g	shift f3	shift meta f5
Forward	shift ctrl minus
GotoClass
GotoDeclaration	f12
GotoFile	meta p
GotoImplementation	meta f12
GotoNextError	alt f8
GotoPreviousError	shift f8	alt shift f8
GotoSymbol	meta t
JumpToLastChange	meta k, meta q
MethodDown
MethodUp
MoveLineDown	alt down
MoveLineUp	alt up
NextTab	shift meta close_bracket	meta alt right
OpenFile	meta o
ParameterInfo	shift meta space
PreviousTab	shift meta open_bracket	meta alt left
QuickJavaDoc	meta k, meta i
RenameElement	f2
Replace	meta alt f
Resume	f5
Run	ctrl f5
SaveDocument	meta S
SaveAll	meta alt s
ShowIntentionActions	meta period	alt enter
StepInto	f11	f7
StepOut	shift f11
StepOver	f10
Stop	shift f5
ToggleLineBreakpoint	f9
VcsShowNextChangeMarker	alt f3	alt f5
VcsShowPrevChangeMarker	shift alt f3	shift alt f5
EditorDecreaseFontSize	meta minus
EditorIncreaseFontSize	meta equals
RecentLocations
Pause	f6
SelectInProjectView	meta k, e
FindUsages	shift alt f12
CodeCompletion	meta i	alt ESCAPE	ctrl space
CloseAllEditorsButActive	meta alt t	meta k, u
"""
}
