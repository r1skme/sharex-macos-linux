#!/usr/bin/env bash
# Build self-contained Linux packages for the current CPU.
# Usage: Scripts/package-linux.sh [OUTPUT_DIR]
set -euo pipefail

out="${1:-artifacts}"
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
version="$(sed -n 's:.*<Version>\(.*\)</Version>.*:\1:p' "$repo/Directory.Build.props" | head -1)"

case "$(uname -m)" in
  x86_64) rid=linux-x64; platform=x64; deb_arch=amd64; rpm_arch=x86_64 ;;
  aarch64|arm64) rid=linux-arm64; platform=ARM64; deb_arch=arm64; rpm_arch=aarch64 ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT
mkdir -p "$out"
out="$(cd "$out" && pwd)"

echo "Building ShareX $version for $rid..."
dotnet publish "$repo/ShareX/ShareX.csproj" -c Release -r "$rid" --self-contained true \
  -p:Platform="$platform" -p:PublishTrimmed=false -p:DebugType=none -p:DebugSymbols=false -o "$staging/publish"

portable_name="ShareX-$version-$rid"
portable="$staging/$portable_name"
mkdir -p "$portable"
cp -R "$staging/publish" "$portable/app"
cp "$repo/ShareX.HelpersLib/Resources/ShareX_Logo.png" "$portable/sharex.png"
cp "$repo/Scripts/install-linux.sh" "$portable/install.sh"
chmod +x "$portable/install.sh"
tar -C "$staging" -czf "$out/$portable_name.tar.gz" "$portable_name"
cp "$out/$portable_name.tar.gz" "$out/$portable_name.tgz"

package_root="$staging/root"
mkdir -p "$package_root/opt/sharex/app" "$package_root/usr/bin" \
  "$package_root/usr/share/applications" "$package_root/usr/share/icons/hicolor/256x256/apps"
cp -R "$staging/publish/." "$package_root/opt/sharex/app/"
cp "$repo/ShareX.HelpersLib/Resources/ShareX_Logo.png" \
  "$package_root/usr/share/icons/hicolor/256x256/apps/sharex.png"

cat > "$package_root/usr/bin/sharex" <<'LAUNCHER'
#!/bin/sh
exec /opt/sharex/app/ShareX "$@"
LAUNCHER
chmod +x "$package_root/usr/bin/sharex" "$package_root/opt/sharex/app/ShareX"

cat > "$package_root/usr/share/applications/sharex.desktop" <<'DESKTOP'
[Desktop Entry]
Type=Application
Name=ShareX
GenericName=Screenshot and upload tool
Comment=Capture, annotate and share screenshots
Exec=/usr/bin/sharex %F
Icon=sharex
Terminal=false
StartupWMClass=ShareX
Categories=Graphics;Utility;
Actions=Region;FullScreen;Window;

[Desktop Action Region]
Name=Capture region
Exec=/usr/bin/sharex -RectangleRegion

[Desktop Action FullScreen]
Name=Capture full screen
Exec=/usr/bin/sharex -PrintScreen

[Desktop Action Window]
Name=Capture active window
Exec=/usr/bin/sharex -ActiveWindow
DESKTOP

deb="$staging/deb"
mkdir -p "$deb/DEBIAN"
installed_size="$(du -sk "$package_root" | cut -f1)"
cat > "$deb/DEBIAN/control" <<CONTROL
Package: sharex
Version: $version
Section: graphics
Priority: optional
Architecture: $deb_arch
Installed-Size: $installed_size
Maintainer: ShareX Team <https://getsharex.com>
Homepage: https://github.com/ShareX/ShareX
License: GPL-3.0-or-later
Recommends: ffmpeg, tesseract-ocr, libnotify-bin
Description: Screenshot, file sharing and productivity tool
 ShareX captures and annotates screenshots, records the screen and runs
 configurable after-capture workflows.
CONTROL
cp -R "$package_root/." "$deb/"
cat > "$deb/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
exit 0
POSTINST
cat > "$deb/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
exit 0
POSTRM
chmod 755 "$deb/DEBIAN/postinst" "$deb/DEBIAN/postrm"

deb_path="$out/ShareX-$version-$rid.deb"
if command -v dpkg-deb >/dev/null; then
  dpkg-deb --root-owner-group --build "$deb" "$deb_path"
else
  mkdir -p "$staging/deb-parts/control"
  cp "$deb/DEBIAN/control" "$deb/DEBIAN/postinst" "$deb/DEBIAN/postrm" "$staging/deb-parts/control/"
  printf '2.0\n' > "$staging/deb-parts/debian-binary"
  tar -C "$staging/deb-parts/control" --owner=0 --group=0 -czf "$staging/deb-parts/control.tar.gz" .
  tar -C "$package_root" --owner=0 --group=0 -czf "$staging/deb-parts/data.tar.gz" .
  (cd "$staging/deb-parts" && ar r "$deb_path" debian-binary control.tar.gz data.tar.gz)
fi

rpm_top="$staging/rpmbuild"
mkdir -p "$rpm_top/BUILD" "$rpm_top/BUILDROOT" "$rpm_top/RPMS" "$rpm_top/SOURCES" "$rpm_top/SPECS" "$rpm_top/SRPMS"
cat > "$rpm_top/SPECS/sharex.spec" <<SPEC
Name: sharex
Version: $version
Release: 1
Summary: Screenshot, file sharing and productivity tool
License: GPL-3.0-or-later
URL: https://github.com/ShareX/ShareX
BuildArch: $rpm_arch
AutoReqProv: no

%description
ShareX captures and annotates screenshots, records the screen and runs
configurable after-capture workflows.

%install
mkdir -p %{buildroot}
cp -a %{sharex_root}/. %{buildroot}/

%files
/opt/sharex
/usr/bin/sharex
/usr/share/applications/sharex.desktop
/usr/share/icons/hicolor/256x256/apps/sharex.png

%post
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true

%postun
command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database /usr/share/applications || true
SPEC

rpmbuild --quiet -bb "$rpm_top/SPECS/sharex.spec" --define "_topdir $rpm_top" --define "sharex_root $package_root"
rpm_source="$(find "$rpm_top/RPMS" -name '*.rpm' -type f -print -quit)"
test -n "$rpm_source"
cp "$rpm_source" "$out/ShareX-$version-$rid.rpm"

echo "Packages written to $out"
ls -1 "$out"/ShareX-"$version"-"$rid".*
