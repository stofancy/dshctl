#!/usr/bin/env bash
# 在临时目录验证 repair 流程；systemctl/npm/curl 使用替身，不操作本机服务。
# 0.6 起没有槽位：repair 只重建单元，不再理会任何 drop-in 或本地槽位。
set -eu
repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT

setup() {
    source "$repo_dir/dshctl"
    fixture="$test_dir/$1"
    UNIT_FILE="$fixture/systemd/$UNIT"
    STATE_DIR="$fixture/state"
    calls="$fixture/calls"
    mkdir -p "$(dirname "$UNIT_FILE")" "$STATE_DIR" "$fixture/npm/bin" "$UNIT_FILE.d"
    printf '#!/bin/sh\nexit 0\n' > "$fixture/npm/bin/dsh"
    chmod +x "$fixture/npm/bin/dsh"
    printf 'old unit\n' > "$UNIT_FILE"
    # 别人写的 drop-in：repair 不能动它。
    printf '[Service]\nEnvironment=KEEP_ME=yes\n' > "$UNIT_FILE.d/90-custom.conf"
    printf 'keep channel and data\n' > "$STATE_DIR/data"
    : > "$calls"
    reload_status=0
    restart_status=0
    reset_status=0
    failed_status=0
    DSHCTL_HEALTH_TRIES=1
}

npm() {
    [ "$*" = 'prefix -g' ] || { echo "unexpected npm action: $*" >&2; return 99; }
    printf '%s/npm\n' "$fixture"
}
systemctl() {
    printf '%s\n' "$*" >> "$calls"
    case "$*" in
        '--user daemon-reload') return "$reload_status" ;;
        '--user reset-failed '*) return "$reset_status" ;;
        '--user is-failed --quiet '*) return "$failed_status" ;;
        '--user restart '*) return "$restart_status" ;;
        '--user is-active --quiet '*) return 0 ;;
        *) echo "unexpected systemctl action: $*" >&2; return 99 ;;
    esac
}
curl() { printf '401'; }
spinner() { shift 2; "$@"; }

expect_status() {
    local expected="$1" actual=0
    shift
    "$@" > "$fixture/output" 2>&1 || actual=$?
    [ "$actual" = "$expected" ] || {
        cat "$fixture/output" >&2
        echo "expected status $expected, got $actual" >&2
        return 1
    }
}
assert_preserved() {
    [ "$(cat "$STATE_DIR/data")" = 'keep channel and data' ]
    [ "$(cat "$UNIT_FILE.d/90-custom.conf")" = $'[Service]\nEnvironment=KEEP_ME=yes' ]
}
assert_no_call() {
    if grep -E -- "$1" "$calls"; then
        echo "unexpected service action" >&2
        return 1
    fi
}

test_repair() {
    setup repair
    expect_status 0 main repair
    grep -Fxq "ExecStart=$fixture/npm/bin/dsh web --host 127.0.0.1 --port 3080" "$UNIT_FILE"
    [ "$(cat "$STATE_DIR"/service-backup.*/dsh-web.service)" = 'old unit' ]
    grep -Fxq -- '--user reset-failed dsh-web.service' "$calls"
    grep -Fxq -- '--user restart dsh-web.service' "$calls"
    assert_preserved
}
test_read_only() {
    setup read_only
    expect_status 0 main repair --dry-run
    expect_status 0 main repair --help
    grep -Fq 'dshctl repair [--dry-run] [--no-restart]' "$fixture/output"
    expect_status 2 main repair extra
    expect_status 2 main repair --docker
    expect_status 2 main repair --unknown
    [ ! -s "$calls" ]
    [ "$(cat "$UNIT_FILE")" = 'old unit' ]
    [ "$(find "$STATE_DIR" -mindepth 1 | wc -l)" = 1 ]
    assert_preserved
}
test_missing_package() {
    setup missing_package
    rm "$fixture/npm/bin/dsh"
    expect_status 1 main repair
    [ ! -s "$calls" ]
    [ "$(cat "$UNIT_FILE")" = 'old unit' ]
    [ "$(find "$STATE_DIR" -mindepth 1 | wc -l)" = 1 ]
}
test_missing_unit() {
    setup missing_unit
    rm "$UNIT_FILE"
    failed_status=1
    expect_status 0 main repair
    [ -f "$UNIT_FILE" ]
    assert_no_call 'reset-failed'
    grep -Fxq -- '--user restart dsh-web.service' "$calls"
}
test_linked_unit() {
    setup linked_unit
    mv "$UNIT_FILE" "$fixture/original.service"
    ln -s "$fixture/original.service" "$UNIT_FILE"
    expect_status 0 main repair --no-restart
    [ ! -L "$UNIT_FILE" ]
    [ "$(cat "$fixture/original.service")" = 'old unit' ]
    [ -L "$STATE_DIR"/service-backup.*/dsh-web.service ]
}
test_failures() {
    setup backup_failure
    STATE_DIR="$fixture/not-a-directory"
    touch "$STATE_DIR"
    expect_status 1 main repair
    [ ! -s "$calls" ]
    [ "$(cat "$UNIT_FILE")" = 'old unit' ]
    setup reload_failure
    reload_status=1
    expect_status 1 main repair
    assert_no_call 'restart|reset-failed'
    [ "$(cat "$STATE_DIR"/service-backup.*/dsh-web.service)" = 'old unit' ]
    setup reset_failure
    reset_status=1
    expect_status 1 main repair
    assert_no_call '--user restart'
    setup restart_failure
    restart_status=1
    expect_status 1 main repair
    setup health_failure
    DSHCTL_HEALTH_TRIES=0
    expect_status 1 main repair
}

for test in repair read_only missing_package missing_unit linked_unit failures; do
    ("test_$test")
    printf 'PASS %s\n' "$test"
done
