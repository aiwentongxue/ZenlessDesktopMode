#!/bin/zsh
set -eu

project="${0:A:h:h}"
output="${1:-$project/.build}"
mkdir -p "$output"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
support="$sdk/System/iOSSupport/System/Library/Frameworks"
work="$(mktemp -d "$output/.build-plugin.XXXXXX")"
trap 'rm -f -- "$work/EmbeddedCursor.hpp" "$work/libZenlessDesktopMode.dylib"; rmdir -- "$work"' EXIT
flags=()

if [[ -n "${ZZZDM_CURSOR_PNG:-}" ]]; then
    cursor="$ZZZDM_CURSOR_PNG"
    if [[ ! -f "$cursor" ]] || [[ "$(stat -f %z "$cursor")" -gt 1048576 ]]; then
        print -u2 'ZZZDM_CURSOR_PNG must be a PNG file of at most 1 MiB.'
        exit 1
    fi
    metadata="$(LC_ALL=C sips -g format -g pixelWidth -g pixelHeight "$cursor")"
    if ! /usr/bin/grep -qx '  format: png' <<< "$metadata" ||
       ! /usr/bin/grep -qx '  pixelWidth: 64' <<< "$metadata" ||
       ! /usr/bin/grep -qx '  pixelHeight: 64' <<< "$metadata"; then
        print -u2 'ZZZDM_CURSOR_PNG must be a 64×64 PNG.'
        exit 1
    fi
    {
        print -r -- 'constexpr unsigned char EmbeddedCursorPNG[] = {'
        /usr/bin/xxd -i < "$cursor"
        print -r -- '};'
    } > "$work/EmbeddedCursor.hpp"
    flags=(-DZZZDM_EMBED_CURSOR -I "$work")
fi

name=libZenlessDesktopMode.dylib
xcrun --sdk macosx clang++ -dynamiclib -std=c++20 -O2 -fobjc-arc \
    -target arm64-apple-ios15.0-macabi -isysroot "$sdk" -iframework "$support" -F"$support" \
    -framework Foundation -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -framework GameController -framework ImageIO -Wall -Wextra -Werror -fvisibility=hidden \
    -install_name "@rpath/$name" "${flags[@]}" "$project"/Sources/*.mm -o "$work/$name"

codesign --force --sign - --identifier io.zenless.desktopmode "$work/$name"
codesign --verify --strict "$work/$name"
mv -f -- "$work/$name" "$output/$name"
print -r -- "$output/$name"
