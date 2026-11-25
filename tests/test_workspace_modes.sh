#!/bin/bash
# Exercise the real settings CLI with a disposable shell config and Hyprland IPC.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home" PATH="$tmp/bin:$PATH" HYPRLAND_INSTANCE_SIGNATURE=workspace-mode-test
mkdir -p "$tmp/bin" "$HOME/.config/omarchy" "$HOME/.config/omarchy-windows-like"
cat >"$tmp/bin/hyprctl" <<'MOCK'
#!/bin/bash
case "$*" in
  "-j activeworkspace") printf '{"id":%s}\n' "$(cat "$HOME/workspace")" ;;
  "reload") echo reload >>"$HOME/reloads" ;;
  *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/bin/hyprctl"

cli="$repo/bin/omarchy-windows-like"
shell="$HOME/.config/omarchy/shell.json"
settings="$HOME/.config/omarchy-windows-like/settings.json"
policy="$HOME/.local/state/omarchy-windows-like/workspace-policy.json"
native='{"bar":{"position":"top","layout":{"left":[{"id":"omarchy.menu"}]}},"disabledPlugins":["omarchy.dock","custom"]}'
printf '%s\n' "$native" >"$shell"
printf '[bar]\nsize-horizontal = 31 # my preference\n' >"$HOME/.config/omarchy/shell.toml"
echo '{"workspaces":{"startMode":"windows-like","scope":"selected","selected":[1,3]},"snapping":{"assist":false}}' >"$settings"

assert_windows_like() {
  jq -e '.bar.position == "bottom" and (.disabledPlugins | index("omarchy.dock") != null)' "$shell" >/dev/null
}
assert_native() {
  jq -e --argjson native "$native" '. == $native' "$shell" >/dev/null
  grep -Fxq 'size-horizontal = 31 # my preference' "$HOME/.config/omarchy/shell.toml"
}

echo 1 >"$HOME/workspace"
"$cli" apply
assert_windows_like
echo 3 >"$HOME/workspace"
"$cli" sync-mode
assert_windows_like
[[ $(wc -l <"$HOME/reloads") == 1 ]]

echo 2 >"$HOME/workspace"
"$cli" sync-mode
assert_native
"$cli" toggle-mode
assert_windows_like
jq -e '.overrides == {"2":"windows-like"}' "$policy" >/dev/null

# A subsequent login restores the previous toggle.
HYPRLAND_INSTANCE_SIGNATURE=workspace-mode-next-login "$cli" sync-mode
assert_windows_like
"$cli" toggle-mode
assert_native

# Changing the starting policy clears the saved overrides and preserves
# unrelated plugin settings.
jq '.workspaces.scope = "all"' "$settings" >"$tmp/settings.new"
mv "$tmp/settings.new" "$settings"
"$cli" apply
assert_windows_like
jq -e '.overrides == {}' "$policy" >/dev/null
jq -e '.snapping.assist == false' "$settings" >/dev/null
jq '.workspaces.startMode = "native"' "$settings" >"$tmp/settings.new"
mv "$tmp/settings.new" "$settings"
"$cli" apply
assert_native
printf '%s\n' 'PASS: workspace policies, persisted toggles, and native bar restoration'
