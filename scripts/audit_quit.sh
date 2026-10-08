#!/bin/zsh
set -euo pipefail
root="${0:A:h:h}"
audit_dir=$(mktemp -d /tmp/findui-quit-audit.XXXXXX)
if [[ "${FINDUI_KEEP_QUIT_AUDIT:-0}" != 1 ]]; then trap 'rm -rf "$audit_dir"' EXIT; fi
mkdir -p "$root/.cache/quit-audit"
sources=("$root"/Sources/FindUI/*.swift)
sources=("${sources[@]:#*/FindUIApp.swift}")
app="$audit_dir/FindUI Quit Audit.app"
mkdir -p "$app/Contents/MacOS"
bash "$root/scripts/swiftc_with_search_core.sh" -disable-sandbox -swift-version 6 -parse-as-library \
  -module-cache-path /tmp/findui-clang-module-cache "${sources[@]}" "$root/scripts/audit_quit.swift" \
  -o "$app/Contents/MacOS/audit"
# A disposable search process that ignores SIGTERM exercises the real runner's
# escalation and reaping. Other scenarios have an empty filename search result.
cat > "$audit_dir/worker.c" <<'WORKER'
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int main(void) {
    const char *mode = getenv("FINDUI_QUIT_SCENARIO");
    if (!mode || strcmp(mode, "active-search")) return 0;
    signal(SIGTERM, SIG_IGN);
    alarm(30);
    char marker[4096];
    snprintf(marker, sizeof(marker), "%s/workers", getenv("FINDUI_CACHE_DIRECTORY"));
    FILE *file = fopen(marker, "a");
    if (!file) return 1;
    fprintf(file, "%d\n", getpid());
    fclose(file);
    for (;;) pause();
}
WORKER
clang "$audit_dir/worker.c" -o "$app/Contents/MacOS/fd"
codesign --force --sign - "$app/Contents/MacOS/fd"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.findui.quit-audit</string>
<key>CFBundleName</key><string>FindUI Quit Audit</string>
<key>CFBundleExecutable</key><string>audit</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - "$app"
scenarios=(command-q command-w close-button settings-close multiple-windows repeated-quit active-search modal-panel)
if (( $# )); then scenarios=("$@"); fi
for scenario in "${scenarios[@]}"; do
  fixture="$audit_dir/$scenario"
  mkdir -p "$fixture/data" "$fixture/files" "$fixture/cache"
  ruby -rjson -e 'root=ARGV.first; File.write(File.join(root,"data/library.json"), JSON.generate({defaultSearchDirectoryPath:File.join(root,"files"),history:[],managedIndexes:[],explicitConversionChoices:true,showIcons:true}))' "$fixture"
  log="$root/.cache/quit-audit/$scenario.log"
  # LaunchServices appends to these files. Never mistake an earlier run's
  # watchdog failure (or success) for this process's result.
  : > "$log"
  open -W -n --env "FINDUI_DATA_DIRECTORY=$fixture/data" --env "FINDUI_CACHE_DIRECTORY=$fixture/cache" \
    --env "FINDUI_QUIT_SCENARIO=$scenario" \
    --stdout "$log" --stderr "$log" "$app" --args "$scenario"
  if [[ -f "$fixture/cache/quit.sample" ]]; then
    cp "$fixture/cache/quit.sample" "$root/.cache/quit-audit/$scenario.sample"
  fi
  cat "$log"
  rg -q "^READY: $scenario with pending settings saved" "$log"
  if rg -q '^FAIL:' "$log"; then exit 1; fi
  printf 'PASS: %s process exited.\n' "$scenario"
  if [[ -f "$fixture/cache/workers" ]]; then
    ruby -e 'File.readlines(ARGV.first).each { |line| begin; Process.kill(0, Integer(line)); abort "FAIL: search worker survived quit"; rescue Errno::ESRCH; end }; puts "PASS: cancelled search workers were reaped before app exit."' "$fixture/cache/workers"
  fi
done
