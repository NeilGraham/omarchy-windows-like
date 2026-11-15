CXX ?= g++
PKGS = hyprland libdrm libinput libudev pixman-1 wayland-server xkbcommon
CXXFLAGS ?= -O2
CXXFLAGS += -std=c++2b -shared -fPIC -fno-gnu-unique $(shell pkg-config --cflags $(PKGS))
LDLIBS = $(shell pkg-config --libs $(PKGS))

drag-events.so: main.cpp
	$(CXX) $(CXXFLAGS) main.cpp -o $@ $(LDLIBS)

clean:
	rm -f drag-events.so

.PHONY: clean
