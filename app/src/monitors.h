#pragma once

#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariant>

// The monitors Hyprland sees (`hyprctl monitors all -j`), summed up for the
// Display page, and the way into Displays, the separate app that changes them.
// Displays is optional: without it the page keeps the summary and says so.
class Monitors : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList monitors READ monitors NOTIFY changed)
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(bool displaysInstalled READ displaysInstalled NOTIFY changed)

public:
    // Tests pass a fake hyprctl, displays and omarchy-launch-or-focus.
    explicit Monitors(const QString &hyprctl = {}, const QString &displays = {}, const QString &launcher = {},
                      QObject *parent = nullptr);
    ~Monitors() override;

    QVariantList monitors() const { return m_monitors; }
    // Hyprland answered, so the list is real (it may still be empty).
    bool available() const { return m_available; }
    QString error() const { return m_error; }
    bool displaysInstalled() const { return !displaysPath().isEmpty(); }

    // Asks Hyprland again; the page calls it when it's shown and while it is.
    Q_INVOKABLE void refresh();
    // Brings Displays forward, or starts it, the way Omarchy's menu does.
    Q_INVOKABLE bool openDisplays();

    // Each monitor as a map: name, label, description, width, height,
    // refreshRate, scale, scalePercent, x, y, logicalWidth, logicalHeight,
    // transform, focused, disabled, mirrorOf, builtIn.
    static QVariantList parse(const QByteArray &json);
    // What Windows would call the monitor: "Built-in display", else its model.
    static QString displayName(const QJsonObject &monitor);
    static QString findDisplays();
    static QString findLauncher();

signals:
    void changed();

private:
    QString displaysPath() const;
    void setResult(const QVariantList &monitors, bool available, const QString &error);

    QString m_hyprctl;
    QString m_displays;
    QString m_launcher;
    QVariantList m_monitors;
    bool m_available = false;
    QString m_error;
    QProcess m_process;
    QTimer m_timeout;
};
