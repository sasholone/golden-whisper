#!/usr/bin/env bash
# build.sh [--check]  ->  python3 build.py
exec python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build.py" "$@"
