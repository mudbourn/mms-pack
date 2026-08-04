#!/bin/zsh
# mms-dev-setup — one-time setup for the hotswap dev client ("MMS Dev").
#
# Installs two things into ~/.mms-dev:
#   • JetBrains Runtime 21 — a JDK whose JVM supports enhanced class
#     redefinition (DCEVM). Stock JDKs only allow swapping method BODIES;
#     JBR also allows adding/removing methods and fields, which is what
#     makes hotswapping actually useful for mod work.
#   • hotswap-agent.jar — watches the class output dir and calls redefine
#     itself, so no IDE is needed to trigger the swap.
#
# The "MMS Dev" Prism instance is already pointed at both paths; it will not
# launch until this script has run.
#
# Usage:
#   ./mms-dev-setup.sh                 # resolve latest builds from GitHub
#   ./mms-dev-setup.sh <jbr-tar-url>   # pin a specific JBR build
set -e

DEV=~/.mms-dev
mkdir -p "$DEV"

# ── JetBrains Runtime ────────────────────────────────────────────────────────
# Since JBR 17 the DCEVM patches are folded into the standard builds, so any
# osx-aarch64 JBR works — there is no separate "_dcevm" variant to hunt for.
if [ -x "$DEV/jbr/Contents/Home/bin/java" ]; then
    echo "jbr: already installed ($("$DEV/jbr/Contents/Home/bin/java" -version 2>&1 | head -1))"
else
    url="$1"
    if [ -z "$url" ]; then
        echo "jbr: resolving latest osx-aarch64 build from GitHub…"
        url=$(curl -fsSL "https://api.github.com/repos/JetBrains/JetBrainsRuntime/releases?per_page=15" \
            | grep -oE '"browser_download_url": *"[^"]*"' \
            | sed 's/.*"browser_download_url": *"//; s/"$//' \
            | grep -E 'jbr-21.*osx-aarch64.*\.tar\.gz$' \
            | head -1)
    fi
    if [ -z "$url" ]; then
        echo "!! could not resolve a JBR 21 osx-aarch64 tarball." >&2
        echo "   Grab one from https://github.com/JetBrains/JetBrainsRuntime/releases" >&2
        echo "   and re-run:  ./mms-dev-setup.sh <url>" >&2
        exit 1
    fi
    echo "jbr: downloading $url"
    curl -fL --progress-bar -o "$DEV/jbr.tar.gz" "$url"

    rm -rf "$DEV/jbr.extract" "$DEV/jbr"
    mkdir -p "$DEV/jbr.extract"
    tar -xzf "$DEV/jbr.tar.gz" -C "$DEV/jbr.extract"

    # tarballs unpack as <something>/Contents/Home — find it and normalise the
    # path to ~/.mms-dev/jbr, which is what instance.cfg hardcodes.
    home=$(find "$DEV/jbr.extract" -maxdepth 3 -type d -path '*/Contents/Home' | head -1)
    if [ -z "$home" ]; then
        echo "!! unexpected JBR archive layout; no Contents/Home found." >&2
        exit 1
    fi
    mv "$(dirname "$(dirname "$home")")" "$DEV/jbr"
    rm -rf "$DEV/jbr.extract" "$DEV/jbr.tar.gz"

    # downloaded archives are quarantined by Gatekeeper; the JVM won't run until
    # the attribute is cleared
    xattr -dr com.apple.quarantine "$DEV/jbr" 2>/dev/null || true
    echo "jbr: installed — $("$DEV/jbr/Contents/Home/bin/java" -version 2>&1 | head -1)"
fi

# verify the JVM actually accepts the enhanced-redefinition flag; a plain JDK
# accidentally landing here would fail silently at swap time instead
if ! "$DEV/jbr/Contents/Home/bin/java" -XX:+AllowEnhancedClassRedefinition -version >/dev/null 2>&1; then
    echo "!! this JVM rejects -XX:+AllowEnhancedClassRedefinition — not a DCEVM-capable JBR." >&2
    exit 1
fi
echo "jbr: enhanced class redefinition supported ✓"

# ── HotswapAgent ─────────────────────────────────────────────────────────────
if [ -f "$DEV/hotswap-agent.jar" ]; then
    echo "hotswap-agent: already installed"
else
    echo "hotswap-agent: resolving latest release…"
    ha=$(curl -fsSL "https://api.github.com/repos/HotswapProjects/HotswapAgent/releases/latest" \
        | grep -oE '"browser_download_url": *"[^"]*hotswap-agent-[0-9.]+\.jar"' \
        | sed 's/.*"browser_download_url": *"//; s/"$//' | head -1)
    if [ -z "$ha" ]; then
        echo "!! could not resolve hotswap-agent.jar; download it from" >&2
        echo "   https://github.com/HotswapProjects/HotswapAgent/releases" >&2
        echo "   and save it as $DEV/hotswap-agent.jar" >&2
        exit 1
    fi
    curl -fL --progress-bar -o "$DEV/hotswap-agent.jar" "$ha"
    echo "hotswap-agent: installed"
fi

echo
echo "── done. Next: ──"
echo "  1. Restart Prism Launcher so it picks up the new 'MMS Dev' instance."
echo "  2. Start the pack server:   ./mms-dev-serve.sh"
echo "  3. Launch 'MMS Dev', connect to the test server."
echo "  4. Watch a mod for changes: ./mms-hotswap-watch.sh mms-mod-compat-support"
