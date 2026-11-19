QT += core gui qml quick quickcontrols2 testlib
CONFIG += c++17 testcase
TARGET = windows-like-settings_tests
TEMPLATE = app

INCLUDEPATH += ../src

HEADERS += ../src/backend.h ../src/drives.h ../src/monitors.h ../src/theme.h ../src/translator.h
SOURCES += windows-like-settings_tests.cpp ../src/backend.cpp ../src/drives.cpp ../src/monitors.cpp ../src/theme.cpp ../src/translator.cpp
RESOURCES += ../src/resources.qrc
DEFINES += SRCDIR=\\\"$$PWD\\\"
