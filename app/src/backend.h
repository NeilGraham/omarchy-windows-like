#pragma once

#include <QFileSystemWatcher>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariant>

// The settings of omarchy-windows-like: config/defaults.json from the plugin,
// with the user's choices in ~/.config/omarchy-windows-like/settings.json
// over them. Only the user's choices are written, atomically; after a change
// settles, `omarchy-windows-like apply` puts it into effect (taskbar layout,
// Hyprland bindings, and so on). The shell reads the file live by itself.
class Backend : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantMap settings READ settings NOTIFY settingsChanged)
    Q_PROPERTY(bool applying READ applying NOTIFY statusChanged)
    Q_PROPERTY(QString status READ status NOTIFY statusChanged)
    Q_PROPERTY(QString error READ error NOTIFY statusChanged)
    Q_PROPERTY(bool installed READ installed CONSTANT)

public:
    // Tests pass their own files and a fake apply command.
    explicit Backend(const QString &settingsPath = {}, const QString &defaultsPath = {}, const QString &applyCommand = {},
                     QObject *parent = nullptr);
    ~Backend() override;

    QVariantMap settings() const { return m_merged.toVariantMap(); }
    bool applying() const { return m_apply.state() != QProcess::NotRunning; }
    QString status() const { return m_status; }
    QString error() const { return m_error; }
    bool installed() const { return !m_applyCommand.isEmpty() && !m_defaults.isEmpty(); }

    // value("snapping.edges")
    Q_INVOKABLE QVariant value(const QString &path) const;
    Q_INVOKABLE void setValue(const QString &path, const QVariant &value);
    // Removes an item from a list setting, e.g. a pinned app.
    Q_INVOKABLE void removeFromList(const QString &path, const QString &item);
    Q_INVOKABLE void resetToDefaults();
    Q_INVOKABLE void applyNow();
    // The name a desktop entry shows ("org.gnome.Nautilus" -> "Files").
    Q_INVOKABLE QString appName(const QString &desktopId) const;

    static QJsonObject merge(const QJsonObject &base, const QJsonObject &over);
    static QJsonValue valueAt(const QJsonObject &object, const QString &path);
    static QJsonObject withValueAt(const QJsonObject &object, const QStringList &path, const QJsonValue &value);
    static QString defaultSettingsPath();
    static QString findDefaults();
    static QString findApplyCommand();

signals:
    void settingsChanged();
    void statusChanged();

private:
    void load();
    bool save();
    void setStatus(const QString &status, const QString &error = {});
    void watch();

    QString m_settingsPath;
    QString m_defaultsPath;
    QString m_applyCommand;
    QJsonObject m_defaults;
    QJsonObject m_user;
    QJsonObject m_merged;
    QByteArray m_lastWritten;
    QString m_status;
    QString m_error;
    QFileSystemWatcher m_watcher;
    QTimer m_reload;
    QTimer m_applyLater;
    QProcess m_apply;
    bool m_applyAgain = false;
};
