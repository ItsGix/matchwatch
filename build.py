#!/usr/bin/env python3
"""Bundle files/ and luci-app-matchwatch/ into one self-contained installer for OpenWrt."""
import os

CORE = "files"
LUCI_ROOT = "luci-app-matchwatch/root"
LUCI_WWW = "luci-app-matchwatch/htdocs"
LIB = "/usr/lib/matchwatch"
RES = "/www/luci-static/resources"

# (source, where it goes on the router, mode)
items = [
    (f"{CORE}/matchwatch", "/usr/bin/matchwatch", "755"),
    (f"{CORE}/analyze.awk", f"{LIB}/analyze.awk", "644"),
    (f"{CORE}/report.awk", f"{LIB}/report.awk", "644"),
    (f"{CORE}/public.html", f"{LIB}/public.html", "644"),
    (f"{CORE}/matchwatch.config", f"{LIB}/config.uci", "644"),
    (f"{CORE}/regions.list", f"{LIB}/regions.list", "644"),
    (f"{CORE}/geofeeds.list", f"{LIB}/geofeeds.list", "644"),
    (f"{CORE}/countries.list", f"{LIB}/countries.list", "644"),
    (f"{CORE}/places.list", f"{LIB}/places.list", "644"),
    (f"{CORE}/games.list", f"{LIB}/games.list", "644"),
    (f"{CORE}/matchwatch.init", "/etc/init.d/matchwatch", "755"),
    (f"{LUCI_ROOT}/usr/libexec/rpcd/luci.matchwatch", "/usr/libexec/rpcd/luci.matchwatch", "755"),
    (f"{LUCI_ROOT}/usr/share/luci/menu.d/luci-app-matchwatch.json", "/usr/share/luci/menu.d/luci-app-matchwatch.json", "644"),
    (f"{LUCI_ROOT}/usr/share/rpcd/acl.d/luci-app-matchwatch.json", "/usr/share/rpcd/acl.d/luci-app-matchwatch.json", "644"),
    (f"{LUCI_WWW}/luci-static/resources/matchwatch/dashboard.js", f"{RES}/matchwatch/dashboard.js", "644"),
    (f"{LUCI_WWW}/luci-static/resources/matchwatch/dashboard.css", f"{RES}/matchwatch/dashboard.css", "644"),
    (f"{LUCI_WWW}/luci-static/resources/view/matchwatch/dashboard.js", f"{RES}/view/matchwatch/dashboard.js", "644"),
    (f"{LUCI_WWW}/luci-static/resources/view/matchwatch/settings.js", f"{RES}/view/matchwatch/settings.js", "644"),
]
# left behind by versions before 0.10.0, or made by the service at run time
stale = [f"{LIB}/index.html", f"{LIB}/config.default", "/www/cgi-bin/matchwatch-api"]
runtime = ["/www/matchwatch/index.html", "/www/matchwatch/data", "/www/cgi-bin/matchwatch-mark"]
# only ever removed when empty
our_dirs = [LIB, "/www/matchwatch", f"{RES}/matchwatch", f"{RES}/view/matchwatch"]


def quoted(paths):
    return " ".join(f'"$R{p}"' for p in paths)


installed = [dst for _, dst, _ in items]
make_dirs = sorted({os.path.dirname(dst) for dst in installed} | {"/etc/matchwatch", "/etc/config"})

head = r'''#!/bin/sh
# matchwatch installer for OpenWrt. One file; contains everything, including the LuCI app.
#   sh matchwatch-install.sh [gaming-device-ip]   install or update
#   sh matchwatch-install.sh remove               uninstall (keeps your history and settings)
#   sh matchwatch-install.sh purge                uninstall and delete history and settings
R="${MW_ROOT:-}"

luci_refresh() {
	rm -f /tmp/luci-indexcache* 2>/dev/null
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload
}

if [ "$1" = remove ] || [ "$1" = purge ]; then
	[ -z "$R" ] && [ -x /etc/init.d/matchwatch ] && { /etc/init.d/matchwatch stop; /etc/init.d/matchwatch disable; }
	[ -z "$R" ] && nft delete table inet matchwatch 2>/dev/null
	rm -f @INSTALLED@
	rm -f @STALE@ @RUNTIME@
	rmdir @DIRS@ 2>/dev/null
	[ -z "$R" ] && luci_refresh
	if [ "$1" = purge ]; then
		rm -f "$R/etc/config/matchwatch" "$R/etc/matchwatch/config" "$R/etc/matchwatch/config.imported" "$R/etc/matchwatch/sessions.tsv" "$R/etc/matchwatch/blocklist" "$R/etc/matchwatch/geo.cache" "$R/etc/matchwatch/last.txt" "$R/etc/matchwatch/token" "$R/etc/matchwatch/stay" "$R/etc/matchwatch/regions.tsv" "$R/etc/matchwatch/games.local" "$R/etc/matchwatch/regions.local" "$R/etc/matchwatch/ratings.shared" "$R/etc/matchwatch/favourites" "$R/etc/matchwatch/tried" "$R/etc/matchwatch/gameplaces.shared" "$R/etc/matchwatch/ranges.cache" "$R/etc/matchwatch/cities.cache" "$R/etc/matchwatch/geofeeds.local"
		rm -rf "$R/etc/matchwatch/share.undo"
		for f in "$R"/etc/matchwatch/matches/*.json; do [ -f "$f" ] && rm -f "$f"; done
		rmdir "$R/etc/matchwatch/matches" 2>/dev/null
		rmdir "$R/etc/matchwatch" 2>/dev/null
		echo "matchwatch removed, history and settings deleted."
	else
		echo "matchwatch removed. History kept in /etc/matchwatch, settings in /etc/config/matchwatch."
	fi
	exit 0
fi

[ -z "$R" ] && [ "$(id -u)" != 0 ] && { echo "Run this as root on the router."; exit 1; }
[ -z "$R" ] && [ ! -f /etc/openwrt_release ] && echo "Warning: this does not look like OpenWrt. Continuing anyway."
[ -z "$R" ] && [ ! -d /usr/share/luci/menu.d ] && echo "Warning: LuCI was not found. The dashboard lives in LuCI; without it only the commands work."

if [ -z "$R" ]; then
	for pkg in tcpdump traceroute; do
		command -v "$pkg" >/dev/null 2>&1 && continue
		[ "$pkg" = traceroute ] && continue
		echo "Installing $pkg..."
		if command -v apk >/dev/null 2>&1; then apk update >/dev/null 2>&1; apk add tcpdump || apk add tcpdump-mini
		elif command -v opkg >/dev/null 2>&1; then opkg update >/dev/null 2>&1; opkg install tcpdump || opkg install tcpdump-mini
		fi
	done
	command -v tcpdump >/dev/null 2>&1 || { echo "Could not install tcpdump. Install it by hand, then run this again."; exit 1; }
fi

mkdir -p @MKDIRS@
'''
tail = r'''
rm -f @STALE@
if [ ! -f "$R/etc/config/matchwatch" ]; then
	cp "$R/usr/lib/matchwatch/config.uci" "$R/etc/config/matchwatch"
	echo "Created /etc/config/matchwatch"
fi
if [ -z "$R" ]; then
	/usr/bin/matchwatch _migrate
	case "$1" in
		[0-9]*.[0-9]*.[0-9]*.[0-9]*)
			uci set "matchwatch.main.device_ip=$1" && uci commit matchwatch
			echo "Watching device $1" ;;
	esac
	grep -q '^/etc/matchwatch/' /etc/sysupgrade.conf 2>/dev/null || echo "/etc/matchwatch/" >> /etc/sysupgrade.conf
	luci_refresh
	/etc/init.d/matchwatch enable
	/etc/init.d/matchwatch restart
	sleep 2
	/usr/bin/matchwatch doctor
	echo
	echo "Installed. In LuCI, open Services, then MatchWatch."
	echo "If you were already logged in to LuCI, log out and in again so the new page appears."
	echo "Play a match, then open the dashboard."
else
	echo "Installed into $R"
fi
'''
fill = {"@INSTALLED@": quoted(installed), "@STALE@": quoted(stale), "@RUNTIME@": quoted(runtime),
        "@DIRS@": quoted(our_dirs), "@MKDIRS@": quoted(make_dirs)}
for k, v in fill.items():
    head, tail = head.replace(k, v), tail.replace(k, v)

out = [head]
for i, (src, dst, mode) in enumerate(items):
    body = open(src, encoding="utf-8").read()
    assert body.strip(), f"{src} is empty"
    tag = f"MW_FILE_END_{i}"
    assert tag not in body
    if not body.endswith("\n"): body += "\n"
    # written beside the old file and then moved over it: the update button runs this installer from
    # the very script being replaced, and a shell reading a file that is rewritten under it goes wrong
    out.append(f"cat > \"$R{dst}.new\" <<'{tag}'\n{body}{tag}\nchmod {mode} \"$R{dst}.new\"\nmv -f \"$R{dst}.new\" \"$R{dst}\"\n")
out.append(tail)
os.makedirs("dist", exist_ok=True)
# newline="\n": on Windows the default would write CRLF, which the router's shell cannot run
with open("dist/matchwatch-install.sh", "w", encoding="utf-8", newline="\n") as f:
    f.write("".join(out))
# what `matchwatch update` reads: the version, and the installer's SHA-256 so a cut-short download is caught
import hashlib, re
version = re.search(r'^VERSION="([0-9.]+)"$', open(f"{CORE}/matchwatch", encoding="utf-8").read(), re.M).group(1)
digest = hashlib.sha256(open("dist/matchwatch-install.sh", "rb").read()).hexdigest()
with open("dist/version", "w", encoding="utf-8", newline="\n") as f:
    f.write(f"{version} {digest}\n")
print("built", os.path.getsize("dist/matchwatch-install.sh"), "bytes from", len(items), "files")
