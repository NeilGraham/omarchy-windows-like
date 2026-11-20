#pragma once

#include <QHash>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QTimer>
#include <QVariant>

// The displays, for the Display page, laid out like Windows' display
// settings: what Hyprland sees (`hyprctl monitors all -j`), changed live
// (`hyprctl eval 'hl.monitor({ … })'`) and, once kept, saved to
// ~/.config/hypr/monitors.lua.
//
// Settings are saved in the block the Displays app keeps there (between
// "-- BEGIN Displays" and "-- END Displays"), one hl.monitor rule per display,
// so the two apps read each other's work. Only the displays changed here are
// rewritten; the rest of the block stays as it was.
//
// A change that can leave a screen blank (resolution, turning a display off)
// is tried first and asks to be kept, as on Windows: kept, it's saved; not
// kept within 15 seconds, it's put back.
class Monitors : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList monitors READ monitors NOTIFY changed)
    Q_PROPERTY(bool available READ available NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY changed)
    Q_PROPERTY(bool confirming READ confirming NOTIFY confirmChanged)
    Q_PROPERTY(int secondsLeft READ secondsLeft NOTIFY confirmChanged)
    Q_PROPERTY(QString applyError READ applyError NOTIFY applyErrorChanged)

public:
    // Tests pass a fake hyprctl and a monitors.lua of their own.
    explicit Monitors(const QString &hyprctl = {}, const QString &configPath = {}, QObject *parent = nullptr);
    ~Monitors() override;

    QVariantList monitors() const { return m_monitors; }
    // Hyprland answered, so the list is real (it may still be empty).
    bool available() const { return m_available; }
    QString error() const { return m_error; }
    bool confirming() const { return m_confirming; }
    int secondsLeft() const { return m_secondsLeft; }
    QString applyError() const { return m_applyError; }

    // Asks Hyprland again; the page calls it when it's shown and while it is.
    Q_INVOKABLE void refresh();
    // Puts displays as these configs say (see config() below for the keys).
    // With confirm, they're tried and wait for keep() or revert(); without,
    // they're saved at once.
    Q_INVOKABLE bool apply(const QVariantList &configs, bool confirm);
    Q_INVOKABLE void keep();
    Q_INVOKABLE void revert();

    int confirmSeconds = 15;

    // Each monitor as a map: name, label, description, make, model, serial,
    // width, height, refreshRate, scale, scalePercent, x, y, logicalWidth,
    // logicalHeight, transform, focused, disabled, mirrorOf, builtIn,
    // physicalWidth, physicalHeight (mm), modes ([{ width, height, refresh }],
    // biggest first), format, bitdepth, cm, sdrBrightness, sdrSaturation, vrr,
    // output (what its rule is for) and config (below). `saved` are the rules
    // in monitors.lua, by output, for what Hyprland doesn't say (VRR only for
    // fullscreen, a display that's off).
    static QVariantList parse(const QByteArray &json, const QHash<QString, QVariantMap> &saved = {});
    // What Windows would call the monitor: "Built-in display", else its model.
    static QString displayName(const QJsonObject &monitor);
    // A display's settings, as apply() takes them: output, name, enabled,
    // width, height, refresh, x, y, scale, transform, mirror, vrr (0 off,
    // 1 on, 2 fullscreen only), bitdepth (8 or 10), cm (Hyprland's color
    // management preset), sdrBrightness, sdrSaturation.
    static QVariantMap config(const QVariantMap &monitor, const QVariantMap &saved);
    // The hl.monitor rule that sets a config.
    static QString rule(const QVariantMap &config);
    // The hl.monitor rules in the Displays block of monitors.lua, by output,
    // each a map of its fields as written ("mode", "vrr", …).
    static QHash<QString, QVariantMap> savedRules(const QString &text);
    // monitors.lua with these rules in its Displays block: each replaces the
    // rule for its output, or is added; a file without the block gets one.
    static QString withRules(const QString &text, const QList<QPair<QString, QString>> &rules);

signals:
    void changed();
    void confirmChanged();
    void applyErrorChanged();

private:
    void setResult(const QByteArray &json, bool available, const QString &error);
    bool run(const QStringList &rules);
    bool save(const QVariantList &configs);
    void setApplyError(const QString &error);
    void finishConfirm();
    QString readConfig() const;

    QString m_hyprctl;
    QString m_configPath;
    QVariantList m_monitors;
    QByteArray m_lastJson;
    bool m_available = false;
    QString m_error;
    QString m_applyError;
    QProcess m_process;
    QTimer m_timeout;

    // A change waiting to be kept: what it set, and the rules that undo it.
    bool m_confirming = false;
    int m_secondsLeft = 0;
    QVariantList m_pending;
    QStringList m_undo;
    QTimer m_tick;
};
