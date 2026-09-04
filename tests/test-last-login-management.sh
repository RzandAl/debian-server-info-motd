#!/bin/bash

set -Eeuo pipefail

if ((EUID != 0)); then
    printf 'This test must run as root.\n' >&2
    exit 1
fi

REPOSITORY_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
readonly REPOSITORY_ROOT
TEST_DIRECTORY=$(mktemp -d "/tmp/debian-server-info-motd-test.XXXXXX")
readonly TEST_DIRECTORY
readonly TEST_ROOT="${TEST_DIRECTORY}/root"
readonly TEST_BIN="${TEST_DIRECTORY}/bin"
readonly TEST_INSTALLER="${TEST_DIRECTORY}/install.sh"
readonly TEST_OUTPUT="${TEST_DIRECTORY}/output"
readonly TEST_SERVICE_LOG="${TEST_DIRECTORY}/service.log"
readonly TEST_RELOAD_FAILURE="${TEST_DIRECTORY}/fail-reload-once"
readonly TEST_BASE_SETTING="${TEST_DIRECTORY}/base-print-last-log"
readonly TEST_LAST_LOGIN_CONFIG="${TEST_ROOT}/etc/ssh/sshd_config.d/00-debian-server-info-motd.conf"
readonly TEST_STATE_DIRECTORY="${TEST_ROOT}/var/lib/debian-server-info-motd"
readonly TEST_LAST_LOGIN_STATE="${TEST_STATE_DIRECTORY}/last-login.sha256"

cleanup() {
    rm -rf -- "$TEST_DIRECTORY"
}

trap cleanup EXIT

assert_absent() {
    local path=$1

    if [[ -e $path || -L $path ]]; then
        printf 'Expected an absent path: %s\n' "$path" >&2
        exit 1
    fi
}

assert_contains() {
    local expected=$1

    if ! grep -Fq -- "$expected" "$TEST_OUTPUT"; then
        printf 'Expected output was not found: %s\n' "$expected" >&2
        tail -n 30 -- "$TEST_OUTPUT" >&2
        exit 1
    fi
}

prepare_installer() {
    install -d -m 0755 -- "$TEST_BIN"
    cp -- "${REPOSITORY_ROOT}/install.sh" "$TEST_INSTALLER"

    sed -i \
        -e "s|^export PATH=.*|export PATH=\"${TEST_BIN}:/usr/sbin:/usr/bin:/sbin:/bin\"|" \
        -e "s|^readonly MOTD_DIRECTORY=.*|readonly MOTD_DIRECTORY=\"${TEST_ROOT}/etc/update-motd.d\"|" \
        -e "s|^readonly COMMAND_DIRECTORY=.*|readonly COMMAND_DIRECTORY=\"${TEST_ROOT}/usr/local/bin\"|" \
        -e "s|^readonly MOTD_FILE=.*|readonly MOTD_FILE=\"${TEST_ROOT}/etc/motd\"|" \
        -e "s|^readonly ISSUE_FILE=.*|readonly ISSUE_FILE=\"${TEST_ROOT}/etc/issue\"|" \
        -e "s|^readonly STATE_DIRECTORY=.*|readonly STATE_DIRECTORY=\"${TEST_STATE_DIRECTORY}\"|" \
        -e "s|^readonly SSHD_CONFIG_DIRECTORY=.*|readonly SSHD_CONFIG_DIRECTORY=\"${TEST_ROOT}/etc/ssh/sshd_config.d\"|" \
        -e 's|^readonly STEP_DELAY=.*|readonly STEP_DELAY="0"|' \
        -e "s|/etc/os-release|${TEST_ROOT}/etc/os-release|g" \
        "$TEST_INSTALLER"

    cat > "${TEST_BIN}/sshd" <<'MOCK_SSHD'
#!/bin/bash
set -Eeuo pipefail

case ${1:-} in
    -t)
        exit 0
        ;;
    -T)
        effective_value=$(< "$TEST_BASE_SETTING")

        if [[ -f $TEST_LAST_LOGIN_CONFIG ]]; then
            configured_value=$(
                awk '
                    tolower($1) == "printlastlog" {
                        print tolower($2)
                        exit
                    }
                ' "$TEST_LAST_LOGIN_CONFIG"
            )

            if [[ -n $configured_value ]]; then
                effective_value=$configured_value
            fi
        fi

        printf 'printlastlog %s\n' "$effective_value"
        ;;
    *)
        exit 1
        ;;
esac
MOCK_SSHD

    cat > "${TEST_BIN}/systemctl" <<'MOCK_SYSTEMCTL'
#!/bin/bash
set -Eeuo pipefail

case ${1:-} in
    is-active)
        exit 0
        ;;
    reload)
        printf 'reload-attempt\n' >> "$TEST_SERVICE_LOG"

        if [[ -e $TEST_RELOAD_FAILURE ]]; then
            rm -f -- "$TEST_RELOAD_FAILURE"
            exit 1
        fi

        printf 'reload-success\n' >> "$TEST_SERVICE_LOG"
        ;;
    *)
        exit 1
        ;;
esac
MOCK_SYSTEMCTL

    chmod 0755 -- \
        "$TEST_INSTALLER" \
        "${TEST_BIN}/sshd" \
        "${TEST_BIN}/systemctl"
}

prepare_fixture() {
    local command_checksum
    local payload_checksum

    rm -rf -- "$TEST_ROOT"
    install -d -m 0755 -- \
        "${TEST_ROOT}/etc/update-motd.d" \
        "${TEST_ROOT}/etc/ssh/sshd_config.d" \
        "${TEST_ROOT}/usr/local/bin" \
        "${TEST_STATE_DIRECTORY}/backup"
    chmod 0700 -- "$TEST_STATE_DIRECTORY"

    printf 'ID=debian\nNAME=Debian\nVERSION_ID=13\n' > \
        "${TEST_ROOT}/etc/os-release"
    : > "${TEST_ROOT}/etc/motd"
    : > "${TEST_ROOT}/etc/issue"

    install -m 0755 -- \
        "${REPOSITORY_ROOT}/etc/update-motd.d/10-server-info" \
        "${TEST_ROOT}/etc/update-motd.d/10-server-info"
    install -m 0755 -- \
        "${REPOSITORY_ROOT}/usr/local/bin/server-info" \
        "${TEST_ROOT}/usr/local/bin/server-info"

    payload_checksum=$(sha256sum -- \
        "${TEST_ROOT}/etc/update-motd.d/10-server-info")
    payload_checksum=${payload_checksum%% *}
    command_checksum=$(sha256sum -- \
        "${TEST_ROOT}/usr/local/bin/server-info")
    command_checksum=${command_checksum%% *}

    : > "${TEST_STATE_DIRECTORY}/installed"
    printf '2\n' > "${TEST_STATE_DIRECTORY}/state-format"
    printf 'main\n' > "${TEST_STATE_DIRECTORY}/source-ref"
    printf '0.3.0\n' > "${TEST_STATE_DIRECTORY}/version"
    printf '%s\n' "$payload_checksum" > \
        "${TEST_STATE_DIRECTORY}/payload.sha256"
    printf '%s\n' "$command_checksum" > \
        "${TEST_STATE_DIRECTORY}/command.sha256"
    : > "${TEST_STATE_DIRECTORY}/enabled-script-modes"

    printf 'no\n' > "$TEST_BASE_SETTING"
    : > "$TEST_SERVICE_LOG"
    rm -f -- "$TEST_RELOAD_FAILURE"
}

write_managed_state() {
    local managed_checksum

    managed_checksum=$(
        printf '%s\n' \
            '# Managed by Debian Server Info MOTD.' \
            'PrintLastLog yes' |
            sha256sum
    )
    managed_checksum=${managed_checksum%% *}
    printf '%s\n' "$managed_checksum" > "$TEST_LAST_LOGIN_STATE"
}

write_managed_config() {
    printf '%s\n' \
        '# Managed by Debian Server Info MOTD.' \
        'PrintLastLog yes' > "$TEST_LAST_LOGIN_CONFIG"
    chmod 0644 -- "$TEST_LAST_LOGIN_CONFIG"
}

assert_managed_config() {
    local actual_checksum
    local expected_checksum

    expected_checksum=$(
        printf '%s\n' \
            '# Managed by Debian Server Info MOTD.' \
            'PrintLastLog yes' |
            sha256sum
    )
    expected_checksum=${expected_checksum%% *}
    actual_checksum=$(sha256sum -- "$TEST_LAST_LOGIN_CONFIG")
    actual_checksum=${actual_checksum%% *}

    [[ $actual_checksum == "$expected_checksum" ]]
    [[ $(< "$TEST_LAST_LOGIN_STATE") == "$expected_checksum" ]]
    [[ $(stat -c '%U:%G:%a' -- "$TEST_LAST_LOGIN_CONFIG") == \
        'root:root:644' ]]
}

run_installer() {
    local expected_status=$1
    local input=$2
    local installer_status

    export TEST_BASE_SETTING
    export TEST_LAST_LOGIN_CONFIG
    export TEST_RELOAD_FAILURE
    export TEST_SERVICE_LOG

    set +e
    printf '%b' "$input" |
        script -qefc \
            "env NO_COLOR=1 bash '${TEST_INSTALLER}'" \
            /dev/null > "$TEST_OUTPUT" 2>&1
    installer_status=$?
    set -e

    if ((installer_status != expected_status)); then
        printf 'Expected installer status %s, got %s.\n' \
            "$expected_status" "$installer_status" >&2
        tail -n 40 -- "$TEST_OUTPUT" >&2
        exit 1
    fi
}

test_enable_unmanaged_setting() {
    prepare_fixture

    run_installer 0 '2\ny\n'

    assert_managed_config
    assert_contains \
        'OpenSSH Last login notices were enabled successfully.'
    [[ $(grep -Fc 'reload-success' "$TEST_SERVICE_LOG") -eq 1 ]]
}

test_stop_valid_management() {
    prepare_fixture
    write_managed_state
    write_managed_config

    run_installer 0 '2\ny\n'

    assert_absent "$TEST_LAST_LOGIN_CONFIG"
    assert_absent "$TEST_LAST_LOGIN_STATE"
    assert_contains \
        'OpenSSH Last login is no longer managed by Debian Server Info MOTD.'
    assert_contains 'Effective OpenSSH Last login setting: disabled.'
    [[ $(grep -Fc 'reload-success' "$TEST_SERVICE_LOG") -eq 1 ]]
}

test_stop_missing_management() {
    prepare_fixture
    write_managed_state

    run_installer 0 '2\n2\n'

    assert_absent "$TEST_LAST_LOGIN_CONFIG"
    assert_absent "$TEST_LAST_LOGIN_STATE"
    assert_contains \
        'OpenSSH Last login is no longer managed by Debian Server Info MOTD.'
    [[ ! -s $TEST_SERVICE_LOG ]]
}

test_stop_modified_management() {
    local original_attributes

    prepare_fixture
    write_managed_state
    printf '%s\n' \
        '# Kept as user-managed configuration.' \
        'PrintLastLog no' > "$TEST_LAST_LOGIN_CONFIG"
    chmod 0640 -- "$TEST_LAST_LOGIN_CONFIG"
    cp -a -- "$TEST_LAST_LOGIN_CONFIG" "${TEST_DIRECTORY}/modified.expected"
    original_attributes=$(stat -c '%u:%g:%a' -- "$TEST_LAST_LOGIN_CONFIG")

    run_installer 0 '2\n2\n'

    assert_absent "$TEST_LAST_LOGIN_STATE"
    cmp -s -- \
        "$TEST_LAST_LOGIN_CONFIG" \
        "${TEST_DIRECTORY}/modified.expected"
    [[ $(stat -c '%u:%g:%a' -- "$TEST_LAST_LOGIN_CONFIG") == \
        "$original_attributes" ]]
    [[ ! -s $TEST_SERVICE_LOG ]]
}

test_repair_modified_management() {
    prepare_fixture
    write_managed_state
    printf 'PrintLastLog no\n' > "$TEST_LAST_LOGIN_CONFIG"

    run_installer 0 '2\n1\n'

    assert_managed_config
    assert_contains \
        'OpenSSH Last login configuration was repaired successfully.'
    [[ $(grep -Fc 'reload-success' "$TEST_SERVICE_LOG") -eq 1 ]]
}

test_reload_failure_rolls_back() {
    local original_checksum
    local restored_checksum

    prepare_fixture
    write_managed_state
    write_managed_config
    original_checksum=$(sha256sum -- "$TEST_LAST_LOGIN_CONFIG")
    original_checksum=${original_checksum%% *}
    : > "$TEST_RELOAD_FAILURE"

    run_installer 1 '2\ny\n'

    [[ -f $TEST_LAST_LOGIN_CONFIG && ! -L $TEST_LAST_LOGIN_CONFIG ]]
    [[ -f $TEST_LAST_LOGIN_STATE && ! -L $TEST_LAST_LOGIN_STATE ]]
    restored_checksum=$(sha256sum -- "$TEST_LAST_LOGIN_CONFIG")
    restored_checksum=${restored_checksum%% *}
    [[ $restored_checksum == "$original_checksum" ]]
    [[ $(< "$TEST_LAST_LOGIN_STATE") == "$original_checksum" ]]
    assert_contains \
        'OpenSSH Last login configuration failed and all changes were rolled back.'
    [[ $(grep -Fc 'reload-attempt' "$TEST_SERVICE_LOG") -eq 2 ]]
    [[ $(grep -Fc 'reload-success' "$TEST_SERVICE_LOG") -eq 1 ]]
}

prepare_installer
test_enable_unmanaged_setting
test_stop_valid_management
test_stop_missing_management
test_stop_modified_management
test_repair_modified_management
test_reload_failure_rolls_back

printf 'OpenSSH Last login management tests: passed\n'
