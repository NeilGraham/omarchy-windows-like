#include "monitors.h"

#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QStandardPaths>
#include <cmath>

Monitors::Monitors(const QString &hyprctl, const QString &displays, const QString &launcher, QObject *parent)
    : QObject(parent), m_displays(displays), m_launcher(launcher.isEmpty() ? findLauncher() : launcher) {
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
            setResult(parse(output), true, {});
    });

    if (m_hyprctl.isEmpty())
        m_error = tr("Hyprland isn't running, so there are no displays to show.");
    refresh();
}

Monitors::~Monitors() {
    if (m_process.state() != QProcess::NotRunning) {
        m_process.kill();
        m_process.waitForFinished(1000);
    }
}

void Monitors::refresh() {
    if (m_hyprctl.isEmpty()) {
        emit changed(); // Displays may have been installed meanwhile.
        return;
    }
    if (m_process.state() != QProcess::NotRunning)
        return;
    m_process.start(m_hyprctl, {"monitors", "all", "-j"});
    m_timeout.start();
}

void Monitors::setResult(const QVariantList &monitors, bool available, const QString &error) {
    m_monitors = monitors;
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

QVariantList Monitors::parse(const QByteArray &json) {
    QVariantList out;
    for (const auto &entry : QJsonDocument::fromJson(json).array()) {
        const QJsonObject m = entry.toObject();
        if (m.value("name").toString().isEmpty())
            continue;
        const int width = m.value("width").toInt(), height = m.value("height").toInt();
        const int transform = m.value("transform").toInt();
        const double scale = m.value("scale").toDouble() > 0 ? m.value("scale").toDouble() : 1;
        // Rotated a quarter turn, the mode's width stands upright.
        const bool sideways = transform % 2 == 1;
        const QString mirrorOf = m.value("mirrorOf").toString();
        const QString label = displayName(m);
        out.append(QVariantMap{
            {"name", m.value("name").toString()},
            {"label", label},
            {"description", m.value("description").toString()},
            {"width", width},
            {"height", height},
            {"refreshRate", std::round(m.value("refreshRate").toDouble() * 100) / 100},
            {"scale", scale},
            {"scalePercent", int(std::lround(scale * 100))},
            {"x", m.value("x").toInt()},
            {"y", m.value("y").toInt()},
            {"logicalWidth", int(std::lround((sideways ? height : width) / scale))},
            {"logicalHeight", int(std::lround((sideways ? width : height) / scale))},
            {"transform", transform},
            {"focused", m.value("focused").toBool()},
            {"disabled", m.value("disabled").toBool()},
            {"mirrorOf", mirrorOf == "none" ? QString() : mirrorOf},
            {"builtIn", label == tr("Built-in display")},
        });
    }
    return out;
}

// `displays` is a separate app (not part of this package); setup links
// personal tools into ~/.local/bin, which a launcher's PATH may not include.
QString Monitors::findDisplays() {
    QString found = QStandardPaths::findExecutable("displays");
    if (found.isEmpty())
        found = QStandardPaths::findExecutable("displays", {QDir::homePath() + "/.local/bin"});
    return found;
}

QString Monitors::findLauncher() {
    QString found = QStandardPaths::findExecutable("omarchy-launch-or-focus");
    if (found.isEmpty())
        found = QStandardPaths::findExecutable("omarchy-launch-or-focus",
                                               {qEnvironmentVariable("OMARCHY_PATH") + "/bin",
                                                QDir::homePath() + "/.local/share/omarchy/bin",
                                                "/usr/share/omarchy/bin"});
    return found;
}

// Looked up every time, so installing Displays while the app is open shows
// the button on the next refresh.
QString Monitors::displaysPath() const {
    const QString path = m_displays.isEmpty() ? findDisplays() : m_displays;
    return QFileInfo(path).isExecutable() && QFileInfo(path).isFile() ? path : QString();
}

bool Monitors::openDisplays() {
    const QString path = displaysPath();
    if (path.isEmpty())
        return false;
    // `omarchy-launch-or-focus displays 'uwsm-app -- displays'`, as Omarchy's
    // Setup > Display does; the full path only when it isn't on PATH.
    const QString program = QStandardPaths::findExecutable("displays") == path ? QString("displays") : path;
    const bool uwsm = !QStandardPaths::findExecutable("uwsm-app").isEmpty();
    const QString quoted = "'" + QString(program).replace("'", "'\\''") + "'";
    const QString command = uwsm ? "uwsm-app -- " + quoted : quoted;
    if (!m_launcher.isEmpty())
        return QProcess::startDetached(m_launcher, {"displays", command});
    return uwsm ? QProcess::startDetached("uwsm-app", {"--", path}) : QProcess::startDetached(path, {});
}
