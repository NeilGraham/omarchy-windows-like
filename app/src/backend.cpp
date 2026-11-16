#include "backend.h"

#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QSaveFile>
#include <QSettings>
#include <QStandardPaths>

namespace {

const QString PluginDir = QStringLiteral("/.config/omarchy/plugins/io.github.neilgraham.windows-like");

QJsonObject readObject(const QString &path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return QJsonDocument::fromJson(file.readAll()).object();
}

} // namespace

QString Backend::defaultSettingsPath() {
    return QDir::homePath() + "/.config/omarchy-windows-like/settings.json";
}

// The plugin's own defaults (a checkout named by OMARCHY_WINDOWS_LIKE_ROOT, or
// the installed plugin), else the copy this package ships.
QString Backend::findDefaults() {
    const QStringList candidates{qEnvironmentVariable("OMARCHY_WINDOWS_LIKE_ROOT") + "/config/defaults.json",
                                 QDir::homePath() + PluginDir + "/config/defaults.json",
                                 "/usr/share/windows-like-settings/defaults.json"};
    for (const auto &path : candidates)
        if (!path.startsWith("/config") && QFileInfo::exists(path))
            return path;
    return {};
}

// `omarchy-windows-like` is linked into ~/.local/bin by setup, which a
// launcher's PATH may not include, so look there and in the plugin too.
QString Backend::findApplyCommand() {
    QString found = QStandardPaths::findExecutable("omarchy-windows-like");
    if (found.isEmpty())
        found = QStandardPaths::findExecutable("omarchy-windows-like", {QDir::homePath() + "/.local/bin",
                                                                        QDir::homePath() + PluginDir + "/bin"});
    return found;
}

Backend::Backend(const QString &settingsPath, const QString &defaultsPath, const QString &applyCommand, QObject *parent)
    : QObject(parent),
      m_settingsPath(settingsPath.isEmpty() ? defaultSettingsPath() : settingsPath),
      m_defaultsPath(defaultsPath.isEmpty() ? findDefaults() : defaultsPath),
      m_applyCommand(applyCommand.isEmpty() ? findApplyCommand() : applyCommand) {
    // The Start menu changes the same file (pinning apps), so follow it.
    m_reload.setSingleShot(true);
    m_reload.setInterval(80);
    connect(&m_watcher, &QFileSystemWatcher::fileChanged, this, [this] { m_reload.start(); });
    connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_reload.start(); });
    connect(&m_reload, &QTimer::timeout, this, [this] {
        QFile file(m_settingsPath);
        if (file.open(QIODevice::ReadOnly) && file.readAll() == m_lastWritten) {
            watch();
            return;
        }
        load();
    });

    // A burst of changes (dragging the height slider) applies once it settles.
    m_applyLater.setSingleShot(true);
    m_applyLater.setInterval(350);
    connect(&m_applyLater, &QTimer::timeout, this, &Backend::applyNow);
    connect(&m_apply, &QProcess::finished, this, [this](int code, QProcess::ExitStatus exitStatus) {
        const QString output = QString::fromUtf8(m_apply.readAllStandardError()).trimmed();
        if (exitStatus != QProcess::NormalExit || code != 0)
            setStatus({}, output.isEmpty() ? tr("Applying the settings failed.") : output);
        else
            setStatus(tr("Saved and applied"));
        if (m_applyAgain) {
            m_applyAgain = false;
            applyNow();
        }
    });
    connect(&m_apply, &QProcess::errorOccurred, this, [this](QProcess::ProcessError) {
        if (m_apply.state() == QProcess::NotRunning)
            setStatus({}, tr("Couldn't run %1.").arg(m_applyCommand));
    });

    load();
    if (m_defaults.isEmpty())
        setStatus({}, tr("omarchy-windows-like isn't installed: its defaults weren't found."));
    else if (m_applyCommand.isEmpty())
        setStatus({}, tr("omarchy-windows-like isn't installed: run its setup first."));
}

Backend::~Backend() {
    if (m_apply.state() != QProcess::NotRunning)
        m_apply.waitForFinished(5000);
}

void Backend::watch() {
    const auto paths = m_watcher.files() + m_watcher.directories();
    if (!paths.isEmpty())
        m_watcher.removePaths(paths);
    // An atomic save replaces the file, so watch its directory as well.
    const QString directory = QFileInfo(m_settingsPath).absolutePath();
    if (QFileInfo::exists(directory))
        m_watcher.addPath(directory);
    if (QFileInfo::exists(m_settingsPath))
        m_watcher.addPath(m_settingsPath);
}

void Backend::load() {
    if (!m_defaultsPath.isEmpty())
        m_defaults = readObject(m_defaultsPath);
    m_user = readObject(m_settingsPath);
    m_merged = merge(m_defaults, m_user);
    watch();
    emit settingsChanged();
}

bool Backend::save() {
    QDir().mkpath(QFileInfo(m_settingsPath).absolutePath());
    QSaveFile file(m_settingsPath);
    const QByteArray data = QJsonDocument(m_user).toJson(QJsonDocument::Indented);
    if (!file.open(QIODevice::WriteOnly) || file.write(data) != data.size() || !file.commit()) {
        setStatus({}, tr("Couldn't save %1.").arg(m_settingsPath));
        return false;
    }
    m_lastWritten = data;
    watch();
    return true;
}

QJsonObject Backend::merge(const QJsonObject &base, const QJsonObject &over) {
    QJsonObject out = base;
    for (auto it = over.begin(); it != over.end(); ++it) {
        const QJsonValue b = out.value(it.key());
        if (b.isObject() && it.value().isObject())
            out.insert(it.key(), merge(b.toObject(), it.value().toObject()));
        else
            out.insert(it.key(), it.value());
    }
    return out;
}

QJsonValue Backend::valueAt(const QJsonObject &object, const QString &path) {
    QJsonValue value = object;
    for (const auto &key : path.split('.')) {
        if (!value.isObject())
            return QJsonValue(QJsonValue::Undefined);
        value = value.toObject().value(key);
    }
    return value;
}

QJsonObject Backend::withValueAt(const QJsonObject &object, const QStringList &path, const QJsonValue &value) {
    QJsonObject out = object;
    if (path.isEmpty())
        return out;
    if (path.size() == 1) {
        out.insert(path.first(), value);
        return out;
    }
    out.insert(path.first(), withValueAt(out.value(path.first()).toObject(), path.mid(1), value));
    return out;
}

QVariant Backend::value(const QString &path) const {
    const QJsonValue v = valueAt(m_merged, path);
    return v.isUndefined() ? QVariant() : v.toVariant();
}

void Backend::setValue(const QString &path, const QVariant &value) {
    const QJsonValue json = QJsonValue::fromVariant(value);
    if (valueAt(m_merged, path) == json && !valueAt(m_user, path).isUndefined())
        return;
    m_user = withValueAt(m_user, path.split('.'), json);
    m_merged = merge(m_defaults, m_user);
    emit settingsChanged();
    if (save())
        m_applyLater.start();
}

void Backend::removeFromList(const QString &path, const QString &item) {
    QJsonArray list = valueAt(m_merged, path).toArray();
    for (qsizetype i = list.size() - 1; i >= 0; --i)
        if (list.at(i).toString() == item)
            list.removeAt(i);
    setValue(path, list.toVariantList());
}

void Backend::resetToDefaults() {
    // Pins are the user's own, not a setting to reset.
    QJsonObject kept;
    for (const QString path : {"taskbar.pinned", "start.pinned"}) {
        const QJsonValue pins = valueAt(m_user, path);
        if (!pins.isUndefined())
            kept = withValueAt(kept, path.split('.'), pins);
    }
    m_user = kept;
    m_merged = merge(m_defaults, m_user);
    emit settingsChanged();
    if (save())
        m_applyLater.start();
}

void Backend::applyNow() {
    if (m_applyCommand.isEmpty())
        return;
    if (m_apply.state() != QProcess::NotRunning) {
        m_applyAgain = true;
        return;
    }
    setStatus(tr("Applying…"));
    m_apply.start(m_applyCommand, {"apply"});
    emit statusChanged();
}

void Backend::setStatus(const QString &status, const QString &error) {
    m_status = status;
    m_error = error;
    emit statusChanged();
}

QString Backend::appName(const QString &desktopId) const {
    const QString file = desktopId.endsWith(".desktop") ? desktopId : desktopId + ".desktop";
    const QString path = QStandardPaths::locate(QStandardPaths::ApplicationsLocation, file);
    if (path.isEmpty())
        return desktopId;
    QFile f(path);
    if (!f.open(QIODevice::ReadOnly))
        return desktopId;
    bool inEntry = false;
    while (!f.atEnd()) {
        const QString line = QString::fromUtf8(f.readLine()).trimmed();
        if (line.startsWith('['))
            inEntry = line == "[Desktop Entry]";
        else if (inEntry && line.startsWith("Name="))
            return line.mid(5);
    }
    return desktopId;
}
