#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QtTest>

#include <QJsonDocument>
#include <QJsonObject>
#include <QSignalSpy>

#include "backend.h"
#include "theme.h"
#include "translator.h"

class WindowsLikeSettingsTests : public QObject {
    Q_OBJECT

private slots:
    void themeFallsBack()
    {
        QTemporaryDir dir;
        Theme theme(dir.path());
        QCOMPARE(theme.accent(), QString("#FFD60A"));
        QCOMPARE(theme.accentForeground(), QString("black"));
    }

    void themeReadsAccent()
    {
        QTemporaryDir dir;
        QDir(dir.path()).mkpath("theme");
        QFile colors(dir.path() + "/theme/colors.toml");
        QVERIFY(colors.open(QIODevice::WriteOnly));
        colors.write("accent = \"#112233\"\n");
        colors.close();

        Theme theme(dir.path());
        QCOMPARE(theme.accent(), QString("#112233"));
        QCOMPARE(theme.accentForeground(), QString("white"));
    }

    void themeFollowsHyprlandRounding()
    {
        QTemporaryDir dir;
        const QString response = dir.filePath("response.json"), command = dir.filePath("hyprctl");
        auto write = [](const QString &path, const QByteArray &data) {
            QFile file(path);
            return file.open(QIODevice::WriteOnly) && file.write(data) == data.size();
        };
        QVERIFY(write(command, "#!/bin/sh\ncat '" + response.toUtf8() + "'\n"));
        QVERIFY(QFile::setPermissions(command, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner));
        QVERIFY(write(response, "{\"int\":0}"));

        Theme theme(dir.path(), nullptr, command);
        QCOMPARE(theme.radius(), 0);
        QVERIFY(write(response, "{\"int\":6}"));
        QTRY_COMPARE(theme.radius(), 6);
    }

    void translatorFallsBackToEnglish()
    {
        QTemporaryDir dir;
        Translator translator(dir.path() + "/language", dir.path());
        QCOMPARE(translator.language(), QString("en"));
        QVERIFY(translator.translate("Main", "Save").isNull());
    }

    void translatorFollowsTheLanguageFile()
    {
        QTemporaryDir dir;
        write(dir.path() + "/language", "pt-BR\n");
        write(dir.path() + "/pt.json", R"({"Save": "Guardar", "Open": "Abrir"})");
        write(dir.path() + "/pt-BR.json", R"({"Save": "Salvar"})");

        Translator translator(dir.path() + "/language", dir.path());
        QCOMPARE(translator.language(), QString("pt-BR"));
        QCOMPARE(translator.translate("Main", "Save"), QString("Salvar"));
        QCOMPARE(translator.translate("Main", "Open"), QString("Abrir"));
        QVERIFY(translator.translate("Main", "Quit").isNull());
    }

    void translatorPicksPluralForms()
    {
        QTemporaryDir dir;
        write(dir.path() + "/language", "ru\n");
        write(dir.path() + "/en.json", R"({"%n clips": {"one": "%n clip", "other": "%n clips"}})");
        write(dir.path() + "/ru.json", R"({"%n clips": {"one": "%n клип", "few": "%n клипа", "many": "%n клипов", "other": "%n клипа"}})");

        Translator translator(dir.path() + "/language", dir.path());
        QCOMPARE(translator.translate("Main", "%n clips", nullptr, 21), QString("%n клип"));
        QCOMPARE(translator.translate("Main", "%n clips", nullptr, 22), QString("%n клипа"));
        QCOMPARE(translator.translate("Main", "%n clips", nullptr, 25), QString("%n клипов"));
        QCOMPARE(Translator::pluralCategory("ar", 11), QString("many"));
        QCOMPARE(Translator::pluralCategory("ja", 1), QString("other"));
    }

    // ---------- Backend ----------

    void settingsMergeOverDefaults()
    {
        QTemporaryDir dir;
        write(dir.path() + "/defaults.json", R"({"snapping": {"edges": true, "corners": true}, "taskbar": {"style": "windows11"}})");
        write(dir.path() + "/settings.json", R"({"snapping": {"edges": false}})");
        Backend backend(dir.path() + "/settings.json", dir.path() + "/defaults.json", fakeApply(dir));
        QCOMPARE(backend.value("snapping.edges"), QVariant(false));
        QCOMPARE(backend.value("snapping.corners"), QVariant(true));
        QCOMPARE(backend.value("taskbar.style"), QVariant("windows11"));
        QVERIFY(!backend.value("nothing.here").isValid());
    }

    void changesWriteOnlyTheUsersChoicesAndApply()
    {
        QTemporaryDir dir;
        write(dir.path() + "/defaults.json", R"({"snapping": {"edges": true, "corners": true}})");
        Backend backend(dir.path() + "/settings.json", dir.path() + "/defaults.json", fakeApply(dir));
        backend.setValue("snapping.corners", false);
        QCOMPARE(backend.value("snapping.corners"), QVariant(false));
        QCOMPARE(read(dir.path() + "/settings.json"), QJsonObject({{"snapping", QJsonObject({{"corners", false}})}}));
        // The change settles, then `omarchy-windows-like apply` runs.
        QTRY_COMPARE(read(dir.path() + "/applied.txt", true).value("args").toString(), QString("apply"));
        QTRY_COMPARE(backend.status(), QString("Saved and applied"));
        QVERIFY(backend.error().isEmpty());
    }

    void aFailedApplyIsReported()
    {
        QTemporaryDir dir;
        write(dir.path() + "/defaults.json", R"({"a": {"b": true}})");
        const QString failing = dir.filePath("failing");
        write(failing, "#!/bin/sh\necho 'jq is required' >&2\nexit 1\n");
        QFile::setPermissions(failing, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        Backend backend(dir.path() + "/settings.json", dir.path() + "/defaults.json", failing);
        backend.setValue("a.b", false);
        QTRY_COMPARE(backend.error(), QString("jq is required"));
    }

    void outsideChangesAreFollowed()
    {
        QTemporaryDir dir;
        write(dir.path() + "/defaults.json", R"({"start": {"pinned": []}})");
        Backend backend(dir.path() + "/settings.json", dir.path() + "/defaults.json", fakeApply(dir));
        QSignalSpy spy(&backend, &Backend::settingsChanged);
        // The Start menu pins an app by writing the file itself.
        write(dir.path() + "/settings.json", R"({"start": {"pinned": ["firefox"]}})");
        QTRY_VERIFY(spy.count() > 0);
        QCOMPARE(backend.value("start.pinned").toStringList(), QStringList{"firefox"});
    }

    void unpinAndResetKeepPins()
    {
        QTemporaryDir dir;
        write(dir.path() + "/defaults.json", R"({"taskbar": {"pinned": [], "style": "windows11"}, "snapping": {"edges": true}})");
        write(dir.path() + "/settings.json", R"({"taskbar": {"pinned": ["a", "b"], "style": "classic"}, "snapping": {"edges": false}})");
        Backend backend(dir.path() + "/settings.json", dir.path() + "/defaults.json", fakeApply(dir));
        backend.removeFromList("taskbar.pinned", "a");
        QCOMPARE(backend.value("taskbar.pinned").toStringList(), QStringList{"b"});
        backend.resetToDefaults();
        QCOMPARE(backend.value("taskbar.style"), QVariant("windows11"));
        QCOMPARE(backend.value("snapping.edges"), QVariant(true));
        QCOMPARE(backend.value("taskbar.pinned").toStringList(), QStringList{"b"});
    }

    void missingInstallIsSaid()
    {
        QTemporaryDir dir;
        Backend backend(dir.path() + "/settings.json", dir.path() + "/nowhere.json", fakeApply(dir));
        QVERIFY(!backend.installed());
        QVERIFY(!backend.error().isEmpty());
    }

    void theRealDefaultsAreValid()
    {
        // config/defaults.json in this repository: every switch the app shows exists.
        const QJsonObject defaults = read(QStringLiteral(SRCDIR "/../../config/defaults.json"));
        for (const QString path : {"taskbar.enabled", "taskbar.style", "taskbar.position", "taskbar.height",
                                   "taskbar.showWorkspaces", "taskbar.showLabels", "start.superOpens", "start.showRecent",
                                   "start.showRecentlyInstalled", "snapping.edges", "snapping.corners", "snapping.fillSpace", "snapping.topMaximizes",
                                   "snapping.picker", "snapping.assist", "snapping.stretch", "snapping.restoreSize",
                                   "resizing.sides", "tabs.enabled", "tabs.terminalShortcuts", "tabs.terminalNames",
                                   "general.floatingDefault", "general.superZ"})
            QVERIFY2(!Backend::valueAt(defaults, path).isUndefined(), qPrintable(path));
    }

private:
    // A stand-in for `omarchy-windows-like` that records how it was run.
    static QString fakeApply(const QTemporaryDir &dir)
    {
        const QString path = dir.filePath("apply");
        write(path, ("#!/bin/sh\nprintf '{\"args\": \"%s\"}' \"$*\" > '" + dir.filePath("applied.txt") + "'\n").toUtf8());
        QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        return path;
    }

    static QJsonObject read(const QString &path, bool quiet = false)
    {
        QFile file(path);
        if (!file.open(QIODevice::ReadOnly)) {
            if (!quiet)
                qWarning() << "can't read" << path;
            return {};
        }
        return QJsonDocument::fromJson(file.readAll()).object();
    }
    static void write(const QString &path, const QByteArray &contents)
    {
        QFile file(path);
        QVERIFY(file.open(QIODevice::WriteOnly));
        file.write(contents);
    }
};

QTEST_MAIN(WindowsLikeSettingsTests)
#include "windows-like-settings_tests.moc"
