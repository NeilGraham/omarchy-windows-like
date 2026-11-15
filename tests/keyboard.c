// A virtual keyboard for the nested tests, driven by lines on stdin:
//   down <keysym>   press a key, e.g. "down Control_L"
//   up <keysym>     release it
//   tap <keysym>    press and release
//   wait <ms>
//
// Unlike wtype, which uploads a keymap of its own with made-up keycodes, this
// uses the standard US keymap and real keycodes, so Hyprland's key bindings
// (resolved against its own keymap) see the keys a real keyboard would send.

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>
#include "keyboard-protocol.h"

static struct wl_seat *seat;
static struct zwp_virtual_keyboard_manager_v1 *manager;

static void global(void *data, struct wl_registry *registry, uint32_t name, const char *interface, uint32_t version) {
  if (!strcmp(interface, "zwp_virtual_keyboard_manager_v1"))
    manager = wl_registry_bind(registry, name, &zwp_virtual_keyboard_manager_v1_interface, 1);
  else if (!strcmp(interface, "wl_seat") && !seat)
    seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
}

static void removed(void *data, struct wl_registry *registry, uint32_t name) {}

static uint32_t now_ms(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// The first keycode whose level-1 or level-2 symbol is the named keysym.
static xkb_keycode_t find_key(struct xkb_keymap *keymap, const char *name) {
  const xkb_keysym_t want = xkb_keysym_from_name(name, XKB_KEYSYM_CASE_INSENSITIVE);
  if (want == XKB_KEY_NoSymbol)
    return 0;
  for (xkb_keycode_t kc = xkb_keymap_min_keycode(keymap); kc <= xkb_keymap_max_keycode(keymap); kc++) {
    for (xkb_level_index_t level = 0; level < 2; level++) {
      const xkb_keysym_t *syms;
      const int n = xkb_keymap_key_get_syms_by_level(keymap, kc, 0, level, &syms);
      for (int i = 0; i < n; i++)
        if (syms[i] == want)
          return kc;
    }
  }
  return 0;
}

int main(void) {
  struct wl_display *display = wl_display_connect(NULL);
  if (!display)
    return 1;
  struct wl_registry *registry = wl_display_get_registry(display);
  const struct wl_registry_listener listener = {global, removed};
  wl_registry_add_listener(registry, &listener, NULL);
  wl_display_roundtrip(display);
  if (!manager || !seat)
    return 3;

  struct xkb_context *ctx = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
  struct xkb_rule_names names = {.layout = "us"};
  struct xkb_keymap *keymap = xkb_keymap_new_from_names(ctx, &names, XKB_KEYMAP_COMPILE_NO_FLAGS);
  struct xkb_state *state = xkb_state_new(keymap);
  char *text = xkb_keymap_get_as_string(keymap, XKB_KEYMAP_FORMAT_TEXT_V1);
  const size_t size = strlen(text) + 1;
  const int fd = memfd_create("keymap", MFD_CLOEXEC);
  if (fd < 0 || ftruncate(fd, size) < 0)
    return 4;
  char *map = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
  memcpy(map, text, size);
  munmap(map, size);

  struct zwp_virtual_keyboard_v1 *kb = zwp_virtual_keyboard_manager_v1_create_virtual_keyboard(manager, seat);
  zwp_virtual_keyboard_v1_keymap(kb, WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1, fd, size);
  wl_display_roundtrip(display);

  char line[128], command[32], arg[64];
  while (fgets(line, sizeof(line), stdin)) {
    if (sscanf(line, "%31s %63s", command, arg) < 1)
      continue;
    if (!strcmp(command, "wait")) {
      usleep(atoi(arg) * 1000);
      continue;
    }
    const xkb_keycode_t kc = find_key(keymap, arg);
    if (!kc) {
      fprintf(stderr, "keyboard: unknown key %s\n", arg);
      return 5;
    }
    const int presses = !strcmp(command, "tap") ? 2 : 1;
    for (int p = 0; p < presses; p++) {
      const int down = !strcmp(command, "down") || (!strcmp(command, "tap") && p == 0);
      zwp_virtual_keyboard_v1_key(kb, now_ms(), kc - 8, down ? WL_KEYBOARD_KEY_STATE_PRESSED : WL_KEYBOARD_KEY_STATE_RELEASED);
      xkb_state_update_key(state, kc, down ? XKB_KEY_DOWN : XKB_KEY_UP);
      zwp_virtual_keyboard_v1_modifiers(kb, xkb_state_serialize_mods(state, XKB_STATE_MODS_DEPRESSED),
                                        xkb_state_serialize_mods(state, XKB_STATE_MODS_LATCHED),
                                        xkb_state_serialize_mods(state, XKB_STATE_MODS_LOCKED),
                                        xkb_state_serialize_layout(state, XKB_STATE_LAYOUT_EFFECTIVE));
      wl_display_roundtrip(display);
      usleep(20000);
    }
  }

  zwp_virtual_keyboard_v1_destroy(kb);
  wl_display_roundtrip(display);
  wl_display_disconnect(display);
  return 0;
}
