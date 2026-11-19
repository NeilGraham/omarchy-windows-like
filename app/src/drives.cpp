#include "drives.h"

#include <QCollator>
#include <QDir>
#include <QFileInfo>
#include <QJsonArray>
#include <QJsonDocument>
#include <QLocale>
#include <QRegularExpression>
#include <QSet>
#include <QStandardPaths>
#include <QUrl>
#include <cmath>
#include <fcntl.h>
#include <unistd.h>

namespace {

// Partitions Windows doesn't show either: EFI system, Microsoft reserved,
// Windows recovery, BIOS boot, Linux swap, extended boot (GPT); EFI, hidden
// recovery, swap and diagnostics (MBR).
const QSet<QString> HiddenPartitionTypes{
    "c12a7328-f81f-11d2-ba4b-00a0c93ec93b", "e3c9e316-0b5c-4db8-817d-f92df00215ae",
    "de94bba4-06d1-4d40-a16a-bfd50179d6ac", "21686148-6449-6e6f-744e-656564454649",
    "0657fd6d-a4ab-43c4-84e5-0933c84b4f4f", "bc13c2ff-59e6-4262-a352-b275fd6f7172",
    "0xef", "0x27", "0x82", "0x12"};
const QSet<QString> HiddenMounts{"/boot", "/boot/efi", "/efi", "/recovery"};
// Filesystems that are someone else's business: swap, read-only images, and
// members of a pool that's mounted (or not) by other means.
const QSet<QString> HiddenFilesystems{"swap", "squashfs", "erofs", "zfs_member", "LVM2_member", "linux_raid_member"};
const QSet<QString> NetworkFilesystems{"cifs", "smb3", "smbfs", "nfs", "nfs4", "fuse.sshfs", "sshfs",
                                       "davfs", "fuse.rclone", "ceph", "glusterfs", "fuse.glusterfs"};

qint64 number(const QJsonValue &value) {
    // lsblk -b writes numbers; older versions wrote them as strings.
    return value.isString() ? value.toString().toLongLong() : qint64(value.toDouble(-1));
}

// The fields every tile has, from its size and free space (free < 0: unknown).
void addUsage(QVariantMap &item, qint64 size, qint64 used, qint64 free) {
    item["size"] = size;
    item["used"] = used;
    item["free"] = free;
    item["sizeText"] = size > 0 ? Drives::formatSize(size) : QString();
    item["usedText"] = used >= 0 ? Drives::formatSize(used) : QString();
    item["freeText"] = free >= 0 ? Drives::formatSize(free) : QString();
    const bool known = size > 0 && free >= 0;
    // The bar shows what isn't free, as "X free of Y" says.
    const double fraction = known ? std::clamp(1.0 - double(free) / double(size), 0.0, 1.0) : 0;
    item["hasUsage"] = known;
    item["usedFraction"] = std::round(fraction * 1000) / 1000;
    // Windows turns the bar red when a drive is 90 % full.
    item["nearlyFull"] = known && fraction >= 0.9;
}

struct Walk {
    QVariantList out;
    QSet<QString> seenBtrfs;

    void node(const QJsonObject &n, const QJsonObject &disk, const QString &crypt) {
        const QString type = n.value("type").toString();
        const QString name = n.value("name").toString();
        const QString fstype = n.value("fstype").toString();
        const QJsonArray children = n.value("children").toArray();
        if (type == "loop" || name.startsWith("zram") || number(n.value("size")) <= 0)
            return;
        if (HiddenPartitionTypes.contains(n.value("parttype").toString().toLower()))
            return;

        // Unlocked encryption: the drive is the filesystem inside.
        if (fstype == "crypto_LUKS" || fstype == "BitLocker") {
            if (children.isEmpty())
                add(n, disk, {}, true);
            for (const auto &child : children)
                node(child.toObject(), disk, n.value("path").toString());
            return;
        }
        // A disk's partitions, an LVM volume group's volumes, a RAID's array.
        if (!children.isEmpty()) {
            for (const auto &child : children)
                node(child.toObject(), disk, crypt);
            return;
        }
        if (fstype.isEmpty() || HiddenFilesystems.contains(fstype))
            return;
        add(n, disk, crypt, false);
    }

    void add(const QJsonObject &n, const QJsonObject &disk, const QString &crypt, bool locked) {
        QStringList mounts;
        for (const auto &m : n.value("mountpoints").toArray())
            if (m.isString() && m.toString().startsWith('/'))
                mounts << m.toString();
        for (const auto &m : mounts)
            if (HiddenMounts.contains(m))
                return;
        // A btrfs filesystem spread over several devices shows once.
        const QString uuid = n.value("uuid").toString();
        if (n.value("fstype").toString() == "btrfs" && !uuid.isEmpty()) {
            if (seenBtrfs.contains(uuid))
                return;
            seenBtrfs.insert(uuid);
        }

        // Subvolumes and bind mounts share one filesystem: show it at "/"
        // if it's there, else at its shortest mount point.
        std::sort(mounts.begin(), mounts.end(), [](const QString &a, const QString &b) {
            return a.size() != b.size() ? a.size() < b.size() : a < b;
        });
        const bool system = mounts.contains("/");
        const QString mount = system ? QString("/") : mounts.value(0);

        const QString diskName = disk.value("name").toString();
        const QString transport = disk.value("tran").toString();
        const bool removable = disk.value("rm").toBool() || disk.value("hotplug").toBool() || transport == "usb";
        const bool optical = disk.value("type").toString() == "rom";
        QString kind = system ? "system"
                     : optical ? "optical"
                     : removable && diskName.startsWith("mmcblk") ? "sdcard"
                     : removable ? "usb"
                     : "drive";

        const QString label = n.value("label").toString().trimmed();
        QString name = system ? Drives::tr("System")
                     : !label.isEmpty() ? label
                     : optical ? Drives::tr("Disc Drive")
                     : kind == "usb" ? Drives::tr("USB Drive")
                     : kind == "sdcard" ? Drives::tr("SD Card")
                     : Drives::tr("Local Disk");

        QVariantMap item{
            {"id", n.value("path").toString()},
            {"kind", kind},
            {"name", name},
            {"title", mount.isEmpty() ? name : name + " (" + mount + ")"},
            {"label", label},
            {"mount", mount},
            {"path", mount},
            {"mountPoints", mounts},
            {"mounted", !mount.isEmpty()},
            {"locked", locked},
            {"removable", removable || optical},
            {"device", n.value("path").toString()},
            {"cryptDevice", crypt},
            {"diskDevice", disk.value("path").toString()},
            {"model", QStringList{disk.value("vendor").toString().trimmed(), disk.value("model").toString().trimmed()}
                          .filter(QRegularExpression(".")).join(' ')},
            {"connection", transport},
            {"fstype", locked ? QString() : n.value("fstype").toString()},
        };
        if (mount.isEmpty())
            addUsage(item, number(n.value("size")), -1, -1);
        else
            addUsage(item, number(n.value("fssize")), number(n.value("fsused")), number(n.value("fsavail")));
        out << item;
    }
};

int order(const QVariantMap &item) {
    static const QStringList kinds{"system", "drive", "usb", "sdcard", "optical", "phone"};
    const int kind = kinds.indexOf(item.value("kind").toString());
    return kind * 2 + (item.value("mounted").toBool() ? 0 : 1);
}

void sortItems(QVariantList &items) {
    QCollator collator;
    collator.setNumericMode(true);
    std::stable_sort(items.begin(), items.end(), [&](const QVariant &a, const QVariant &b) {
        const QVariantMap x = a.toMap(), y = b.toMap();
        if (order(x) != order(y))
            return order(x) < order(y);
        return collator.compare(x.value("title").toString(), y.value("title").toString()) < 0;
    });
}

// What a list looks like on screen: two refreshes that differ only in bytes
// nobody sees don't rebuild the tiles (and lose the keyboard focus).
QVariantList visible(QVariantList items) {
    for (auto &item : items) {
        QVariantMap map = item.toMap();
        map.remove("used");
        map.remove("free");
        item = map;
    }
    return items;
}

} // namespace

const QStringList Drives::LsblkColumns{"NAME", "PATH", "TYPE", "SIZE", "FSTYPE", "LABEL", "PARTTYPE", "MOUNTPOINTS",
                                       "FSAVAIL", "FSUSED", "FSSIZE", "RM", "HOTPLUG", "TRAN", "MODEL", "VENDOR", "UUID"};

QString Drives::formatSize(qint64 bytes) {
    static const char *units[] = {QT_TR_NOOP("%1 bytes"), QT_TR_NOOP("%1 KB"), QT_TR_NOOP("%1 MB"),
                                  QT_TR_NOOP("%1 GB"), QT_TR_NOOP("%1 TB"), QT_TR_NOOP("%1 PB")};
    double value = double(std::max<qint64>(bytes, 0));
    int unit = 0;
    // Bytes up to 1,023, then never four figures: 1,000 GB is 0.98 TB.
    if (value >= 1024)
        for (value /= 1024, unit = 1; value >= 1000 && unit < 5; ++unit)
            value /= 1024;
    // Three figures, as Windows writes them: 9.87 GB, 98.7 GB, 987 GB.
    const int decimals = unit == 0 ? 0 : value < 10 ? 2 : value < 100 ? 1 : 0;
    QString text = QLocale().toString(value, 'f', decimals);
    if (decimals > 0) {
        // 2.50 GB reads 2.5 GB, 40.0 GB reads 40 GB.
        const QString point = QLocale().decimalPoint();
        while (text.endsWith('0'))
            text.chop(1);
        if (text.endsWith(point))
            text.chop(point.size());
    }
    return tr(units[unit]).arg(text);
}

QVariantList Drives::parseDrives(const QByteArray &lsblkJson) {
    Walk walk;
    for (const auto &disk : QJsonDocument::fromJson(lsblkJson).object().value("blockdevices").toArray())
        walk.node(disk.toObject(), disk.toObject(), {});
    sortItems(walk.out);
    return walk.out;
}

QVariantList Drives::parseNetworkMounts(const QByteArray &findmntJson) {
    QVariantList out;
    QSet<QString> seen;
    for (const auto &entry : QJsonDocument::fromJson(findmntJson).object().value("filesystems").toArray()) {
        const QJsonObject m = entry.toObject();
        const QString target = m.value("target").toString(), source = m.value("source").toString();
        if (!NetworkFilesystems.contains(m.value("fstype").toString()) || target.isEmpty() || seen.contains(target))
            continue;
        seen.insert(target);
        // //server/share, server:/export/path, user@host:/path.
        QString host, share;
        static const QRegularExpression unc(R"(^//([^/]+)/(.*)$)"), remote(R"(^(?:[^@]+@)?([^:]+):(.*)$)");
        if (const auto match = unc.match(source); match.hasMatch()) {
            host = match.captured(1);
            share = match.captured(2);
        } else if (const auto match = remote.match(source); match.hasMatch()) {
            host = match.captured(1);
            share = match.captured(2);
        }
        share = QFileInfo(share).fileName();
        const QString name = !share.isEmpty() ? share : !host.isEmpty() ? host : QFileInfo(target).fileName();
        QVariantMap item{{"id", target},          {"kind", "network"},       {"name", name},
                         {"title", name + " (" + target + ")"},             {"mount", target},
                         {"path", target},        {"mounted", true},         {"locked", false},
                         {"removable", false},    {"device", source},        {"host", host},
                         {"fstype", m.value("fstype").toString()}};
        const qint64 size = number(m.value("size"));
        addUsage(item, size, size > 0 ? number(m.value("used")) : -1, size > 0 ? number(m.value("avail")) : -1);
        out << item;
    }
    sortItems(out);
    return out;
}

QVariantList Drives::parseGvfs(const QStringList &entries, const QString &directory) {
    QVariantList out;
    for (const QString &entry : entries) {
        const QString type = entry.section(':', 0, 0);
        QHash<QString, QString> keys;
        for (const QString &pair : entry.section(':', 1).split(',', Qt::SkipEmptyParts))
            keys.insert(pair.section('=', 0, 0), QUrl::fromPercentEncoding(pair.section('=', 1).toUtf8()));
        const bool device = type == "mtp" || type == "gphoto2" || type == "afc";
        const QString host = keys.value(type == "smb-share" ? "server" : "host");
        QString name = keys.value("share", keys.value("volume", QFileInfo(keys.value("prefix")).fileName()));
        if (device)
            name = QString(host).replace('_', ' ').remove(QRegularExpression(R"(^\[.*\]$)"));
        if (name.isEmpty())
            name = host;
        if (name.isEmpty())
            continue;
        QVariantMap item{{"id", entry},
                         {"kind", device ? "phone" : "network"},
                         {"name", name},
                         {"title", device || host.isEmpty() || name == host ? name : tr("%1 on %2").arg(name, host)},
                         {"mount", QString()},
                         {"path", directory + "/" + entry},
                         {"mounted", true},
                         {"locked", false},
                         {"removable", false},
                         {"device", entry},
                         {"host", host},
                         {"fstype", type}};
        addUsage(item, -1, -1, -1);
        out << item;
    }
    sortItems(out);
    return out;
}

QVariantList Drives::userFolders() {
    const QList<QPair<QString, QStandardPaths::StandardLocation>> kinds{
        {"desktop", QStandardPaths::DesktopLocation},     {"documents", QStandardPaths::DocumentsLocation},
        {"downloads", QStandardPaths::DownloadLocation},  {"music", QStandardPaths::MusicLocation},
        {"pictures", QStandardPaths::PicturesLocation},   {"videos", QStandardPaths::MoviesLocation}};
    const QString home = QDir::cleanPath(QDir::homePath());
    QVariantList out;
    for (const auto &[kind, location] : kinds) {
        const QString path = QDir::cleanPath(QStandardPaths::writableLocation(location));
        if (path.isEmpty() || path == home || !QFileInfo(path).isDir())
            continue;
        out << QVariantMap{{"id", path}, {"kind", "folder"}, {"folder", kind}, {"name", QFileInfo(path).fileName()},
                           {"title", QFileInfo(path).fileName()}, {"path", path}, {"mounted", true}};
    }
    return out;
}

QString Drives::mountedAt(const QString &udisksOutput) {
    // "Mounted /dev/sdc1 at /run/media/nng/STICK" (older versions end in ".").
    static const QRegularExpression expression(R"(^Mounted \S+ at (.+?)\.?\s*$)", QRegularExpression::MultilineOption);
    return expression.match(udisksOutput).captured(1);
}

Drives::Tools Drives::defaultTools() {
    Tools tools;
    tools.lsblk = QStandardPaths::findExecutable("lsblk");
    tools.findmnt = QStandardPaths::findExecutable("findmnt");
    tools.udisksctl = QStandardPaths::findExecutable("udisksctl");
    // Files, the way Omarchy starts apps, else whatever opens folders.
    const bool nautilus = !QStandardPaths::findExecutable("nautilus").isEmpty();
    const bool uwsm = !QStandardPaths::findExecutable("uwsm-app").isEmpty();
    tools.opener = nautilus && uwsm ? QStringList{"uwsm-app", "--", "nautilus"}
                 : nautilus ? QStringList{"nautilus"}
                 : QStringList{"xdg-open"};
    const QString runtime = qEnvironmentVariable("XDG_RUNTIME_DIR");
    tools.gvfs = runtime.isEmpty() ? QString() : runtime + "/gvfs";
    return tools;
}

Drives::Drives(const Tools &tools, QObject *parent) : QObject(parent), m_tools(tools) {
    m_debounce.setSingleShot(true);
    m_debounce.setInterval(300);
    connect(&m_debounce, &QTimer::timeout, this, &Drives::refresh);

    // Only a program that never started doesn't also finish.
    connect(&m_lsblk, &QProcess::finished, this, [this] { finishRefresh(); });
    connect(&m_lsblk, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart)
            finishRefresh();
    });
    // A network mount whose server has gone can keep findmnt waiting.
    m_findmntTimeout.setSingleShot(true);
    m_findmntTimeout.setInterval(3000);
    connect(&m_findmntTimeout, &QTimer::timeout, &m_findmnt, &QProcess::kill);
    connect(&m_findmnt, &QProcess::finished, this, [this](int code, QProcess::ExitStatus status) {
        m_findmntTimeout.stop();
        if (status == QProcess::NormalExit && (code == 0 || code == 1)) // 1: nothing mounted
            m_kernelNetwork = parseNetworkMounts(m_findmnt.readAllStandardOutput());
        finishRefresh();
    });
    connect(&m_findmnt, &QProcess::errorOccurred, this, [this](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart)
            return;
        m_findmntTimeout.stop();
        finishRefresh();
    });

    if (m_tools.watch) {
        // Mounting or unmounting anything wakes /proc/self/mountinfo.
        m_mountsFd = ::open("/proc/self/mountinfo", O_RDONLY | O_CLOEXEC);
        if (m_mountsFd >= 0) {
            m_mounts = new QSocketNotifier(m_mountsFd, QSocketNotifier::Exception, this);
            connect(m_mounts, &QSocketNotifier::activated, this, [this] {
                // Reading it to the end re-arms the notification.
                char buffer[4096];
                ::lseek(m_mountsFd, 0, SEEK_SET);
                while (::read(m_mountsFd, buffer, sizeof buffer) > 0) {}
                m_debounce.start();
            });
        }
        // udev adds and removes links here as drives and media come and go.
        for (const QString path : {"/dev/disk", "/dev/disk/by-id", "/dev/disk/by-diskseq"})
            if (QFileInfo(path).isDir())
                m_watcher.addPath(path);
        if (!m_tools.gvfs.isEmpty() && QFileInfo(m_tools.gvfs).isDir())
            m_watcher.addPath(m_tools.gvfs);
        connect(&m_watcher, &QFileSystemWatcher::directoryChanged, this, [this] { m_debounce.start(); });
        // Space used changes without any of that.
        m_poll.setInterval(5000);
        connect(&m_poll, &QTimer::timeout, this, &Drives::refresh);
        m_poll.start();
    }
    refresh();
}

Drives::~Drives() {
    for (QProcess *process : {&m_lsblk, &m_findmnt})
        if (process->state() != QProcess::NotRunning) {
            process->kill();
            process->waitForFinished(1000);
        }
    if (m_mountsFd >= 0)
        ::close(m_mountsFd);
}

void Drives::refresh() {
    if (m_lsblk.state() != QProcess::NotRunning || m_findmnt.state() != QProcess::NotRunning)
        return;
    if (!m_tools.lsblk.isEmpty())
        m_lsblk.start(m_tools.lsblk, {"-J", "-b", "-o", LsblkColumns.join(',')});
    if (!m_tools.findmnt.isEmpty()) {
        m_findmnt.start(m_tools.findmnt, {"-J", "-b", "-t", QStringList(NetworkFilesystems.begin(), NetworkFilesystems.end()).join(','),
                                          "-o", "TARGET,SOURCE,FSTYPE,SIZE,USED,AVAIL"});
        m_findmntTimeout.start();
    }
    if (m_lsblk.state() == QProcess::NotRunning && m_findmnt.state() == QProcess::NotRunning)
        finishRefresh();
}

void Drives::finishRefresh() {
    if (m_lsblk.state() != QProcess::NotRunning || m_findmnt.state() != QProcess::NotRunning)
        return;
    QVariantList drives = parseDrives(m_lsblk.readAllStandardOutput());
    QVariantList network = m_kernelNetwork;
    if (!m_tools.gvfs.isEmpty()) {
        const QStringList entries = QDir(m_tools.gvfs).entryList(QDir::Dirs | QDir::NoDotAndDotDot, QDir::Name);
        for (const auto &item : parseGvfs(entries, m_tools.gvfs))
            (item.toMap().value("kind") == "phone" ? drives : network) << item;
    }
    const QVariantList folders = userFolders();
    const bool different = visible(drives) != visible(m_drives) || visible(network) != visible(m_network) || folders != m_folders;
    m_drives = drives;
    m_network = network;
    m_folders = folders;
    if (different)
        emit changed();
}

void Drives::setError(const QString &error) {
    m_error = error;
    emit statusChanged();
}

void Drives::openPath(const QString &path) {
    if (m_tools.opener.isEmpty() || !QProcess::startDetached(m_tools.opener.first(), m_tools.opener.mid(1) << path))
        setError(tr("Couldn't open %1.").arg(path));
}

void Drives::udisks(const QStringList &arguments, std::function<void(const QString &)> done) {
    if (m_tools.udisksctl.isEmpty()) {
        setError(tr("udisksctl isn't installed, so drives can't be mounted or ejected here."));
        return;
    }
    auto *process = new QProcess(this);
    m_pending << process;
    emit statusChanged();
    connect(process, &QProcess::finished, this, [this, process, done](int code, QProcess::ExitStatus status) {
        m_pending.removeAll(process);
        process->deleteLater();
        const QString output = QString::fromUtf8(process->readAllStandardOutput());
        // "Error mounting /dev/sdc1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: wrong fs type…"
        QString message = QString::fromUtf8(process->readAllStandardError()).trimmed();
        message.remove(QRegularExpression(R"(GDBus\.Error:[\w.]+:\s*)"));
        emit statusChanged();
        if (status != QProcess::NormalExit || code != 0)
            setError(message.isEmpty() ? tr("udisksctl failed.") : message);
        else
            done(output);
    });
    connect(process, &QProcess::errorOccurred, this, [this, process](QProcess::ProcessError error) {
        if (error != QProcess::FailedToStart)
            return;
        m_pending.removeAll(process);
        process->deleteLater();
        setError(tr("Couldn't run udisksctl."));
    });
    // Without --no-user-interaction, polkit asks for a password where needed.
    process->start(m_tools.udisksctl, arguments);
}

void Drives::open(const QVariantMap &item) {
    setError({});
    if (item.value("locked").toBool()) {
        setError(tr("%1 is encrypted. Unlock it in Files first.").arg(item.value("name").toString()));
        return;
    }
    if (item.value("mounted").toBool()) {
        openPath(item.value("path").toString());
        return;
    }
    udisks({"mount", "-b", item.value("device").toString()}, [this](const QString &output) {
        refresh();
        const QString path = mountedAt(output);
        if (path.isEmpty())
            setError(tr("Mounted, but udisksctl didn't say where."));
        else
            openPath(path);
    });
}

void Drives::eject(const QVariantMap &item) {
    setError({});
    const QString device = item.value("device").toString(), crypt = item.value("cryptDevice").toString();
    const QString disk = item.value("diskDevice").toString();
    // Power off the whole disk once it's let go, so it can be pulled out.
    auto powerOff = [this, disk](const QString &) {
        refresh();
        if (!disk.isEmpty())
            udisks({"power-off", "-b", disk}, [this](const QString &) { refresh(); });
    };
    auto lock = [this, crypt, powerOff](const QString &output) {
        if (crypt.isEmpty())
            powerOff(output);
        else
            udisks({"lock", "-b", crypt}, powerOff);
    };
    if (item.value("mounted").toBool())
        udisks({"unmount", "-b", device}, lock);
    else
        lock({});
}
