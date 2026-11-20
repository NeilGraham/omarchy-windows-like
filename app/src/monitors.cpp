#include "monitors.h"

#include <QDateTime>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QRegularExpression>
#include <QSaveFile>
#include <QSet>
#include <QStandardPaths>
#include <algorithm>
#include <cmath>

namespace {

const QString BlockBegin = QStringLiteral("-- BEGIN Displays");
const QString BlockEnd = QStringLiteral("-- END Displays");

QString luaString(const QString &value) {
    QString escaped = value;
    escaped.replace("\\", "\\\\").replace("\"", "\\\"");
    return "\"" + escaped + "\"";
}

// 1.5, not 1.500000; 1.25, not 1.25000001.
QString number(double value, int digits = 4) {
    QString text = QString::number(value, 'f', digits);
    if (text.contains('.')) {
        while (text.endsWith('0'))
            text.chop(1);
        if (text.endsWith('.'))
            text.chop(1);
    }
    return text;
}

// "1920x1080@60.00Hz", or a rule's "1920x1080@60" -> width, height, refresh.
bool parseMode(const QString &text, int &width, int &height, double &refresh) {
    static const QRegularExpression re(QStringLiteral("^\\s*(\\d+)x(\\d+)(?:@([0-9.]+))?\\s*(?:Hz)?\\s*$"));
    const auto m = re.match(text);
    if (!m.hasMatch())
        return false;
    width = m.captured(1).toInt();
    height = m.captured(2).toInt();
    refresh = m.captured(3).isEmpty() ? 0 : m.captured(3).toDouble();
    return width > 0 && height > 0;
}

// The fields of a line `hl.monitor({ output = "DP-1", mode = "…", vrr = 1 })`.
QVariantMap ruleFields(const QString &line) {
    static const QRegularExpression call(QStringLiteral("hl\\.monitor\\(\\s*\\{(.*)\\}\\s*\\)"));
    static const QRegularExpression field(QStringLiteral("([A-Za-z_]+)\\s*=\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|[^,}]+)"));
    QVariantMap out;
    const auto m = call.match(line);
    if (!m.hasMatch())
        return out;
    auto it = field.globalMatch(m.captured(1));
    while (it.hasNext()) {
        const auto f = it.next();
        QString value = f.captured(2).trimmed();
        if (value.startsWith('"') && value.endsWith('"') && value.size() >= 2) {
            value = value.mid(1, value.size() - 2);
            value.replace("\\\"", "\"").replace("\\\\", "\\");
        }
        out.insert(f.captured(1), value);
    }
    return out;
}

bool isMonitorRule(const QString &line) { return line.trimmed().startsWith("hl.monitor("); }

} // namespace

Monitors::Monitors(const QString &hyprctl, const QString &configPath, QObject *parent)
    : QObject(parent),
      m_configPath(!configPath.isEmpty() ? configPath : QDir::homePath() + "/.config/hypr/monitors.lua") {
    // Like the theme's rounding: only ask hyprctl inside a Hyprland session.
    m_hyprctl = !hyprctl.isEmpty() ? hyprctl
              : !qEnvironmentVariableIsEmpty("HYPRLAND_INSTANCE_SIGNATURE") ? QStandardPaths::findExecutable("hyprctl")
              : QString();

    m_timeout.setSingleShot(true);
    m_timeout.setInterval(2000);
    connect(&m_timeout, &QTimer::timeout, &m_process, &QProcess::kill);
    connect(&m_process, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        m_timeout.stop();
        if (m_process.state() == QProcess::NotRunning)
            setResult({}, false, tr("Couldn't ask Hyprland about the displays."));
    });
    connect(&m_process, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        m_timeout.stop();
        const QByteArray output = m_process.readAllStandardOutput();
        if (code != 0 || status != QProcess::NormalExit || !QJsonDocument::fromJson(output).isArray())
            setResult({}, false, tr("Couldn't ask Hyprland about the displays."));
        else
            setResult(output, true, {});
    });

    m_tick.setInterval(1000);
    connect(&m_tick, &QTimer::timeout, this, [this] {
        if (--m_secondsLeft <= 0)
            revert();
        else
            emit confirmChanged();
    });

    if (m_hyprctl.isEmpty())
        m_error = tr("Hyprland isn't running, so there are no displays to show.");
    refresh();
}

Monitors::~Monitors() {
    // Closing while asked to keep a change doesn't keep it.
    if (m_confirming)
        run(m_undo);
    if (m_process.state() != QProcess::NotRunning) {
        m_process.kill();
        m_process.waitForFinished(1000);
    }
}

void Monitors::refresh() {
    if (m_hyprctl.isEmpty() || m_process.state() != QProcess::NotRunning)
        return;
    m_process.start(m_hyprctl, {"monitors", "all", "-j"});
    m_timeout.start();
}

QString Monitors::readConfig() const {
    QFile file(m_configPath);
    return file.open(QIODevice::ReadOnly) ? QString::fromUtf8(file.readAll()) : QString();
}

void Monitors::setResult(const QByteArray &json, bool available, const QString &error) {
    // Asked every few seconds: nothing to redraw when nothing changed (and a
    // display being dragged keeps its place).
    const QString saved = readConfig();
    const QByteArray key = json + saved.toUtf8();
    if (available == m_available && error == m_error && key == m_lastJson)
        return;
    m_lastJson = key;
    m_monitors = available ? parse(json, savedRules(saved)) : QVariantList();
    m_available = available;
    m_error = error;
    emit changed();
}

QString Monitors::displayName(const QJsonObject &monitor) {
    const QString name = monitor.value("name").toString();
    for (const char *prefix : {"eDP", "LVDS", "DSI"})
        if (name.startsWith(QLatin1String(prefix)))
            return tr("Built-in display");
    for (const char *key : {"model", "description"}) {
        const QString value = monitor.value(key).toString().trimmed();
        if (!value.isEmpty())
            return value;
    }
    return name;
}

QVariantList Monitors::parse(const QByteArray &json, const QHash<QString, QVariantMap> &saved) {
    QVariantList out;
    const QJsonArray all = QJsonDocument::fromJson(json).array();
    // Hyprland says which display one mirrors by its id; the page and the
    // rules name it.
    QHash<QString, QString> nameOfId;
    for (const auto &entry : all)
        nameOfId.insert(QString::number(entry.toObject().value("id").toInt(-1)), entry.toObject().value("name").toString());
    for (const auto &entry : all) {
        const QJsonObject m = entry.toObject();
        const QString name = m.value("name").toString();
        if (name.isEmpty())
            continue;
        const int width = m.value("width").toInt(), height = m.value("height").toInt();
        const int transform = m.value("transform").toInt();
        const double scale = m.value("scale").toDouble() > 0 ? m.value("scale").toDouble() : 1;
        // Rotated a quarter turn, the mode's width stands upright.
        const bool sideways = transform % 2 == 1;
        QString mirrorOf = m.value("mirrorOf").toString();
        if (mirrorOf == "none")
            mirrorOf.clear();
        else if (nameOfId.contains(mirrorOf))
            mirrorOf = nameOfId.value(mirrorOf);
        const QString label = displayName(m);
        const QString description = m.value("description").toString();
        const QString format = m.value("currentFormat").toString();

        // The modes it offers, biggest and fastest first, each once.
        QVariantList modes;
        QList<std::tuple<int, int, double>> seen;
        for (const auto &mode : m.value("availableModes").toArray()) {
            int w = 0, h = 0;
            double r = 0;
            if (!parseMode(mode.toString(), w, h, r))
                continue;
            r = std::round(r * 100) / 100;
            if (seen.contains({w, h, r}))
                continue;
            seen.append({w, h, r});
        }
        // The one it shows is always a choice, even when not offered
        // (a virtual display's).
        const double currentRefresh = std::round(m.value("refreshRate").toDouble() * 100) / 100;
        if (width > 0 && height > 0 && !m.value("disabled").toBool()) {
            bool found = false;
            for (const auto &[w, h, r] : seen)
                found = found || (w == width && h == height && std::abs(r - currentRefresh) < 0.02);
            if (!found)
                seen.append({width, height, currentRefresh});
        }
        std::sort(seen.begin(), seen.end(), [](const auto &a, const auto &b) {
            const auto &[aw, ah, ar] = a;
            const auto &[bw, bh, br] = b;
            if (qint64(aw) * ah != qint64(bw) * bh)
                return qint64(aw) * ah > qint64(bw) * bh;
            if (aw != bw)
                return aw > bw;
            return ar > br;
        });
        for (const auto &[w, h, r] : seen)
            modes.append(QVariantMap{{"width", w}, {"height", h}, {"refresh", r}});

        QVariantMap monitor{
            {"name", name},
            {"label", label},
            {"description", description},
            {"make", m.value("make").toString()},
            {"model", m.value("model").toString()},
            {"serial", m.value("serial").toString()},
            {"width", width},
            {"height", height},
            {"refreshRate", currentRefresh},
            {"scale", scale},
            {"scalePercent", int(std::lround(scale * 100))},
            {"x", m.value("x").toInt()},
            {"y", m.value("y").toInt()},
            {"logicalWidth", int(std::lround((sideways ? height : width) / scale))},
            {"logicalHeight", int(std::lround((sideways ? width : height) / scale))},
            {"transform", transform},
            {"focused", m.value("focused").toBool()},
            {"disabled", m.value("disabled").toBool()},
            {"mirrorOf", mirrorOf},
            {"builtIn", label == tr("Built-in display")},
            {"physicalWidth", m.value("physicalWidth").toInt()},
            {"physicalHeight", m.value("physicalHeight").toInt()},
            {"modes", modes},
            {"format", format},
            {"bitdepth", format.contains("2101010") ? 10 : 8},
            {"cm", m.value("colorManagementPreset").toString()},
            {"sdrBrightness", m.value("sdrBrightness").toDouble(1)},
            {"sdrSaturation", m.value("sdrSaturation").toDouble(1)},
            {"vrr", m.value("vrr").toBool()},
            // The Displays app writes rules by description, which follows a
            // display from one port to another; one without names its port.
            {"output", description.isEmpty() ? name : "desc:" + description},
        };
        const QVariantMap rule = saved.value(monitor.value("output").toString(), saved.value(name));
        monitor.insert("config", config(monitor, rule));
        out.append(monitor);
    }
    return out;
}

QVariantMap Monitors::config(const QVariantMap &m, const QVariantMap &saved) {
    const bool enabled = !m.value("disabled").toBool();
    QVariantMap c{
        {"output", m.value("output").toString()},
        {"name", m.value("name").toString()},
        {"enabled", enabled},
        {"width", m.value("width")},
        {"height", m.value("height")},
        {"refresh", m.value("refreshRate")},
        {"x", m.value("x")},
        {"y", m.value("y")},
        {"scale", m.value("scale")},
        {"transform", m.value("transform")},
        {"mirror", m.value("mirrorOf").toString()},
        {"vrr", m.value("vrr").toBool() ? 1 : 0},
        {"bitdepth", m.value("bitdepth")},
        // Hyprland reports what "auto" picked (sRGB, or wide color at 10
        // bits), so only HDR, which auto never picks, is taken as asked for.
        {"cm", m.value("cm").toString().startsWith("hdr") ? m.value("cm").toString() : QString("auto")},
        {"sdrBrightness", m.value("sdrBrightness")},
        {"sdrSaturation", m.value("sdrSaturation")},
    };
    // What Hyprland doesn't say: VRR on for fullscreen only, the exact color
    // preset asked for (it reports "hdr" for "hdredid"), and how a display
    // that's off was last set up.
    // (Hyprland's "vrr" says whether it's in use right now, which for
    // fullscreen only is false outside a fullscreen game.)
    if (saved.contains("vrr"))
        c.insert("vrr", saved.value("vrr").toInt());
    if (saved.contains("cm")) {
        const QString reported = m.value("cm").toString();
        const QString wanted = saved.value("cm").toString();
        if (!enabled || reported.isEmpty() || wanted.startsWith(reported))
            c.insert("cm", wanted);
    }
    if (!enabled) {
        int w = 0, h = 0;
        double r = 0;
        const QVariantList modes = m.value("modes").toList();
        if (parseMode(saved.value("mode").toString(), w, h, r)) {
            c.insert("width", w);
            c.insert("height", h);
            c.insert("refresh", r);
        } else if (!modes.isEmpty()) {
            const QVariantMap first = modes.first().toMap();
            c.insert("width", first.value("width"));
            c.insert("height", first.value("height"));
            c.insert("refresh", first.value("refresh"));
        }
        static const QRegularExpression pos(QStringLiteral("^\\s*(-?\\d+)x(-?\\d+)\\s*$"));
        const auto p = pos.match(saved.value("position").toString());
        c.insert("x", p.hasMatch() ? p.captured(1).toInt() : 0);
        c.insert("y", p.hasMatch() ? p.captured(2).toInt() : 0);
        if (saved.value("scale").toDouble() > 0)
            c.insert("scale", saved.value("scale").toDouble());
        if (saved.contains("transform"))
            c.insert("transform", saved.value("transform").toInt());
        if (saved.contains("bitdepth"))
            c.insert("bitdepth", saved.value("bitdepth").toInt());
        if (saved.contains("sdrbrightness"))
            c.insert("sdrBrightness", saved.value("sdrbrightness").toDouble());
        if (saved.contains("sdrsaturation"))
            c.insert("sdrSaturation", saved.value("sdrsaturation").toDouble());
    }
    return c;
}

QString Monitors::rule(const QVariantMap &c) {
    const QString output = luaString(c.value("output").toString());
    if (!c.value("enabled", true).toBool())
        return "hl.monitor({ output = " + output + ", disabled = true })";
    // Hyprland lays a rule over the one before for the same display, so
    // every field is said, or one left out would keep its old value (a
    // display stays turned, mirrored, or off).
    QStringList fields{"output = " + output, "disabled = false"};
    const int width = c.value("width").toInt(), height = c.value("height").toInt();
    const double refresh = c.value("refresh").toDouble();
    if (width > 0 && height > 0)
        fields << "mode = " + luaString(QString("%1x%2").arg(width).arg(height)
                                        + (refresh > 0 ? "@" + QString::number(refresh, 'f', 2) : QString()));
    else
        fields << "mode = \"preferred\"";
    fields << "position = " + luaString(QString("%1x%2").arg(c.value("x").toInt()).arg(c.value("y").toInt()));
    fields << "scale = " + number(c.value("scale").toDouble() > 0 ? c.value("scale").toDouble() : 1);
    fields << "transform = " + QString::number(c.value("transform").toInt());
    fields << "mirror = " + luaString(c.value("mirror").toString());
    fields << "vrr = " + QString::number(c.value("vrr").toInt());
    fields << "bitdepth = " + QString::number(c.value("bitdepth").toInt() == 10 ? 10 : 8);
    const QString cm = c.value("cm").toString();
    fields << "cm = " + luaString(cm.isEmpty() ? QString("auto") : cm);
    fields << "sdrbrightness = " + number(c.value("sdrBrightness").toDouble() > 0 ? c.value("sdrBrightness").toDouble() : 1, 2);
    fields << "sdrsaturation = " + number(c.value("sdrSaturation").toDouble() > 0 ? c.value("sdrSaturation").toDouble() : 1, 2);
    return "hl.monitor({ " + fields.join(", ") + " })";
}

QHash<QString, QVariantMap> Monitors::savedRules(const QString &text) {
    QHash<QString, QVariantMap> out;
    bool inside = false;
    for (const QString &line : text.split('\n')) {
        const QString trimmed = line.trimmed();
        if (trimmed.startsWith(BlockBegin))
            inside = true;
        else if (trimmed.startsWith(BlockEnd))
            inside = false;
        else if (inside && isMonitorRule(trimmed)) {
            const QVariantMap fields = ruleFields(trimmed);
            if (fields.contains("output"))
                out.insert(fields.value("output").toString(), fields);
        }
    }
    return out;
}

QString Monitors::withRules(const QString &text, const QList<QPair<QString, QString>> &rules) {
    QStringList lines = text.split('\n');
    // Without a newline at the end, the last line is the one split() left.
    if (!lines.isEmpty() && lines.last().isEmpty())
        lines.removeLast();
    int begin = -1, end = -1;
    for (int i = 0; i < lines.size(); ++i) {
        if (begin < 0 && lines[i].trimmed().startsWith(BlockBegin))
            begin = i;
        else if (begin >= 0 && lines[i].trimmed().startsWith(BlockEnd)) {
            end = i;
            break;
        }
    }
    if (begin < 0 || end < 0) {
        if (!lines.isEmpty() && !lines.last().trimmed().isEmpty())
            lines << QString();
        begin = lines.size();
        lines << BlockBegin + " (written by Settings, or the Displays app: Setup > Display in the Omarchy menu)"
              << "-- Changes here are overwritten the next time displays are set. Remove this"
              << "-- block to go back to the rules above."
              << BlockEnd;
        end = begin + 3;
    }

    QHash<QString, QString> byOutput;
    QStringList order;
    for (const auto &[output, rule] : rules) {
        if (!byOutput.contains(output))
            order << output;
        byOutput.insert(output, rule);
    }
    QStringList inner;
    QSet<QString> placed;
    for (int i = begin + 1; i < end; ++i) {
        const QString &line = lines[i];
        const QString output = isMonitorRule(line) ? ruleFields(line).value("output").toString() : QString();
        if (output.isEmpty() || !byOutput.contains(output)) {
            inner << line;
        } else if (!placed.contains(output)) {
            inner << byOutput.value(output);
            placed.insert(output);
        }
    }
    for (const QString &output : order)
        if (!placed.contains(output))
            inner << byOutput.value(output);

    QStringList result = lines.mid(0, begin + 1);
    result << inner << lines.mid(end);
    return result.join('\n') + "\n";
}

bool Monitors::run(const QStringList &rules) {
    if (rules.isEmpty())
        return true;
    if (m_hyprctl.isEmpty()) {
        setApplyError(tr("Hyprland isn't running."));
        return false;
    }
    QProcess process;
    process.start(m_hyprctl, {"eval", rules.join("; ")});
    if (!process.waitForFinished(5000)) {
        process.kill();
        setApplyError(tr("Hyprland didn't answer."));
        return false;
    }
    const QString output = QString::fromUtf8(process.readAllStandardOutput() + process.readAllStandardError()).trimmed();
    if (process.exitCode() != 0 || output.contains("error", Qt::CaseInsensitive)) {
        setApplyError(tr("Hyprland couldn't set the display: %1").arg(output.isEmpty() ? tr("no reason given") : output));
        return false;
    }
    return true;
}

bool Monitors::apply(const QVariantList &configs, bool confirm) {
    if (configs.isEmpty())
        return true;
    // One change at a time: one still waiting is kept first.
    if (m_confirming)
        keep();
    setApplyError({});

    // How the displays are now, to put them back.
    const QHash<QString, QVariantMap> saved = savedRules(readConfig());
    QStringList undo, rules;
    for (const QVariant &value : configs) {
        const QVariantMap c = value.toMap();
        rules << rule(c);
        for (const QVariant &m : m_monitors)
            if (m.toMap().value("name") == c.value("name"))
                undo << rule(m.toMap().value("config").toMap());
    }
    if (!run(rules)) {
        run(undo);
        refresh();
        return false;
    }
    if (confirm) {
        m_pending = configs;
        m_undo = undo;
        m_confirming = true;
        m_secondsLeft = confirmSeconds;
        m_tick.start();
        emit confirmChanged();
    } else {
        save(configs);
    }
    refresh();
    return true;
}

void Monitors::finishConfirm() {
    m_tick.stop();
    m_confirming = false;
    m_secondsLeft = 0;
    m_pending.clear();
    m_undo.clear();
    emit confirmChanged();
}

void Monitors::keep() {
    if (!m_confirming)
        return;
    const QVariantList pending = m_pending;
    finishConfirm();
    save(pending);
}

void Monitors::revert() {
    if (!m_confirming)
        return;
    const QStringList undo = m_undo;
    finishConfirm();
    run(undo);
    refresh();
}

bool Monitors::save(const QVariantList &configs) {
    QList<QPair<QString, QString>> rules;
    for (const QVariant &value : configs) {
        const QVariantMap c = value.toMap();
        rules.append({c.value("output").toString(), rule(c)});
    }
    const QString before = readConfig();
    const QString after = withRules(before, rules);
    if (after == before)
        return true;

    QDir().mkpath(QFileInfo(m_configPath).absolutePath());
    // A copy first, as the Displays app keeps one.
    if (QFileInfo::exists(m_configPath)) {
        const QString backup = m_configPath + ".bak." + QDateTime::currentDateTime().toString("yyyyMMdd-HHmmss");
        if (!QFileInfo::exists(backup))
            QFile::copy(m_configPath, backup);
    }
    QSaveFile file(m_configPath);
    if (!file.open(QIODevice::WriteOnly) || file.write(after.toUtf8()) < 0 || !file.commit()) {
        setApplyError(tr("Couldn't save %1: %2").arg(m_configPath, file.errorString()));
        return false;
    }
    // Not `hyprctl reload`: the change is already live, and a reload would
    // also undo whatever else was set live and isn't in the file (a display
    // another program turned off, say).
    return true;
}

void Monitors::setApplyError(const QString &error) {
    if (m_applyError == error)
        return;
    m_applyError = error;
    emit applyErrorChanged();
}
