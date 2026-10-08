#!/bin/zsh
# Maintainer command. Recipients only unzip and open FindUI.app.
set -euo pipefail
root="${0:A:h:h}"
cd "$root"
if [[ "${1:-}" != "--skip-build" ]]; then zsh scripts/build_app.sh; fi
app="$root/dist/FindUI.app"
staging=$(mktemp -d "$root/dist/.package.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ruby scripts/audit_publication.rb --app "$app" --archive "$staging/FindUI-source.zip"
ruby scripts/verify_app.rb "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
archs=$(lipo -archs "$app/Contents/MacOS/FindUI")
for tool in FindUIApp findui-content fd rg fzf; do
  tool_archs=$(lipo -archs "$app/Contents/MacOS/$tool")
  [[ "$archs" == "$tool_archs" ]] || { echo "App and $tool architectures differ" >&2; exit 1; }
done
architecture="${archs// /-}"
name="FindUI-${version}-${architecture}.zip"
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --noextattr --noqtn --keepParent "$app" "$staging/$name"
/usr/bin/ditto -x -k "$staging/$name" "$staging/unpacked"
/usr/bin/codesign --verify --deep --strict "$staging/unpacked/FindUI.app"
cmp "$app/Contents/MacOS/FindUI" "$staging/unpacked/FindUI.app/Contents/MacOS/FindUI"
for tool in FindUIApp findui-content fd rg fzf; do cmp "$app/Contents/MacOS/$tool" "$staging/unpacked/FindUI.app/Contents/MacOS/$tool"; done
mv "$staging/$name" "$root/dist/$name"
mv "$staging/FindUI-source.zip" "$staging/FindUI-source.zip.sha256" "$root/dist/"
(cd "$root/dist" && /usr/bin/shasum -a 256 "$name" > "$name.sha256")
ruby -rjson -rdigest -e 'app,zip,arch=ARGV; executables=%w[FindUI FindUIApp findui-content fd rg fzf].to_h { |n| [n,Digest::SHA256.file(File.join(app,"Contents/MacOS",n)).hexdigest] }; puts JSON.pretty_generate({architectures:arch.split,minimumMacOS:"14.0",archive:File.basename(zip),sha256:Digest::SHA256.file(zip).hexdigest,executables:executables})' "$app" "$root/dist/$name" "$archs" > "$root/dist/$name.json"
echo "$root/dist/$name"
echo "$root/dist/FindUI-source.zip"
