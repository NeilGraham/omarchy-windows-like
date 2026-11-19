QT += core gui qml quick quickcontrols2

CONFIG += c++17 release
TARGET = windows-like-settings
TEMPLATE = app

HEADERS += \
    src/backend.h \
    src/drives.h \
    src/monitors.h \
    src/theme.h \
    src/translator.h

SOURCES += \
    src/main.cpp \
    src/backend.cpp \
    src/drives.cpp \
    src/monitors.cpp \
    src/theme.cpp \
    src/translator.cpp

RESOURCES += src/resources.qrc
