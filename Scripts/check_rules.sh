#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test_binary="$(mktemp -t daytape-rules.XXXXXX)"
trap 'rm -f "$test_binary"' EXIT HUP INT TERM
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -pedantic -IShared Shared/RecorderRules.c Tests/RulesTests.c -lm -o "$test_binary"
"$test_binary"
