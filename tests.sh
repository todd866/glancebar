#!/bin/zsh
# Compile and run Glancebar's pure-function unit tests.
set -e
cd "$(dirname "$0")"
clang -fobjc-arc -ISources Sources/pure.m Tests/test_pure.m \
    -framework Foundation -o /tmp/glancebar_tests
exec /tmp/glancebar_tests
