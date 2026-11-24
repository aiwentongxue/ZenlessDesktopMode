#!/bin/zsh
set -eu
project="${0:A:h:h}"
output="${1:-$project/.build/tests}"
mkdir -p "$output"
xcrun --sdk macosx clang++ -std=c++20 -Wall -Wextra -Werror \
    -I "$project/Sources" "$project/Tests/DesktopPolicyTests.cpp" \
    -o "$output/DesktopPolicyTests"
"$output/DesktopPolicyTests"
