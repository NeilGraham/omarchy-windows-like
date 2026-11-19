// windows-like-settings — Settings, laid out like Windows 11's: the displays
// (with the way into the Displays app), and what omarchy-windows-like
// changes: the taskbar and Start, snapping, tabs, and more.
//
// `windows-like-settings --this-pc` is This PC instead: folders, drives and
// network locations with the space on each, opened in Files.

#include <QGuiApplication>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQuickStyle>
#include <QUrl>
#include <memory>

#include "backend.h"
#include "drives.h"
#include "monitors.h"
#include "theme.h"
#include "translator.h"

int main(int argc, char *argv[]) {
    QGuiApplication app(argc, argv);
    app.setApplicationName("windows-like-settings");
    app.setApplicationVersion("0.2.0");

    // Matches the window to windows-like-settings.desktop (or
    // windows-like-this-pc.desktop), so the compositor (Wayland app_id), the
    // taskbar and the launcher tell the two apart and pick up their icons.
    const bool thisPc = app.arguments().contains("--this-pc");
    const QString id = thisPc ? "windows-like-this-pc" : "windows-like-settings";
    app.setDesktopFileName(id);
    app.setWindowIcon(QIcon::fromTheme(id));

    QQuickStyle::setStyle("Material");

    // Installed before anything is translated, and every qsTr() binding is
    // re-evaluated when the Omarchy language changes.
    Translator translator;
    app.installTranslator(&translator);

    Theme theme;
    // Each window gets only what it uses.
    std::unique_ptr<Backend> backend;
    std::unique_ptr<Monitors> monitors;
    std::unique_ptr<Drives> drives;

    QQmlApplicationEngine engine;
    QObject::connect(&translator, &Translator::changed, &engine, &QQmlEngine::retranslate);
    engine.rootContext()->setContextProperty("translator", &translator);
    engine.rootContext()->setContextProperty("theme", &theme);
    if (thisPc) {
        drives = std::make_unique<Drives>();
        engine.rootContext()->setContextProperty("drives", drives.get());
        engine.load(QUrl("qrc:/ThisPC.qml"));
    } else {
        backend = std::make_unique<Backend>();
        monitors = std::make_unique<Monitors>();
        engine.rootContext()->setContextProperty("backend", backend.get());
        engine.rootContext()->setContextProperty("monitors", monitors.get());
        engine.load(QUrl("qrc:/Main.qml"));
    }
    if (engine.rootObjects().isEmpty())
        return 1;

    return app.exec();
}
