CXX ?= g++
PKGS = hyprland libdrm libinput libudev pixman-1 wayland-server xkbcommon
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++2b -shared -fPIC -fno-gnu-unique $(shell pkg-config --cflags $(PKGS))
LDLIBS = $(shell pkg-config --libs $(PKGS))

SRC = main.cpp tabs.cpp

drag-events.so: $(SRC) tabs.hpp
	$(CXX) $(CXXFLAGS) $(SRC) -o $@ $(LDLIBS)

clean:
	rm -f drag-events.so

.PHONY: clean
