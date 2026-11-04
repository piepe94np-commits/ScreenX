import AppKit

/// Hauptmenü, solange Editor-Fenster offen sind. Es macht die Tastenkürzel ⌘,, ⌘O, ⌘S, ⇧⌘S, ⌘W,
/// ⌘Z, ⇧⌘Z und ⌘C (sowie Ausschneiden/Einfügen für Textfelder) verfügbar.
/// Widerrufen, Wiederholen und Kopieren nutzen eigene Selektoren (`editorUndo:` usw.) statt `undo:`/`copy:`:
/// Diese Standard-Selektoren beantworten `NSWindow`, das Textfeld oder `NSHostingView` schon vor dem
/// Controller in der Responder-Kette, und dann liefen offene Farbänderungen nicht vorher ab.
@MainActor
enum EditorMenu {
    private static var menu: NSMenu?
    private static var previous: NSMenu?

    static func install() {
        let editorMenu = menu ?? build()
        menu = editorMenu
        guard NSApp.mainMenu !== editorMenu else { return }
        previous = NSApp.mainMenu
        NSApp.mainMenu = editorMenu
        NSApp.windowsMenu = editorMenu.items.last?.submenu
    }

    /// Ruft „Einstellungen …“ aus dem SwiftUI-Hauptmenü auf, das der Editor ersetzt hat.
    /// `false`, wenn es dort keinen solchen Eintrag gibt.
    static func performPreviousSettingsItem() -> Bool {
        guard let previous, let item = settingsItem(in: previous), let action = item.action else { return false }
        return NSApp.sendAction(action, to: item.target, from: item)
    }

    private static func settingsItem(in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.keyEquivalent == ",", item.keyEquivalentModifierMask == .command { return item }
            if let submenu = item.submenu, let found = settingsItem(in: submenu) { return found }
        }
        return nil
    }

    static func uninstall() {
        guard let menu, NSApp.mainMenu === menu else { return }
        NSApp.mainMenu = previous
        previous = nil
    }

    private static func build() -> NSMenu {
        let main = NSMenu()
        add(to: main, title: "ScreenX", items: [
            item(String(localized: "Über ScreenX"), #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item(String(localized: "Einstellungen …"), #selector(EditorWindowController.showSettings(_:)), ","),
            .separator(),
            item(String(localized: "ScreenX ausblenden"), #selector(NSApplication.hide(_:)), "h"),
            item(String(localized: "Andere ausblenden"), #selector(NSApplication.hideOtherApplications(_:)),
                 "h", [.command, .option]),
            item(String(localized: "Alle einblenden"), #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item(String(localized: "ScreenX beenden"), #selector(NSApplication.terminate(_:)), "q"),
        ])
        add(to: main, title: String(localized: "Ablage"), items: [
            item(String(localized: "Öffnen …"), #selector(EditorWindowController.openProject(_:)), "o"),
            .separator(),
            item(String(localized: "Schließen"), #selector(NSWindow.performClose(_:)), "w"),
            item(String(localized: "Projekt sichern"), #selector(EditorWindowController.saveProject(_:)), "s"),
            item(String(localized: "Projekt sichern unter …"), #selector(EditorWindowController.saveProjectAs(_:)),
                 "s", [.command, .option, .shift]),
            item(String(localized: "Sichern unter …"), #selector(EditorWindowController.exportImageAs(_:)),
                 "s", [.command, .shift]),
        ])
        add(to: main, title: String(localized: "Bearbeiten"), items: [
            item(String(localized: "Widerrufen"), #selector(EditorWindowController.editorUndo(_:)), "z"),
            item(String(localized: "Wiederholen"), #selector(EditorWindowController.editorRedo(_:)), "z", [.command, .shift]),
            .separator(),
            item(String(localized: "Ausschneiden"), #selector(NSText.cut(_:)), "x"),
            item(String(localized: "Kopieren"), #selector(EditorWindowController.editorCopy(_:)), "c"),
            item(String(localized: "Einfügen"), #selector(NSText.paste(_:)), "v"),
            item(String(localized: "Alles auswählen"), #selector(NSText.selectAll(_:)), "a"),
        ])
        add(to: main, title: String(localized: "Fenster"), items: [
            item(String(localized: "Minimieren"), #selector(NSWindow.performMiniaturize(_:)), "m"),
            item(String(localized: "Zoomen"), #selector(NSWindow.performZoom(_:))),
        ])
        return main
    }

    private static func add(to main: NSMenu, title: String, items: [NSMenuItem]) {
        let submenu = NSMenu(title: title)
        for item in items { submenu.addItem(item) }
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = submenu
        main.addItem(holder)
    }

    private static func item(
        _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
