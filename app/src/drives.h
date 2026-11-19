#pragma once

#include <QFileSystemWatcher>
#include <QJsonObject>
#include <QObject>
#include <QProcess>
#include <QSocketNotifier>
#include <QTimer>
#include <QVariant>
#include <functional>

// This PC: the user's folders, the drives worth showing (like Windows'
// Devices and drives) and network locations, with their size and use.
//
// Drives come from `lsblk -J`: one call has the whole tree (disk, partition,
// LUKS, LVM), filesystems, labels, partition types, every mount point and the
// space used, it needs no D-Bus, and its JSON makes the rules easy to test.
// Network shares come from `findmnt` (kernel mounts such as cifs and nfs) and
// from gvfs's FUSE folder (shares, phones and cameras opened in Files).
// Mounting, ejecting and powering off go through `udisksctl`, as Files does.
class Drives : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList folders READ folders NOTIFY changed)
    Q_PROPERTY(QVariantList drives READ drives NOTIFY changed)
    Q_PROPERTY(QVariantList network READ network NOTIFY changed)
    Q_PROPERTY(QString error READ error NOTIFY statusChanged)
    Q_PROPERTY(bool busy READ busy NOTIFY statusChanged)

public:
    struct Tools {
        QString lsblk, findmnt, udisksctl;
        QStringList opener;  // run with the path to open after it
        QString gvfs;        // gvfs's FUSE folder, $XDG_RUNTIME_DIR/gvfs
        bool watch = true;   // follow mounts and plugged devices live
    };
    // Tests pass fakes for every tool; the defaults are the real ones.
    explicit Drives(const Tools &tools = defaultTools(), QObject *parent = nullptr);
    ~Drives() override;

    QVariantList folders() const { return m_folders; }
    QVariantList drives() const { return m_drives; }
    QVariantList network() const { return m_network; }
    QString error() const { return m_error; }
    bool busy() const { return !m_pending.isEmpty(); }

    Q_INVOKABLE void refresh();
    // Opens an item in Files, mounting a drive first if it isn't mounted.
    Q_INVOKABLE void open(const QVariantMap &item);
    // Unmounts a removable drive and powers it off, so it can be pulled out.
    Q_INVOKABLE void eject(const QVariantMap &item);
    Q_INVOKABLE void clearError() { setError({}); }

    // "40.4 GB", in the binary units Windows calls KB, MB, GB, TB.
    static QString formatSize(qint64 bytes);
    // The drives in `lsblk -J -b -o …` output, in Windows' order: the system
    // drive, the other fixed drives, then removable ones and discs.
    static QVariantList parseDrives(const QByteArray &lsblkJson);
    // Kernel network mounts in `findmnt -J -b` output.
    static QVariantList parseNetworkMounts(const QByteArray &findmntJson);
    // gvfs's FUSE entries ("smb-share:server=nas,share=media"): shares go to
    // network locations, phones and cameras to the drives.
    static QVariantList parseGvfs(const QStringList &entries, const QString &directory);
    // Desktop, Documents, … from the XDG user dirs, skipping any that are
    // just the home folder or missing.
    static QVariantList userFolders();
    // The mount point `udisksctl mount` reports.
    static QString mountedAt(const QString &udisksOutput);
    static Tools defaultTools();

    static const QStringList LsblkColumns;

signals:
    void changed();
    void statusChanged();

private:
    void setError(const QString &error);
    void openPath(const QString &path);
    // Runs udisksctl; `done` gets its output when it succeeds.
    void udisks(const QStringList &arguments, std::function<void(const QString &)> done);
    void finishRefresh();

    Tools m_tools;
    QVariantList m_folders, m_drives, m_network;
    QVariantList m_kernelNetwork;
    QString m_error;
    QList<QProcess *> m_pending;
    QProcess m_lsblk, m_findmnt;
    QTimer m_poll, m_debounce, m_findmntTimeout;
    QFileSystemWatcher m_watcher;
    QSocketNotifier *m_mounts = nullptr;
    int m_mountsFd = -1;
};
