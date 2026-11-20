#include <QDir>
#include <QFile>
#include <QTemporaryDir>
#include <QtTest>

#include <QJsonDocument>
#include <QJsonObject>
#include <QQmlApplicationEngine>
#include <QQmlContext>
#include <QQmlExpression>
#include <QQuickStyle>
#include <QSignalSpy>
#include <QtQml>

#include "backend.h"
#include "drives.h"
#include "monitors.h"
#include "theme.h"
#include "translator.h"

// `lsblk -J -b -o …` for a made-up PC (data/lsblk.json): LUKS btrfs root with
// subvolumes, an EFI /boot, Windows partitions, LVM, a two-disk btrfs, zram, a
// loop device, a USB stick, a locked USB drive, an SD card and an empty card
// reader.
static QByteArray cannedLsblk()
{
    QFile file(QStringLiteral(SRCDIR "/data/lsblk.json"));
    return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
}

class WindowsLikeSettingsTests : public QObject {
    Q_OBJECT

private slots:
    // The windows below are Material, like the app; this must come first.
    void initTestCase() { QQuickStyle::setStyle("Material"); }

    void themeFallsBack()
    {
        QTemporaryDir dir;
        Theme theme(dir.path());
        QCOMPARE(theme.accent(), QString("#FFD60A"));
        QCOMPARE(theme.accentForeground(), QString("black"));
        QVERIFY(theme.dark());
        QCOMPARE(theme.window(), QString("#151517"));
        QCOMPARE(theme.card(), QString("#1c1c1f"));
    }

    void themeReadsThePalette()
    {
        QTemporaryDir dir;
        QDir(dir.path()).mkpath("theme");
        write(dir.path() + "/theme/colors.toml", "mode = \"light\"\naccent = \"#1e66f5\"\n"
                                                 "background = \"#eff1f5\"\ndark_background = \"#e3e4e8\"\n"
                                                 "foreground = \"#4c4f69\"\nred = 'nope'\n");
        Theme theme(dir.path());
        QVERIFY(!theme.dark());
        QCOMPARE(theme.card(), QString("#eff1f5"));
        QCOMPARE(theme.window(), QString("#e3e4e8"));
        QCOMPARE(theme.foreground(), QString("#4c4f69"));
        // Not a color: the fallback.
        QCOMPARE(theme.danger(), QString("#ff6b6b"));
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
                                   "taskbar.showWorkspaces", "taskbar.showDesktops", "taskbar.showLabels", "start.superOpens", "start.showRecent",
                                   "start.showRecentlyInstalled", "snapping.edges", "snapping.corners", "snapping.fillSpace", "snapping.topMaximizes",
                                   "snapping.picker", "snapping.assist", "snapping.stretch", "snapping.restoreSize", "snapping.gaps",
                                   "resizing.sides", "resizing.joint", "tabs.enabled", "tabs.terminalShortcuts", "tabs.terminalNames",
                                   "general.floatingDefault", "general.superZ", "animations.enabled"})
            QVERIFY2(!Backend::valueAt(defaults, path).isUndefined(), qPrintable(path));
    }

    // ---------- Monitors ----------

    void monitorsAreSummedUp()
    {
        const QVariantList list = Monitors::parse(R"([
            {"id": 0, "name": "DP-2", "description": "Samsung Electric Company Odyssey G95NC HNTWB00286",
             "make": "Samsung Electric Company", "model": "Odyssey G95NC", "width": 7680, "height": 2160,
             "refreshRate": 239.99001, "x": 0, "y": 0, "scale": 1.5, "transform": 0, "focused": true,
             "disabled": false, "mirrorOf": "none"},
            {"name": "eDP-1", "description": "BOE 0x0BCA", "make": "BOE", "model": "0x0BCA", "width": 2880,
             "height": 1800, "refreshRate": 120.0, "x": 5120, "y": 0, "scale": 2, "transform": 1,
             "disabled": false, "mirrorOf": "0"},
            {"name": "HEADLESS-1", "description": "", "width": 1920, "height": 1080, "refreshRate": 60,
             "scale": 0, "disabled": true},
            {"description": "no name, so not a monitor"}
        ])");
        QCOMPARE(list.size(), 3);
        const QVariantMap big = list[0].toMap(), laptop = list[1].toMap(), headless = list[2].toMap();
        QCOMPARE(big.value("label").toString(), QString("Odyssey G95NC"));
        QCOMPARE(big.value("refreshRate").toDouble(), 239.99);
        QCOMPARE(big.value("scalePercent").toInt(), 150);
        QCOMPARE(big.value("logicalWidth").toInt(), 5120);
        QCOMPARE(big.value("mirrorOf").toString(), QString());
        QVERIFY(big.value("focused").toBool());
        // Built in, turned a quarter, and mirroring the other one (which
        // Hyprland names by its id).
        QCOMPARE(laptop.value("label").toString(), QString("Built-in display"));
        QVERIFY(laptop.value("builtIn").toBool());
        QCOMPARE(laptop.value("logicalWidth").toInt(), 900);
        QCOMPARE(laptop.value("logicalHeight").toInt(), 1440);
        QCOMPARE(laptop.value("mirrorOf").toString(), QString("DP-2"));
        // No model or description: its connector, and no scale is 100 %.
        QCOMPARE(headless.value("label").toString(), QString("HEADLESS-1"));
        QCOMPARE(headless.value("scalePercent").toInt(), 100);
        QVERIFY(headless.value("disabled").toBool());
        // Rules are for the description, which follows a display between ports.
        QCOMPARE(big.value("output").toString(), QString("desc:Samsung Electric Company Odyssey G95NC HNTWB00286"));
        QCOMPARE(headless.value("output").toString(), QString("HEADLESS-1"));

        QVERIFY(Monitors::parse("not json").isEmpty());
        QVERIFY(Monitors::parse("{\"name\": \"DP-1\"}").isEmpty());
    }

    void monitorsAskHyprland()
    {
        QTemporaryDir dir;
        const QString hyprctl = script(dir, "hyprctl", "echo \"$*\" > '" + dir.filePath("args.txt") + "'\n"
                                       "echo '[{\"name\": \"DP-1\", \"model\": \"U2720Q\", \"width\": 3840, "
                                       "\"height\": 2160, \"refreshRate\": 59.997, \"scale\": 1.5}]'\n");
        Monitors monitors(hyprctl, dir.filePath("monitors.lua"));
        QTRY_VERIFY(monitors.available());
        QCOMPARE(monitors.monitors().size(), 1);
        QCOMPARE(monitors.monitors()[0].toMap().value("label").toString(), QString("U2720Q"));
        QCOMPARE(monitors.monitors()[0].toMap().value("refreshRate").toDouble(), 60.0);
        QVERIFY(monitors.error().isEmpty());
        QFile args(dir.filePath("args.txt"));
        QVERIFY(args.open(QIODevice::ReadOnly));
        QCOMPARE(args.readAll().trimmed(), QByteArray("monitors all -j"));
    }

    void monitorsSayWhenHyprlandDoesntAnswer()
    {
        QTemporaryDir dir;
        Monitors monitors(script(dir, "hyprctl", "echo 'HYPRLAND_INSTANCE_SIGNATURE not set' >&2\nexit 1\n"),
                          dir.filePath("monitors.lua"));
        QTRY_VERIFY(!monitors.error().isEmpty());
        QVERIFY(!monitors.available());
        QVERIFY(monitors.monitors().isEmpty());
    }

    void modesAndColorAreRead()
    {
        const QVariantList list = Monitors::parse(R"([
            {"name": "DP-1", "description": "Dell U2720Q", "width": 3840, "height": 2160, "refreshRate": 59.997,
             "scale": 1.5, "vrr": false, "currentFormat": "XRGB2101010", "colorManagementPreset": "hdr",
             "sdrBrightness": 1.2, "sdrSaturation": 1.05, "physicalWidth": 600, "physicalHeight": 340,
             "availableModes": ["1920x1080@60.00Hz", "3840x2160@60.00Hz", "3840x2160@30.00Hz", "1920x1080@60.00Hz"]},
            {"name": "DP-2", "description": "LG 27GP850", "disabled": true, "width": 0, "height": 0,
             "availableModes": ["2560x1440@165.00Hz", "2560x1440@60.00Hz"]}
        ])", Monitors::savedRules(R"(
-- BEGIN Displays
hl.monitor({ output = "desc:Dell U2720Q", mode = "3840x2160@60.00", position = "0x0", scale = 1.5, vrr = 2, bitdepth = 10, cm = "hdredid", sdrbrightness = 1.2, sdrsaturation = 1.05 })
hl.monitor({ output = "desc:LG 27GP850", mode = "2560x1440@60.00", position = "2560x0", scale = 1, transform = 1 })
-- END Displays
)"));
        QCOMPARE(list.size(), 2);
        const QVariantMap dell = list[0].toMap(), lg = list[1].toMap();
        // Each mode once, biggest and fastest first.
        QCOMPARE(dell.value("modes").toList().size(), 3);
        QCOMPARE(dell.value("modes").toList()[0].toMap().value("width").toInt(), 3840);
        QCOMPARE(dell.value("modes").toList()[0].toMap().value("refresh").toDouble(), 60.0);
        QCOMPARE(dell.value("modes").toList()[1].toMap().value("refresh").toDouble(), 30.0);
        QCOMPARE(dell.value("bitdepth").toInt(), 10);
        // What Hyprland doesn't say comes from the saved rule: VRR for
        // fullscreen only, and HDR from the display's own data.
        const QVariantMap c = dell.value("config").toMap();
        QCOMPARE(c.value("vrr").toInt(), 2);
        QCOMPARE(c.value("cm").toString(), QString("hdredid"));
        QCOMPARE(c.value("sdrBrightness").toDouble(), 1.2);
        // Off, it remembers how it was last set up.
        const QVariantMap off = lg.value("config").toMap();
        QVERIFY(!off.value("enabled").toBool());
        QCOMPARE(off.value("width").toInt(), 2560);
        QCOMPARE(off.value("refresh").toDouble(), 60.0);
        QCOMPARE(off.value("x").toInt(), 2560);
        QCOMPARE(off.value("transform").toInt(), 1);
    }

    void rulesSayWhatIsSet()
    {
        QVariantMap c{{"output", "desc:Dell U2720Q"}, {"name", "DP-1"}, {"enabled", true}, {"width", 3840},
                      {"height", 2160}, {"refresh", 59.997}, {"x", -1920}, {"y", 0}, {"scale", 1.5},
                      {"transform", 1}, {"mirror", ""}, {"vrr", 2}, {"bitdepth", 10}, {"cm", "hdr"},
                      {"sdrBrightness", 1.25}, {"sdrSaturation", 1.0}};
        QCOMPARE(Monitors::rule(c), QString("hl.monitor({ output = \"desc:Dell U2720Q\", disabled = false, "
                                            "mode = \"3840x2160@60.00\", position = \"-1920x0\", scale = 1.5, transform = 1, "
                                            "mirror = \"\", vrr = 2, bitdepth = 10, cm = \"hdr\", sdrbrightness = 1.25, "
                                            "sdrsaturation = 1 })"));
        // Every field is said, as Hyprland keeps any left out from the rule before.
        c["cm"] = "";
        c["bitdepth"] = 8;
        c["transform"] = 0;
        c["mirror"] = "DP-2";
        QCOMPARE(Monitors::rule(c), QString("hl.monitor({ output = \"desc:Dell U2720Q\", disabled = false, "
                                            "mode = \"3840x2160@60.00\", position = \"-1920x0\", scale = 1.5, transform = 0, "
                                            "mirror = \"DP-2\", vrr = 2, bitdepth = 8, cm = \"auto\", sdrbrightness = 1.25, "
                                            "sdrsaturation = 1 })"));
        c["enabled"] = false;
        QCOMPARE(Monitors::rule(c), QString("hl.monitor({ output = \"desc:Dell U2720Q\", disabled = true })"));
        // Quotes in a description can't end the string.
        c["output"] = "desc:Odd \"name\"";
        QVERIFY(Monitors::rule(c).contains("output = \"desc:Odd \\\"name\\\"\""));
    }

    void theDisplaysBlockKeepsTheRest()
    {
        const QString file = "local scale = 1.5\n"
                             "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = scale })\n"
                             "-- BEGIN Displays (written by the Displays app: Setup > Display in the Omarchy menu)\n"
                             "-- Changes here are overwritten the next time Displays saves.\n"
                             "hl.monitor({ output = \"desc:A\", mode = \"1920x1080@60.00\", position = \"0x0\", scale = 1 })\n"
                             "hl.monitor({ output = \"desc:B\", mode = \"2560x1440@60.00\", position = \"1920x0\", scale = 1 })\n"
                             "-- END Displays\n"
                             "hl.env(\"GDK_SCALE\", \"2\")\n";
        const QString after = Monitors::withRules(file, {{"desc:B", "hl.monitor({ output = \"desc:B\", disabled = true })"},
                                                         {"C-1", "hl.monitor({ output = \"C-1\", mode = \"preferred\" })"}});
        // B is replaced where it was, C is added, and A and everything around stay.
        QCOMPARE(after, QString("local scale = 1.5\n"
                                "hl.monitor({ output = \"\", mode = \"preferred\", position = \"auto\", scale = scale })\n"
                                "-- BEGIN Displays (written by the Displays app: Setup > Display in the Omarchy menu)\n"
                                "-- Changes here are overwritten the next time Displays saves.\n"
                                "hl.monitor({ output = \"desc:A\", mode = \"1920x1080@60.00\", position = \"0x0\", scale = 1 })\n"
                                "hl.monitor({ output = \"desc:B\", disabled = true })\n"
                                "hl.monitor({ output = \"C-1\", mode = \"preferred\" })\n"
                                "-- END Displays\n"
                                "hl.env(\"GDK_SCALE\", \"2\")\n"));
        QCOMPARE(Monitors::savedRules(after).value("desc:B").value("disabled").toString(), QString("true"));
        // Rules outside the block aren't the block's.
        QVERIFY(!Monitors::savedRules(after).contains(""));

        // A file without the block gets one at the end.
        const QString fresh = Monitors::withRules("hl.monitor({ output = \"\", mode = \"preferred\" })", {{"DP-1", "hl.monitor({ output = \"DP-1\", disabled = true })"}});
        QVERIFY(fresh.startsWith("hl.monitor({ output = \"\", mode = \"preferred\" })\n\n-- BEGIN Displays"));
        QVERIFY(fresh.endsWith("hl.monitor({ output = \"DP-1\", disabled = true })\n-- END Displays\n"));
        QCOMPARE(Monitors::savedRules(fresh).size(), 1);
    }

    void changesAreTriedThenKeptOrPutBack()
    {
        QTemporaryDir dir;
        const QString log = dir.filePath("log.txt");
        // hyprctl: every call logged; the monitors as they were.
        const QString hyprctl = script(dir, "hyprctl",
            "printf '%s\\n' \"$*\" >> '" + log + "'\n"
            "case \"$1\" in\n"
            "  monitors) echo '[{\"name\": \"DP-1\", \"description\": \"Dell\", \"width\": 1920, \"height\": 1080, "
            "\"refreshRate\": 60, \"scale\": 1, \"availableModes\": [\"1920x1080@60.00Hz\", \"1280x720@60.00Hz\"]}]' ;;\n"
            "  eval) echo ok ;;\n"
            "  reload) echo ok ;;\n"
            "esac\n");
        const QString lua = dir.filePath("monitors.lua");
        write(lua, "hl.monitor({ output = \"\", mode = \"preferred\" })\n");
        Monitors monitors(hyprctl, lua);
        QTRY_VERIFY(monitors.available());
        auto lines = [&] { return QString::fromUtf8(readBytes(log)).trimmed().split('\n'); };
        // The rules run, without the asking for monitors in between.
        auto evals = [&] { return lines().filter(QRegularExpression("^eval ")); };
        QVariantMap c = monitors.monitors()[0].toMap().value("config").toMap();
        const QString before = Monitors::rule(c);
        c["width"] = 1280;
        c["height"] = 720;

        // Tried, and waiting: nothing saved yet.
        QVERIFY(monitors.apply({c}, true));
        QVERIFY(monitors.confirming());
        QCOMPARE(monitors.secondsLeft(), 15);
        QVERIFY(lines().contains("eval " + Monitors::rule(c)));
        QVERIFY(!QString::fromUtf8(readBytes(lua)).contains("1280x720"));
        // Put back: the rule from before runs, still nothing saved.
        monitors.revert();
        QVERIFY(!monitors.confirming());
        QCOMPARE(evals().last(), "eval " + before);
        QVERIFY(!QString::fromUtf8(readBytes(lua)).contains("1280x720"));

        // Kept: saved in the block, with a copy of the file first. Hyprland
        // isn't made to reload, which would undo other live changes.
        QVERIFY(monitors.apply({c}, true));
        monitors.keep();
        QVERIFY(!monitors.confirming());
        QVERIFY(QString::fromUtf8(readBytes(lua)).contains("-- BEGIN Displays"));
        QVERIFY(QString::fromUtf8(readBytes(lua)).contains(Monitors::rule(c)));
        QVERIFY(QString::fromUtf8(readBytes(lua)).startsWith("hl.monitor({ output = \"\", mode = \"preferred\" })\n"));
        QCOMPARE(QDir(dir.path()).entryList({"monitors.lua.bak.*"}).size(), 1);
        QVERIFY(!lines().contains("reload"));

        // Not answered in time, it goes back by itself (to what the fake
        // Hyprland still says it has).
        monitors.confirmSeconds = 1;
        c["refresh"] = 75;
        QVERIFY(monitors.apply({c}, true));
        QCOMPARE(evals().last(), "eval " + Monitors::rule(c));
        QTRY_VERIFY_WITH_TIMEOUT(!monitors.confirming(), 3000);
        QCOMPARE(evals().last(), "eval " + before);

        // Hyprland refusing: said, and put back.
        const QString refusing = script(dir, "hyprctl-refusing",
            "case \"$1\" in monitors) echo '[{\"name\": \"DP-1\", \"width\": 1920, \"height\": 1080}]' ;; "
            "eval) echo 'error: bad mode' ;; esac\n");
        Monitors stubborn(refusing, lua);
        QTRY_VERIFY(stubborn.available());
        QVERIFY(!stubborn.apply({c}, true));
        QVERIFY(!stubborn.confirming());
        QVERIFY(stubborn.applyError().contains("bad mode"));
    }

    void displaysLineUpLikeWindows()
    {
        // DisplayLayout.js, as the page runs it.
        QString code = QString::fromUtf8(readBytes(QStringLiteral(SRCDIR "/../src/DisplayLayout.js")));
        code.remove(".pragma library");
        QJSEngine js;
        const QJSValue loaded = js.evaluate(code);
        QVERIFY2(!loaded.isError(), qPrintable(loaded.toString()));
        auto run = [&](const QString &expr) {
            const QJSValue v = js.evaluate(expr);
            if (v.isError())
                qWarning() << v.toString();
            return v;
        };
        run(R"(
            var mk = (name, x, w, h, extra) => ({ name: name, config: Object.assign({ output: name, name: name,
                enabled: true, width: w, height: h, refresh: 60, x: x, y: 0, scale: 1, transform: 0, mirror: "",
                vrr: 0, bitdepth: 8, cm: "auto" }, extra || {}) });
            var three = [mk("A", 0, 1920, 1080), mk("B", 1920, 2560, 1440), mk("C", 4480, 1920, 1080, { enabled: false })];
        )");
        // A display that gets bigger pushes the one to its right along.
        QCOMPARE(run("JSON.stringify(change(three, 'A', { width: 2560, height: 1440 }).map(c => [c.name, c.x]))").toString(),
                 QString("[[\"A\",0],[\"B\",2560]]"));
        // Turned a quarter, it stands upright and B moves in.
        QCOMPARE(run("change(three, 'A', { transform: 1 }).find(c => c.name === 'B').x").toInt(), 1080);
        // Dropped over B's right half, A lands against its right side, lined
        // up with its top; dropped high on the left, above it.
        QCOMPARE(run("JSON.stringify(snap(configsOf(three), 'A', 4000, 40))").toString(), QString("{\"x\":4480,\"y\":0}"));
        QCOMPARE(run("JSON.stringify(snap(configsOf(three), 'A', 2200, -700))").toString(), QString("{\"x\":2200,\"y\":-1080}"));
        // Low on its left, A lines up with B's bottom edge.
        QCOMPARE(run("JSON.stringify(snap(configsOf(three), 'A', -1500, 300))").toString(), QString("{\"x\":0,\"y\":360}"));
        // Moved to the right of B, everything shifts so the left edge is 0 again.
        QCOMPARE(run("JSON.stringify(move(three, 'A', 4000, 0).map(c => [c.name, c.x]))").toString(),
                 QString("[[\"A\",2560],[\"B\",0]]"));
        // Dropped where it already was, nothing changes.
        QCOMPARE(run("move(three, 'A', -300, 0).length").toInt(), 0);
        // Turning C on puts it to the right of the rest.
        QCOMPARE(run("JSON.stringify(extend(three, 'C').map(c => [c.name, c.enabled, c.x]))").toString(),
                 QString("[[\"C\",true,4480]]"));
        // Duplicating: B shows A's picture; turning A off: B moves into its
        // place. Either way no gap is left.
        QCOMPARE(run("duplicate(three, 'B', 'A')[0].mirror").toString(), QString("A"));
        run("var four = three.concat([mk('D', 4480, 1920, 1080)])");
        QCOMPARE(run("JSON.stringify(duplicate(four, 'B', 'A').map(c => [c.name, c.x]))").toString(),
                 QString("[[\"B\",1920],[\"D\",1920]]"));
        QCOMPARE(run("JSON.stringify(disconnect(four, 'A').map(c => [c.name, c.enabled, c.x]))").toString(),
                 QString("[[\"A\",false,0],[\"B\",true,0],[\"D\",true,2560]]"));
        // Only one on.
        QCOMPARE(run("JSON.stringify(showOnly(three, 'B').map(c => [c.name, c.enabled, c.x]))").toString(),
                 QString("[[\"A\",false,0],[\"B\",true,0]]"));
        // Never the last one off.
        QCOMPARE(run("disconnect([three[0]], 'A').length").toInt(), 0);
        QCOMPARE(run("disconnect(three, 'A')[0].enabled").toBool(), false);
        // What it offers, and what Windows would suggest.
        QCOMPARE(run("closestRate([{width: 2560, height: 1440, refresh: 165}, {width: 2560, height: 1440, refresh: 60}], 2560, 1440, 144)").toNumber(), 165.0);
        QCOMPARE(run("recommendedScale({ physicalWidth: 600, width: 3840, transform: 0, modes: [{ width: 3840, height: 2160 }] })").toNumber(), 1.75);
        QVERIFY(run("recommendedScale({ physicalWidth: 0, width: 1920 })").isNull());
    }

    // ---------- The window ----------

    void theWindowLoadsAndFindsSettings()
    {
        QTemporaryDir dir;
        write(dir.path() + "/defaults.json", readBytes(QStringLiteral(SRCDIR "/../../config/defaults.json")));
        Translator translator(dir.path() + "/language", ":/i18n");
        Theme theme(dir.path());
        Backend backend(dir.path() + "/settings.json", dir.path() + "/defaults.json", fakeApply(dir));
        Monitors monitors(script(dir, "hyprctl", "echo '[{\"name\": \"DP-1\", \"width\": 1920, \"height\": 1080}]'\n"),
                          dir.filePath("monitors.lua"));
        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty("translator", &translator);
        engine.rootContext()->setContextProperty("theme", &theme);
        engine.rootContext()->setContextProperty("backend", &backend);
        engine.rootContext()->setContextProperty("monitors", &monitors);
        engine.load(QUrl("qrc:/Main.qml"));
        QCOMPARE(engine.rootObjects().size(), 1);
        QObject *window = engine.rootObjects().first();
        auto eval = [&](const QString &js) { return QQmlExpression(qmlContext(window), window, js).evaluate(); };

        QCOMPARE(window->property("title").toString(), QString("Settings"));
        QCOMPARE(window->property("categoryId").toString(), QString("display"));
        // Each category, and each page under Package, opens.
        for (const QString page : {"package", "package/taskbar", "package/snapping", "package/windows", "display"}) {
            eval("go('" + page + "')");
            QCOMPARE(window->property("pageId").toString(), page);
        }
        QVERIFY(eval("canGoBack").toBool());
        eval("back()");
        QCOMPARE(window->property("pageId").toString(), QString("package/windows"));
        QCOMPARE(window->property("categoryId").toString(), QString("package"));

        // Search finds cards on pages that aren't showing, display settings too.
        QCOMPARE(eval("search('corner').map(r => r.page.pageId).join()").toString(), QString("package/snapping"));
        QCOMPARE(eval("search('animation').map(r => r.item.path).join()").toString(), QString("animations.enabled"));
        QCOMPARE(eval("search('motion')[0].page.pageId").toString(), QString("package/windows"));
        // Like every switch, it comes from the defaults and is saved by path.
        QCOMPARE(backend.value("animations.enabled"), QVariant(true));
        eval("search('animation')[0].item.clicked()");
        QCOMPARE(backend.value("animations.enabled"), QVariant(false));
        QCOMPARE(read(dir.path() + "/settings.json"), QJsonObject({{"animations", QJsonObject({{"enabled", false}})}}));
        QCOMPARE(eval("search('Snapping')[0].item === null").toBool(), true);
        QTRY_COMPARE(eval("findPage('display').list.length").toInt(), 1);
        QCOMPARE(eval("search('resolution')[0].page.pageId").toString(), QString("display"));
        QCOMPARE(eval("search('refresh rate')[0].item.title").toString(), QString("Choose a refresh rate"));
        // One display: nothing to duplicate or extend to.
        QCOMPARE(eval("search('duplicate').length").toInt(), 0);
    }

    // ---------- This PC ----------

    void sizesReadLikeWindows()
    {
        QLocale::setDefault(QLocale(QLocale::English, QLocale::UnitedStates));
        QCOMPARE(Drives::formatSize(0), QString("0 bytes"));
        QCOMPARE(Drives::formatSize(1023), QString("1,023 bytes"));
        QCOMPARE(Drives::formatSize(1536), QString("1.5 KB"));
        QCOMPARE(Drives::formatSize(10LL << 30), QString("10 GB"));
        QCOMPARE(Drives::formatSize(40451080192LL), QString("37.7 GB"));
        QCOMPARE(Drives::formatSize(123LL << 30), QString("123 GB"));
        QCOMPARE(Drives::formatSize(4000785100800LL), QString("3.64 TB"));
        QCOMPARE(Drives::formatSize(1000LL << 20), QString("0.98 GB"));
    }

    void drivesWorthShowing()
    {
        const QVariantList drives = Drives::parseDrives(cannedLsblk());
        QStringList titles;
        for (const auto &d : drives)
            titles << d.toMap().value("title").toString();
        // Not shown: swap on zram, a loop device, an empty card reader, the
        // EFI, Microsoft reserved and recovery partitions, /boot, LVM and
        // LUKS containers, and the second device of a two-disk btrfs.
        QCOMPARE(titles, QStringList({"System (/)", "Data Drive (/mnt/data)", "Local Disk (/srv)", "Pool (/mnt/pool)",
                                      "Local Disk", "USB Drive (/run/media/me/USB)", "USB Drive", "CARD (/run/media/me/CARD)"}));

        const QVariantMap system = drives[0].toMap();
        QCOMPARE(system.value("kind").toString(), QString("system"));
        QCOMPARE(system.value("device").toString(), QString("/dev/mapper/root"));
        QCOMPARE(system.value("cryptDevice").toString(), QString("/dev/nvme1n1p2"));
        QCOMPARE(system.value("mountPoints").toStringList(), QStringList({"/", "/home", "/var/log"}));
        QCOMPARE(system.value("model").toString(), QString("Fast SSD"));
        QCOMPARE(system.value("usedFraction").toDouble(), 0.2);
        QVERIFY(!system.value("nearlyFull").toBool());

        // 91 % full: the bar turns red.
        const QVariantMap data = drives[1].toMap();
        QCOMPARE(data.value("kind").toString(), QString("drive"));
        QVERIFY(data.value("nearlyFull").toBool());
        QCOMPARE(data.value("freeText").toString(), QString("90 GB"));
        QCOMPARE(data.value("sizeText").toString(), QString("0.98 TB"));

        // Not mounted: its size, no bar; Open mounts it.
        const QVariantMap unmounted = drives[4].toMap();
        QVERIFY(!unmounted.value("mounted").toBool());
        QVERIFY(!unmounted.value("hasUsage").toBool());
        QCOMPARE(unmounted.value("device").toString(), QString("/dev/nvme0n1p5"));

        const QVariantMap usb = drives[5].toMap();
        QCOMPARE(usb.value("kind").toString(), QString("usb"));
        QVERIFY(usb.value("removable").toBool());
        QCOMPARE(usb.value("diskDevice").toString(), QString("/dev/sda"));
        // Encrypted and locked.
        const QVariantMap locked = drives[6].toMap();
        QVERIFY(locked.value("locked").toBool());
        QCOMPARE(locked.value("kind").toString(), QString("usb"));
        QCOMPARE(drives[7].toMap().value("kind").toString(), QString("sdcard"));

        QVERIFY(Drives::parseDrives("garbage").isEmpty());
    }

    void networkLocations()
    {
        // Kernel network mounts among others, as `findmnt -J -b` lists them.
        const QVariantList mounts = Drives::parseNetworkMounts(readBytes(QStringLiteral(SRCDIR "/data/findmnt.json")));
        QCOMPARE(mounts.size(), 3);
        QStringList titles;
        for (const auto &m : mounts)
            titles << m.toMap().value("title").toString();
        QCOMPARE(titles, QStringList({"files (/home/me/remote)", "games (/mnt/games)", "media (/mnt/media)"}));
        const QVariantMap games = mounts[1].toMap();
        QCOMPARE(games.value("host").toString(), QString("192.168.1.10"));
        QVERIFY(games.value("nearlyFull").toBool());
        QVERIFY(!mounts[2].toMap().value("hasUsage").toBool());

        const QVariantList gvfs = Drives::parseGvfs({"smb-share:server=nas,share=my%20music", "sftp:host=box,user=me",
                                                     "mtp:host=Google_Pixel_8", "nothing"}, "/run/user/1000/gvfs");
        QCOMPARE(gvfs.size(), 3);
        QVariantMap byKind;
        for (const auto &g : gvfs)
            byKind.insert(g.toMap().value("fstype").toString(), g);
        QCOMPARE(byKind["smb-share"].toMap().value("title").toString(), QString("my music on nas"));
        QCOMPARE(byKind["smb-share"].toMap().value("path").toString(),
                 QString("/run/user/1000/gvfs/smb-share:server=nas,share=my%20music"));
        QCOMPARE(byKind["sftp"].toMap().value("title").toString(), QString("box"));
        QCOMPARE(byKind["mtp"].toMap().value("title").toString(), QString("Google Pixel 8"));
        QCOMPARE(byKind["mtp"].toMap().value("kind").toString(), QString("phone"));
    }

    void userFoldersSkipHome()
    {
        QTemporaryDir dir;
        const QByteArray home = qgetenv("HOME"), config = qgetenv("XDG_CONFIG_HOME");
        qputenv("HOME", dir.path().toUtf8());
        qputenv("XDG_CONFIG_HOME", (dir.path() + "/.config").toUtf8());
        QDir(dir.path()).mkpath(".config");
        QDir(dir.path()).mkpath("Downloads");
        QDir(dir.path()).mkpath("Bilder");
        write(dir.path() + "/.config/user-dirs.dirs", "XDG_DESKTOP_DIR=\"$HOME/\"\nXDG_DOWNLOAD_DIR=\"$HOME/Downloads\"\n"
                                                      "XDG_PICTURES_DIR=\"$HOME/Bilder\"\nXDG_MUSIC_DIR=\"$HOME/Missing\"\n");
        const QVariantList folders = Drives::userFolders();
        qputenv("HOME", home);
        config.isNull() ? qunsetenv("XDG_CONFIG_HOME") : qputenv("XDG_CONFIG_HOME", config);
        QStringList names;
        for (const auto &f : folders)
            names << f.toMap().value("folder").toString() + "=" + f.toMap().value("name").toString();
        QCOMPARE(names, QStringList({"downloads=Downloads", "pictures=Bilder"}));
    }

    void udisksSaysWhereItMounted()
    {
        QCOMPARE(Drives::mountedAt("Mounted /dev/sdc1 at /run/media/me/STICK\n"), QString("/run/media/me/STICK"));
        QCOMPARE(Drives::mountedAt("Mounted /dev/sdc1 at /run/media/me/My Stick.\n"), QString("/run/media/me/My Stick"));
        QVERIFY(Drives::mountedAt("").isEmpty());
    }

    void openingMountsFirstAndEjectingLetsGo()
    {
        QTemporaryDir dir;
        const QString log = dir.filePath("udisks.log"), opened = dir.filePath("opened.log");
        Drives::Tools tools;
        tools.lsblk = script(dir, "lsblk", "cat '" SRCDIR "/data/lsblk.json'\n");
        // A stand-in for udisksctl: never touches a real device.
        tools.udisksctl = script(dir, "udisksctl", "echo \"$*\" >> '" + log + "'\n"
                                 "case \"$1 $3\" in\n"
                                 "  'mount /dev/nvme0n1p5') echo 'Mounted /dev/nvme0n1p5 at " + dir.filePath("mnt") + ".' ;;\n"
                                 "  'mount /dev/sdc1') echo 'Error mounting /dev/sdc1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: wrong fs type' >&2; exit 1 ;;\n"
                                 "esac\n");
        tools.opener = {script(dir, "open", "echo \"$1\" >> '" + opened + "'\n")};
        tools.watch = false;
        Drives drives(tools);
        QTRY_COMPARE(drives.drives().size(), 8);
        const QVariantList list = drives.drives();
        auto lines = [](const QString &path) { return QString::fromUtf8(readBytes(path)).trimmed().split('\n', Qt::SkipEmptyParts); };

        // A mounted drive opens straight away.
        drives.open(list[1].toMap());
        QTRY_COMPARE(lines(opened), QStringList{"/mnt/data"});
        // An unmounted one is mounted, then opened where udisks put it.
        drives.open(list[4].toMap());
        QTRY_COMPARE(lines(opened).size(), 2);
        QCOMPARE(lines(opened).last(), dir.filePath("mnt"));
        QCOMPARE(lines(log).first(), QString("mount -b /dev/nvme0n1p5"));
        QVERIFY(drives.error().isEmpty());

        // A failure says why, without D-Bus's error names.
        QVariantMap broken = list[4].toMap();
        broken["device"] = "/dev/sdc1";
        drives.open(broken);
        QTRY_COMPARE(drives.error(), QString("Error mounting /dev/sdc1: wrong fs type"));
        QVERIFY(!drives.busy());

        // A locked drive isn't mounted.
        const int before = lines(log).size();
        drives.open(list[6].toMap());
        QVERIFY(drives.error().contains("encrypted"));
        QCOMPARE(lines(log).size(), before);

        // Eject: unmount, lock what was unlocked, power the disk off.
        QFile::remove(log);
        QVariantMap stick = list[5].toMap();
        stick["cryptDevice"] = "/dev/sda1";
        stick["device"] = "/dev/mapper/stick";
        drives.eject(stick);
        QTRY_COMPARE(lines(log).size(), 3);
        QCOMPARE(lines(log), QStringList({"unmount -b /dev/mapper/stick", "lock -b /dev/sda1", "power-off -b /dev/sda"}));
    }

    void thisPcLoads()
    {
        QTemporaryDir dir;
        Drives::Tools tools;
        tools.lsblk = script(dir, "lsblk", "cat '" SRCDIR "/data/lsblk.json'\n");
        tools.gvfs = dir.filePath("gvfs");
        QDir().mkpath(tools.gvfs + "/smb-share:server=nas,share=media");
        tools.watch = false;
        Theme theme(dir.path());
        Drives drives(tools);
        QQmlApplicationEngine engine;
        engine.rootContext()->setContextProperty("theme", &theme);
        engine.rootContext()->setContextProperty("drives", &drives);
        engine.load(QUrl("qrc:/ThisPC.qml"));
        QCOMPARE(engine.rootObjects().size(), 1);
        QObject *window = engine.rootObjects().first();
        auto eval = [&](const QString &js) { return QQmlExpression(qmlContext(window), window, js).evaluate(); };
        QCOMPARE(window->property("title").toString(), QString("This PC"));
        // The drives and the share, as tiles, the first one focused.
        QTRY_VERIFY(eval("tiles().filter(t => t.entry.kind !== 'folder').length").toInt() == 9);
        QTRY_VERIFY(eval("tiles()[0].activeFocus").toBool());
        const QString first = eval("tiles()[0].entry.id").toString();
        eval("move(tiles()[0], Qt.Key_Right)");
        QVERIFY(eval("tiles()[1].activeFocus").toBool());
        QCOMPARE(window->property("focusedId").toString(), eval("tiles()[1].entry.id").toString());
        QVERIFY(first != window->property("focusedId").toString());
    }

private:
    static QString script(const QTemporaryDir &dir, const QString &name, const QString &body)
    {
        const QString path = dir.filePath(name);
        write(path, ("#!/bin/sh\n" + body).toUtf8());
        QFile::setPermissions(path, QFile::ReadOwner | QFile::WriteOwner | QFile::ExeOwner);
        return path;
    }

    static QByteArray readBytes(const QString &path)
    {
        QFile file(path);
        return file.open(QIODevice::ReadOnly) ? file.readAll() : QByteArray();
    }

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
