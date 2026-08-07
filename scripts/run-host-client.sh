#!/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

while getopts ":c:n:k" opt; do
    case "$opt" in
        c) BUILD_TYPE="$OPTARG" ;;
        n) NUM_CLIENTS="$OPTARG" ;;
        k) JUST_KILL=1 ;;
        :) echo "Option -$OPTARG requires an argument" >&2; exit 1 ;;
        \?) echo "Unknown option: -$OPTARG" >&2; exit 1 ;;
    esac
done

BUILD_TYPE=${BUILD_TYPE:-debug}
NUM_CLIENTS=${NUM_CLIENTS:-10}
JUST_KILL=${JUST_KILL:-0}

BUILD_DIR=.build/x86_64-unknown-linux-gnu/${BUILD_TYPE}
PIDS=()

pkill -9 -f ArenaDemo || true
pkill -9 -f HelloWorld || true

[[ "$JUST_KILL" == "1" ]] && exit 0

swift build --configuration $BUILD_TYPE

cleanup() {
    echo
    echo "Stopping processes..."

    if ((${#PIDS[@]})); then
        kill "${PIDS[@]}" 2>/dev/null || true
        wait "${PIDS[@]}" 2>/dev/null || true
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

CANVAS_VK_VALIDATION=1 "$BUILD_DIR/ArenaDemo" host &
PIDS+=($!)
sleep 3
for run in $(seq 1 "$NUM_CLIENTS"); do
  LAVA_CLIENT=1 "$BUILD_DIR/HelloWorld" > /tmp/hello_world_$run.log 2>&1 &
  PIDS+=("$!")
  sleep 0.5
done

echo "Running. Press Ctrl+C to stop."

wait