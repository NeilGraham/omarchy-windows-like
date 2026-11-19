#pragma once

#include <QFileSystemWatcher>
#include <QHash>
#include <QObject>
#include <QProcess>
#include <QTimer>

// Follows the current Omarchy theme live: the accent, the few palette colors
// the window is painted with (light themes too), and Hyprland's rounding.
class Theme : public QObject {
    Q_OBJECT
    Q_PROPERTY(QString accent READ accent NOTIFY changed)
    Q_PROPERTY(QString accentForeground READ accentForeground NOTIFY changed)
    Q_PROPERTY(bool dark READ dark NOTIFY changed)
    Q_PROPERTY(QString window READ window NOTIFY changed)
    Q_PROPERTY(QString card READ card NOTIFY changed)
    Q_PROPERTY(QString foreground READ foreground NOTIFY changed)
    Q_PROPERTY(QString danger READ danger NOTIFY changed)
    Q_PROPERTY(int radius READ radius NOTIFY changed)

public:
    explicit Theme(const QString &currentDirectory = {}, QObject *parent = nullptr, const QString &hyprctl = {});
    ~Theme() override;

    QString accent() const { return color("accent"); }
    QString accentForeground() const;
    bool dark() const { return m_colors.value("mode") != "light"; }
    // The window and its navigation sit on the darker shade, cards on the
    // theme's background, like Windows 11's cards on Mica.
    QString window() const { return color("dark_background"); }
    QString card() const { return color("background"); }
    QString foreground() const { return color("foreground"); }
    QString danger() const { return color("red"); }
    int radius() const { return m_radius; }

    // A color from colors.toml, else the dark fallback the app has always had.
    QString color(const QString &key) const;

    static QString readAccent(const QString &path);
    static QHash<QString, QString> readColors(const QString &path);

signals:
    void changed();

private:
    void reload();
    void refreshRounding();

    QString m_directory;
    QHash<QString, QString> m_colors;
    QFileSystemWatcher m_watcher;
    QTimer m_debounce;
    QString m_hyprctl;
    int m_radius = 0;
    QProcess m_roundingProcess;
    QTimer m_roundingPoll, m_roundingTimeout;
};
