#!/bin/bash

set -Eeuo pipefail

export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C

umask 077

readonly PROJECT_NAME="Debian Server Info MOTD"
readonly PROJECT_ID="debian-server-info-motd"
readonly REPOSITORY="RzandAl/debian-server-info-motd"
readonly DEFAULT_SOURCE_REF="main"
readonly PAYLOAD_PATH="etc/update-motd.d/10-server-info"
readonly COMMAND_PATH="usr/local/bin/server-info"
readonly CHECKSUM_PATH="SHA256SUMS"
readonly VERSION_PATH="VERSION"
readonly VERSION_PATTERN='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'

readonly MOTD_DIRECTORY="/etc/update-motd.d"
readonly TARGET_FILE="${MOTD_DIRECTORY}/10-server-info"
readonly COMMAND_DIRECTORY="/usr/local/bin"
readonly COMMAND_FILE="${COMMAND_DIRECTORY}/server-info"
readonly MOTD_FILE="/etc/motd"
readonly ISSUE_FILE="/etc/issue"
readonly STATE_DIRECTORY="/var/lib/${PROJECT_ID}"
readonly CURRENT_STATE_FORMAT="2"
readonly SSHD_CONFIG_DIRECTORY="/etc/ssh/sshd_config.d"
readonly LAST_LOGIN_CONFIG_FILE="${SSHD_CONFIG_DIRECTORY}/00-${PROJECT_ID}.conf"

readonly STEP_DELAY="0.4"
readonly DEBUG_LINE_DELAY="0.1"

step_count=4
temporary_directory=""
state_work_directory=""
backup_directory=""
mode_file=""
rollback_directory=""
rollback_mode_file=""
target_temp_file=""
command_temp_file=""
state_checksum_temp=""
state_command_checksum_temp=""
state_source_ref_temp=""
state_version_temp=""
state_last_login_checksum_temp=""
last_login_config_temp=""
downloaded_script=""
downloaded_command=""
downloaded_checksums=""
downloaded_version=""
expected_checksum=""
expected_command_checksum=""
expected_version_checksum=""
actual_checksum=""
actual_command_checksum=""
actual_version_checksum=""
installed_checksum=""
installed_command_checksum=""
installed_source_ref=""
installed_version=""
installed_state_format=""
source_version=""
verification_checksum=""
selected_action=""
menu_choice=""
target_status="unknown"
command_status="unknown"
last_login_config_status="unmanaged"
last_login_effective="unavailable"
last_login_reload_method=""
last_login_requested=0
last_login_managed=0
last_login_change_started=0
installed_last_login_checksum=""
desired_last_login_checksum=""
motd_directory_preexisted=1
command_directory_preexisted=1
active_operation="Installation"
operation_key="install"
changes_started=0
step_active=0
debug_mode=0
debug_pacing=0
preserve_temporary=0
source_ref="$DEFAULT_SOURCE_REF"
source_ref_seen=0

saved_script_modes=()
saved_script_names=()

print_usage() {
    printf 'Usage: install.sh [--debug] [--source-ref <branch-or-tag>]\n\n'
    printf 'Options:\n'
    printf '  --debug                       Show detailed operation output\n'
    printf '  --source-ref <branch-or-tag>  Download files from this Git ref\n'
    printf '  -h, --help                    Show this help message\n'
}

validate_source_ref() {
    local candidate=$1

    [[ -n $candidate && ${#candidate} -le 200 ]] || return 1
    [[ $candidate =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || return 1
    [[ $candidate != *".."* && $candidate != *"//"* ]] || return 1
    [[ $candidate != */ && $candidate != *. ]] || return 1
    [[ $candidate != */.* ]] || return 1
    [[ $candidate != *.lock && $candidate != *".lock/"* ]] || return 1
}

validate_version() {
    local candidate=$1

    [[ $candidate =~ $VERSION_PATTERN ]]
}

while (($# > 0)); do
    case $1 in
        --debug)
            if ((debug_mode == 1)); then
                printf 'Error: option specified more than once: --debug\n' >&2
                exit 2
            fi

            debug_mode=1
            shift
            ;;
        --source-ref)
            if ((source_ref_seen == 1)); then
                printf 'Error: option specified more than once: --source-ref\n' >&2
                exit 2
            fi

            if (($# < 2)); then
                printf 'Error: --source-ref requires a branch or tag\n' >&2
                exit 2
            fi

            source_ref=$2

            if ! validate_source_ref "$source_ref"; then
                printf 'Error: invalid source reference: %s\n' "$source_ref" >&2
                exit 2
            fi

            source_ref_seen=1
            shift 2
            ;;
        --source-ref=*)
            if ((source_ref_seen == 1)); then
                printf 'Error: option specified more than once: --source-ref\n' >&2
                exit 2
            fi

            source_ref=${1#*=}

            if ! validate_source_ref "$source_ref"; then
                printf 'Error: invalid source reference: %s\n' "$source_ref" >&2
                exit 2
            fi

            source_ref_seen=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            printf 'Error: unsupported option: %s\n' "$1" >&2
            print_usage >&2
            exit 2
            ;;
    esac
done

readonly SOURCE_REF="$source_ref"
readonly RAW_BASE_URL="https://raw.githubusercontent.com/${REPOSITORY}/${SOURCE_REF}"

COLOR_RESET=""
COLOR_BOLD=""
COLOR_CYAN=""
COLOR_GREEN=""
COLOR_YELLOW=""
COLOR_RED=""

if ((debug_mode == 0)) &&
    [[ -t 1 && -t 2 && ${TERM:-dumb} != "dumb" && -z ${NO_COLOR:-} ]]; then
    COLOR_RESET=$'\e[0m'
    COLOR_BOLD=$'\e[1m'
    COLOR_CYAN=$'\e[36m'
    COLOR_GREEN=$'\e[32m'
    COLOR_YELLOW=$'\e[33m'
    COLOR_RED=$'\e[31m'
fi

debug_log() {
    if ((debug_mode == 1)); then
        printf 'DEBUG: %s\n' "$*" >&2

        if ((debug_pacing == 1)) && [[ -t 2 ]]; then
            sleep "$DEBUG_LINE_DELAY"
        fi
    fi
}

print_header() {
    if ((debug_mode == 1)); then
        return 0
    fi

    printf '\n%s%s%s\n' "$COLOR_BOLD" "$PROJECT_NAME" "$COLOR_RESET"
    printf '%s\n\n' '-----------------------'
}

begin_step() {
    local step_number=$1
    local description=$2

    if ((debug_mode == 1)); then
        if ((step_number > 1)); then
            printf '\n' >&2
        fi

        debug_log "$description"
        return 0
    fi

    step_active=1
    printf '%s[%s/%s]%s %-38s' \
        "$COLOR_CYAN" "$step_number" "$step_count" "$COLOR_RESET" \
        "$description"
}

complete_step() {
    if ((debug_mode == 1)); then
        return 0
    fi

    if [[ -t 1 ]]; then
        sleep "$STEP_DELAY"
    fi

    printf '%sdone%s\n' "$COLOR_GREEN" "$COLOR_RESET"
    step_active=0
}

mark_step_failed() {
    if ((debug_mode == 1)); then
        return 0
    fi

    if ((step_active == 1)); then
        printf '%sfailed%s\n' "$COLOR_RED" "$COLOR_RESET"
        step_active=0
    fi
}

print_error() {
    printf '%sError:%s %s\n' \
        "$COLOR_RED" "$COLOR_RESET" "$*" >&2
}

print_warning() {
    printf '%sWarning:%s %s\n' \
        "$COLOR_YELLOW" "$COLOR_RESET" "$*" > /dev/tty
}

print_success() {
    local message=$1

    if ((debug_mode == 1)); then
        printf '[OK] %s\n' "$message"
    else
        printf '\n%s[OK]%s %s\n\n' \
            "$COLOR_GREEN" "$COLOR_RESET" "$message"
    fi
}

fail() {
    mark_step_failed
    print_error "$*"
    exit 1
}

render_last_login_config() {
    printf '%s\n' \
        '# Managed by Debian Server Info MOTD.' \
        'PrintLastLog yes'
}

calculate_desired_last_login_checksum() {
    desired_last_login_checksum=$(render_last_login_config | sha256sum)
    desired_last_login_checksum=${desired_last_login_checksum%% *}
}

detect_effective_last_login() {
    local effective_output=""
    local effective_value=""

    last_login_effective="unavailable"

    if ! command -v sshd >/dev/null 2>&1 ||
        ! effective_output=$(sshd -T 2>/dev/null); then
        return 0
    fi

    effective_value=$(
        awk '
            $1 == "printlastlog" {
                print $2
                exit
            }
        ' <<< "$effective_output"
    )

    case $effective_value in
        yes)
            last_login_effective="enabled"
            ;;
        no)
            last_login_effective="disabled"
            ;;
    esac
}

select_ssh_reload_method() {
    last_login_reload_method=""

    if command -v systemctl >/dev/null 2>&1 &&
        systemctl is-active --quiet ssh.service 2>/dev/null; then
        last_login_reload_method="systemctl"
        return 0
    fi

    if command -v service >/dev/null 2>&1 &&
        service ssh status >/dev/null 2>&1; then
        last_login_reload_method="service"
        return 0
    fi

    return 1
}

reload_ssh_daemon() {
    case $last_login_reload_method in
        systemctl)
            debug_log "Reloading OpenSSH through ssh.service"
            systemctl reload ssh.service >/dev/null
            ;;
        service)
            debug_log "Reloading OpenSSH through the service command"
            service ssh reload >/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

verify_managed_last_login_config() {
    local config_checksum

    [[ -f $LAST_LOGIN_CONFIG_FILE && ! -L $LAST_LOGIN_CONFIG_FILE ]] ||
        return 1

    [[ $(stat -c '%U:%G:%a' -- "$LAST_LOGIN_CONFIG_FILE") == \
        "root:root:644" ]] || return 1

    config_checksum=$(sha256sum -- "$LAST_LOGIN_CONFIG_FILE")
    config_checksum=${config_checksum%% *}

    [[ $config_checksum == "$desired_last_login_checksum" ]]
}

install_managed_last_login_config() {
    if [[ -L $SSHD_CONFIG_DIRECTORY ||
        ! -d $SSHD_CONFIG_DIRECTORY ]]; then
        mark_step_failed
        print_error \
            "expected an OpenSSH configuration directory: ${SSHD_CONFIG_DIRECTORY}"
        false
    fi

    if ((last_login_managed == 0)) &&
        [[ -e $LAST_LOGIN_CONFIG_FILE || -L $LAST_LOGIN_CONFIG_FILE ]]; then
        mark_step_failed
        print_error \
            "refusing to overwrite an unmanaged file: ${LAST_LOGIN_CONFIG_FILE}"
        false
    fi

    if [[ -L $LAST_LOGIN_CONFIG_FILE ||
        ( -e $LAST_LOGIN_CONFIG_FILE &&
            ! -f $LAST_LOGIN_CONFIG_FILE ) ]]; then
        mark_step_failed
        print_error \
            "expected a regular file or an absent path: ${LAST_LOGIN_CONFIG_FILE}"
        false
    fi

    if [[ -z $last_login_reload_method ]] &&
        ! select_ssh_reload_method; then
        mark_step_failed
        print_error "could not select a safe OpenSSH reload method"
        false
    fi

    last_login_config_temp=$(mktemp \
        "${SSHD_CONFIG_DIRECTORY}/.${PROJECT_ID}.XXXXXX")
    render_last_login_config > "$last_login_config_temp"
    chown root:root -- "$last_login_config_temp"
    chmod 0644 -- "$last_login_config_temp"

    last_login_change_started=1
    mv -f -- "$last_login_config_temp" "$LAST_LOGIN_CONFIG_FILE"
    last_login_config_temp=""

    debug_log "Installed OpenSSH configuration: ${LAST_LOGIN_CONFIG_FILE}"

    if ! sshd -t; then
        mark_step_failed
        print_error "OpenSSH rejected the updated configuration"
        false
    fi

    if ! reload_ssh_daemon; then
        mark_step_failed
        print_error "could not reload OpenSSH"
        false
    fi

    detect_effective_last_login

    if [[ $last_login_effective != "enabled" ]]; then
        mark_step_failed
        print_error "OpenSSH Last login notices are still disabled"
        false
    fi
}

prompt_enable_last_login() {
    detect_effective_last_login
    debug_log "OpenSSH Last login: ${last_login_effective}"

    if [[ $last_login_effective != "disabled" ]]; then
        return 0
    fi

    if [[ -e $LAST_LOGIN_CONFIG_FILE || -L $LAST_LOGIN_CONFIG_FILE ]]; then
        print_warning \
            "OpenSSH Last login is disabled, but ${LAST_LOGIN_CONFIG_FILE} already exists."
        return 0
    fi

    if [[ -L $SSHD_CONFIG_DIRECTORY ||
        ! -d $SSHD_CONFIG_DIRECTORY ]] ||
        ! select_ssh_reload_method; then
        print_warning \
            "OpenSSH Last login is disabled and cannot be managed safely on this system."
        return 0
    fi

    if confirm_yes_no "Enable OpenSSH Last login notices?"; then
        last_login_requested=1
    fi
}

download_file() {
    local source_url=$1
    local destination_path=$2

    debug_log "Downloading: ${source_url}"

    if ((debug_mode == 1)); then
        wget --no-verbose --https-only --timeout=30 --tries=3 \
            --output-document="$destination_path" "$source_url"
    else
        wget --quiet --https-only --timeout=30 --tries=3 \
            --output-document="$destination_path" "$source_url"
    fi
}

download_and_verify_payload() {
    local download_step=$1
    local verify_step=$2
    local -a version_lines=()

    begin_step "$download_step" "Downloading files..."

    temporary_directory=$(mktemp -d "/tmp/${PROJECT_ID}.XXXXXX")
    downloaded_script="${temporary_directory}/${PAYLOAD_PATH}"
    downloaded_command="${temporary_directory}/${COMMAND_PATH}"
    downloaded_checksums="${temporary_directory}/${CHECKSUM_PATH}"
    downloaded_version="${temporary_directory}/${VERSION_PATH}"

    debug_log "Temporary directory: ${temporary_directory}"

    install -d -m 0700 -- \
        "${temporary_directory}/etc/update-motd.d" \
        "${temporary_directory}/usr/local/bin"

    if ! download_file \
        "${RAW_BASE_URL}/${PAYLOAD_PATH}" "$downloaded_script"; then
        fail "could not download ${PAYLOAD_PATH}"
    fi

    if ! download_file \
        "${RAW_BASE_URL}/${COMMAND_PATH}" "$downloaded_command"; then
        fail "could not download ${COMMAND_PATH}"
    fi

    if ! download_file \
        "${RAW_BASE_URL}/${VERSION_PATH}" "$downloaded_version"; then
        fail "could not download ${VERSION_PATH}"
    fi

    if ! download_file \
        "${RAW_BASE_URL}/${CHECKSUM_PATH}" "$downloaded_checksums"; then
        fail "could not download ${CHECKSUM_PATH}"
    fi

    complete_step
    begin_step "$verify_step" "Verifying SHA-256 checksum..."

    expected_checksum=$(
        awk -v path="$PAYLOAD_PATH" '
            $2 == path {
                print $1
                exit
            }
        ' "$downloaded_checksums"
    )

    if [[ ! $expected_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail "no valid checksum found for ${PAYLOAD_PATH}"
    fi

    expected_checksum=${expected_checksum,,}
    debug_log "Expected MOTD SHA-256: ${expected_checksum}"

    expected_command_checksum=$(
        awk -v path="$COMMAND_PATH" '
            $2 == path {
                print $1
                exit
            }
        ' "$downloaded_checksums"
    )

    if [[ ! $expected_command_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail "no valid checksum found for ${COMMAND_PATH}"
    fi

    expected_command_checksum=${expected_command_checksum,,}
    debug_log "Expected command SHA-256: ${expected_command_checksum}"

    expected_version_checksum=$(
        awk -v path="$VERSION_PATH" '
            $2 == path {
                print $1
                exit
            }
        ' "$downloaded_checksums"
    )

    if [[ ! $expected_version_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail "no valid checksum found for ${VERSION_PATH}"
    fi

    expected_version_checksum=${expected_version_checksum,,}
    debug_log "Expected version SHA-256: ${expected_version_checksum}"

    actual_checksum=$(sha256sum -- "$downloaded_script")
    actual_checksum=${actual_checksum%% *}

    debug_log "Actual MOTD SHA-256: ${actual_checksum}"

    if [[ $expected_checksum != "$actual_checksum" ]]; then
        fail "checksum verification failed for ${PAYLOAD_PATH}"
    fi

    actual_command_checksum=$(sha256sum -- "$downloaded_command")
    actual_command_checksum=${actual_command_checksum%% *}

    debug_log "Actual command SHA-256: ${actual_command_checksum}"

    if [[ $expected_command_checksum != "$actual_command_checksum" ]]; then
        fail "checksum verification failed for ${COMMAND_PATH}"
    fi

    actual_version_checksum=$(sha256sum -- "$downloaded_version")
    actual_version_checksum=${actual_version_checksum%% *}

    debug_log "Actual version SHA-256: ${actual_version_checksum}"

    if [[ $expected_version_checksum != "$actual_version_checksum" ]]; then
        fail "checksum verification failed for ${VERSION_PATH}"
    fi

    mapfile -t version_lines < "$downloaded_version"

    if ((${#version_lines[@]} != 1)); then
        fail "expected exactly one version line in ${VERSION_PATH}"
    fi

    source_version=${version_lines[0]}

    if ! validate_version "$source_version"; then
        fail "invalid version in ${VERSION_PATH}"
    fi

    debug_log "Source version: ${source_version}"

    if ! bash -n "$downloaded_script"; then
        fail "downloaded MOTD script has invalid Bash syntax"
    fi

    if ! bash -n "$downloaded_command"; then
        fail "downloaded manual command has invalid Bash syntax"
    fi

    debug_log "Downloaded Bash syntax: valid"
    complete_step
}

cleanup() {
    if [[ -n $target_temp_file &&
        ( -e $target_temp_file || -L $target_temp_file ) ]]; then
        rm -f -- "$target_temp_file"
    fi

    if [[ -n $command_temp_file &&
        ( -e $command_temp_file || -L $command_temp_file ) ]]; then
        rm -f -- "$command_temp_file"
    fi

    if [[ -n $state_checksum_temp &&
        ( -e $state_checksum_temp || -L $state_checksum_temp ) ]]; then
        rm -f -- "$state_checksum_temp"
    fi

    if [[ -n $state_command_checksum_temp &&
        ( -e $state_command_checksum_temp ||
            -L $state_command_checksum_temp ) ]]; then
        rm -f -- "$state_command_checksum_temp"
    fi

    if [[ -n $state_source_ref_temp &&
        ( -e $state_source_ref_temp || -L $state_source_ref_temp ) ]]; then
        rm -f -- "$state_source_ref_temp"
    fi

    if [[ -n $state_version_temp &&
        ( -e $state_version_temp || -L $state_version_temp ) ]]; then
        rm -f -- "$state_version_temp"
    fi

    if [[ -n $state_last_login_checksum_temp &&
        ( -e $state_last_login_checksum_temp ||
            -L $state_last_login_checksum_temp ) ]]; then
        rm -f -- "$state_last_login_checksum_temp"
    fi

    if [[ -n $last_login_config_temp &&
        ( -e $last_login_config_temp || -L $last_login_config_temp ) ]]; then
        rm -f -- "$last_login_config_temp"
    fi

    if ((preserve_temporary == 0)) &&
        [[ -n $temporary_directory && -d $temporary_directory ]]; then
        rm -rf -- "$temporary_directory"
    fi

    if ((changes_started == 0)) &&
        [[ -n $state_work_directory && -d $state_work_directory ]]; then
        rm -rf -- "$state_work_directory"
    fi
}

backup_file() {
    local source_path=$1
    local backup_name=$2

    if [[ -e $source_path || -L $source_path ]]; then
        debug_log "Backing up: ${source_path}"
        cp -a -- "$source_path" "${backup_directory}/${backup_name}"
        : > "${backup_directory}/${backup_name}.present"
    else
        debug_log "Backup source is absent: ${source_path}"
    fi
}

restore_file() {
    local target_path=$1
    local backup_name=$2

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        debug_log "Restoring: ${target_path}"
    else
        debug_log "Removing installer-created file: ${target_path}"
    fi

    rm -f -- "$target_path" || return 1

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        cp -a -- "${backup_directory}/${backup_name}" "$target_path"
    fi
}

backup_transaction_file() {
    local source_path=$1
    local backup_name=$2

    if [[ -e $source_path || -L $source_path ]]; then
        cp -a -- "$source_path" "${rollback_directory}/${backup_name}"
        : > "${rollback_directory}/${backup_name}.present"
    fi
}

restore_transaction_file() {
    local target_path=$1
    local backup_name=$2

    rm -f -- "$target_path" || return 1

    if [[ -f ${rollback_directory}/${backup_name}.present ]]; then
        cp -a -- "${rollback_directory}/${backup_name}" "$target_path"
    fi
}

verify_restored_file() {
    local target_path=$1
    local backup_name=$2

    if [[ -f ${backup_directory}/${backup_name}.present ]]; then
        [[ -f $target_path && ! -L $target_path ]] || return 1
        cmp -s -- "${backup_directory}/${backup_name}" "$target_path" &&
            [[ $(stat -c '%U:%G:%a' -- "$target_path") == \
                "$(stat -c '%U:%G:%a' -- \
                    "${backup_directory}/${backup_name}")" ]]
    else
        [[ ! -e $target_path && ! -L $target_path ]]
    fi
}

validate_installed_state() {
    local backup_name
    local current_checksum
    local current_mode
    local enabled_output
    local expected_enabled_output=""
    local expected_disabled_mode
    local expected_disabled_value
    local extra_field
    local mode
    local original_mode_value
    local script_name
    local script_path
    local state_attributes
    local state_path
    local -A seen_scripts=()

    if [[ -L $STATE_DIRECTORY || ! -d $STATE_DIRECTORY ]]; then
        fail "invalid installation state directory: ${STATE_DIRECTORY}"
    fi

    state_attributes=$(stat -c '%U:%G:%a' -- "$STATE_DIRECTORY")

    if [[ $state_attributes != "root:root:700" ]]; then
        fail "unexpected ownership or mode on ${STATE_DIRECTORY}"
    fi

    for state_path in \
        "${STATE_DIRECTORY}/installed" \
        "${STATE_DIRECTORY}/state-format" \
        "${STATE_DIRECTORY}/source-ref" \
        "${STATE_DIRECTORY}/version" \
        "${STATE_DIRECTORY}/payload.sha256" \
        "${STATE_DIRECTORY}/command.sha256" \
        "${STATE_DIRECTORY}/enabled-script-modes"; do
        if [[ -L $state_path || ! -f $state_path ]]; then
            fail "invalid installation state file: ${state_path}"
        fi
    done

    backup_directory="${STATE_DIRECTORY}/backup"
    mode_file="${STATE_DIRECTORY}/enabled-script-modes"

    if [[ -L $backup_directory || ! -d $backup_directory ]]; then
        fail "invalid backup directory: ${backup_directory}"
    fi

    installed_state_format=$(< "${STATE_DIRECTORY}/state-format")

    if [[ $installed_state_format != "$CURRENT_STATE_FORMAT" ]]; then
        fail "unsupported installation state format: ${installed_state_format}"
    fi

    installed_source_ref=$(< "${STATE_DIRECTORY}/source-ref")

    if ! validate_source_ref "$installed_source_ref"; then
        fail "invalid source reference in installation state"
    fi

    installed_version=$(< "${STATE_DIRECTORY}/version")

    if ! validate_version "$installed_version"; then
        fail "invalid version in installation state"
    fi

    installed_checksum=$(< "${STATE_DIRECTORY}/payload.sha256")
    installed_checksum=${installed_checksum,,}

    if [[ ! $installed_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail "invalid payload checksum in installation state"
    fi

    installed_command_checksum=$(< "${STATE_DIRECTORY}/command.sha256")
    installed_command_checksum=${installed_command_checksum,,}

    if [[ ! $installed_command_checksum =~ ^[[:xdigit:]]{64}$ ]]; then
        fail "invalid command checksum in installation state"
    fi

    last_login_managed=0
    last_login_config_status="unmanaged"
    installed_last_login_checksum=""

    state_path="${STATE_DIRECTORY}/last-login.sha256"

    if [[ -e $state_path || -L $state_path ]]; then
        if [[ -L $state_path || ! -f $state_path ]]; then
            fail "invalid installation state file: ${state_path}"
        fi

        installed_last_login_checksum=$(< "$state_path")
        installed_last_login_checksum=${installed_last_login_checksum,,}

        if [[ ! $installed_last_login_checksum =~ \
            ^[[:xdigit:]]{64}$ ]]; then
            fail "invalid Last login checksum in installation state"
        fi

        last_login_managed=1
        last_login_config_status="valid"

        if [[ -L $LAST_LOGIN_CONFIG_FILE ]]; then
            fail \
                "managed OpenSSH configuration is a symbolic link: ${LAST_LOGIN_CONFIG_FILE}"
        elif [[ ! -e $LAST_LOGIN_CONFIG_FILE ]]; then
            last_login_config_status="missing"
        elif [[ ! -f $LAST_LOGIN_CONFIG_FILE ]]; then
            fail \
                "managed OpenSSH configuration is not a regular file: ${LAST_LOGIN_CONFIG_FILE}"
        elif [[ $(stat -c '%U:%G:%a' -- \
                "$LAST_LOGIN_CONFIG_FILE") != "root:root:644" ]]; then
            last_login_config_status="modified"
        else
            current_checksum=$(sha256sum -- "$LAST_LOGIN_CONFIG_FILE")
            current_checksum=${current_checksum%% *}

            if [[ $current_checksum != "$installed_last_login_checksum" ]]; then
                last_login_config_status="modified"
            fi
        fi
    elif [[ -e $LAST_LOGIN_CONFIG_FILE ||
        -L $LAST_LOGIN_CONFIG_FILE ]]; then
        last_login_config_status="unmanaged-conflict"
    fi

    for backup_name in motd issue; do
        if [[ -e ${backup_directory}/${backup_name}.present ||
            -L ${backup_directory}/${backup_name}.present ]]; then
            if [[ -L ${backup_directory}/${backup_name}.present ||
                ! -f ${backup_directory}/${backup_name}.present ||
                -L ${backup_directory}/${backup_name} ||
                ! -f ${backup_directory}/${backup_name} ]]; then
                fail "invalid backup entry: ${backup_name}"
            fi
        elif [[ -e ${backup_directory}/${backup_name} ||
            -L ${backup_directory}/${backup_name} ]]; then
            fail "backup marker is missing for: ${backup_name}"
        fi
    done

    if [[ -e ${STATE_DIRECTORY}/update-motd-directory.present ||
        -L ${STATE_DIRECTORY}/update-motd-directory.present ]]; then
        if [[ -L ${STATE_DIRECTORY}/update-motd-directory.present ||
            ! -f ${STATE_DIRECTORY}/update-motd-directory.present ]]; then
            fail "invalid update-motd directory marker"
        fi

        motd_directory_preexisted=1
    else
        motd_directory_preexisted=0
    fi

    if [[ -L $MOTD_DIRECTORY || ! -d $MOTD_DIRECTORY ]]; then
        fail "expected a directory: ${MOTD_DIRECTORY}"
    fi

    target_status="valid"

    if [[ -L $TARGET_FILE ]]; then
        fail "installed MOTD script is a symbolic link: ${TARGET_FILE}"
    elif [[ ! -e $TARGET_FILE ]]; then
        target_status="missing"
    elif [[ ! -f $TARGET_FILE ]]; then
        fail "installed MOTD script is not a regular file: ${TARGET_FILE}"
    else
        if [[ $(stat -c '%U:%G:%a' -- "$TARGET_FILE") != \
            "root:root:755" ]]; then
            fail "unexpected ownership or mode on ${TARGET_FILE}"
        fi

        current_checksum=$(sha256sum -- "$TARGET_FILE")
        current_checksum=${current_checksum%% *}

        if [[ $current_checksum != "$installed_checksum" ]]; then
            target_status="modified"
        fi
    fi

    if [[ -e ${STATE_DIRECTORY}/command-directory.present ||
        -L ${STATE_DIRECTORY}/command-directory.present ]]; then
        if [[ -L ${STATE_DIRECTORY}/command-directory.present ||
            ! -f ${STATE_DIRECTORY}/command-directory.present ]]; then
            fail "invalid command directory marker"
        fi

        command_directory_preexisted=1
    else
        command_directory_preexisted=0
    fi

    if [[ -L $COMMAND_DIRECTORY || ! -d $COMMAND_DIRECTORY ]]; then
        fail "expected a directory: ${COMMAND_DIRECTORY}"
    fi

    command_status="valid"

    if [[ -L $COMMAND_FILE ]]; then
        fail "installed manual command is a symbolic link: ${COMMAND_FILE}"
    elif [[ ! -e $COMMAND_FILE ]]; then
        command_status="missing"
    elif [[ ! -f $COMMAND_FILE ]]; then
        fail "installed manual command is not a regular file: ${COMMAND_FILE}"
    else
        if [[ $(stat -c '%U:%G:%a' -- "$COMMAND_FILE") != \
            "root:root:755" ]]; then
            fail "unexpected ownership or mode on ${COMMAND_FILE}"
        fi

        current_checksum=$(sha256sum -- "$COMMAND_FILE")
        current_checksum=${current_checksum%% *}

        if [[ $current_checksum != "$installed_command_checksum" ]]; then
            command_status="modified"
        fi
    fi

    for state_path in "$MOTD_FILE" "$ISSUE_FILE"; do
        if [[ -L $state_path || ! -f $state_path ]]; then
            fail "expected a regular file: ${state_path}"
        fi

        if [[ -s $state_path ]]; then
            fail "file was modified after installation: ${state_path}"
        fi
    done

    saved_script_modes=()
    saved_script_names=()

    while IFS=$'\t' read -r mode script_name extra_field; do
        if [[ ! $mode =~ ^[0-7]{3,4}$ ||
            ! $script_name =~ ^[A-Za-z0-9_-]+$ ||
            -n $extra_field || $script_name == "${TARGET_FILE##*/}" ]]; then
            fail "invalid enabled-script entry in installation state"
        fi

        if [[ -n ${seen_scripts[$script_name]:-} ]]; then
            fail "duplicate enabled-script entry: ${script_name}"
        fi

        seen_scripts[$script_name]=1
        script_path="${MOTD_DIRECTORY}/${script_name}"

        if [[ -L $script_path || ! -f $script_path ]]; then
            fail "previous MOTD script is missing or unsupported: ${script_path}"
        fi

        original_mode_value=$((8#$mode))

        if (( (original_mode_value & 0111) == 0 )); then
            fail "saved MOTD script mode is not executable: ${script_path}"
        fi

        expected_disabled_value=$((original_mode_value & ~0111))
        printf -v expected_disabled_mode '%o' "$expected_disabled_value"
        current_mode=$(stat -c '%a' -- "$script_path")

        if [[ $current_mode != "$expected_disabled_mode" ]]; then
            fail "MOTD script mode was modified: ${script_path}"
        fi

        saved_script_modes+=("$mode")
        saved_script_names+=("$script_name")
    done < "$mode_file"

    if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
        fail "cannot inspect ${MOTD_DIRECTORY}"
    fi

    if [[ $target_status != "missing" ]]; then
        expected_enabled_output=$TARGET_FILE
    fi

    if [[ $enabled_output != "$expected_enabled_output" ]]; then
        fail "unexpected enabled MOTD scripts were found"
    fi

    debug_log "Installation state format: ${installed_state_format}"
    debug_log "Installed source reference: ${installed_source_ref}"
    debug_log "Installed version: ${installed_version}"
    debug_log "Installed payload SHA-256: ${installed_checksum}"
    debug_log "Installed command SHA-256: ${installed_command_checksum}"
    debug_log "Installed MOTD script status: ${target_status}"
    debug_log "Installed manual command status: ${command_status}"
    if ((last_login_managed == 1)); then
        debug_log "Managed OpenSSH Last login: yes"
    else
        debug_log "Managed OpenSSH Last login: no"
    fi

    debug_log "OpenSSH Last login configuration status: ${last_login_config_status}"
    debug_log "Installed MOTD configuration: valid"
}

rollback_installation() {
    local rollback_failed=0
    local mode
    local script_name

    debug_log "Rolling back installation"
    debug_log "Removing: ${TARGET_FILE}"
    rm -f -- "$TARGET_FILE" || rollback_failed=1

    debug_log "Removing: ${COMMAND_FILE}"
    rm -f -- "$COMMAND_FILE" || rollback_failed=1

    if ((last_login_change_started == 1)); then
        debug_log "Removing: ${LAST_LOGIN_CONFIG_FILE}"

        if ! rm -f -- "$LAST_LOGIN_CONFIG_FILE" ||
            ! sshd -t ||
            ! reload_ssh_daemon; then
            rollback_failed=1
        else
            debug_log "Previous OpenSSH configuration: restored"
            last_login_change_started=0
        fi
    fi

    restore_file "$MOTD_FILE" "motd" || rollback_failed=1
    restore_file "$ISSUE_FILE" "issue" || rollback_failed=1

    if [[ -f $mode_file ]]; then
        while IFS=$'\t' read -r mode script_name; do
            if [[ -n $mode && -n $script_name &&
                -f ${MOTD_DIRECTORY}/${script_name} &&
                ! -L ${MOTD_DIRECTORY}/${script_name} ]]; then
                if chmod "$mode" -- "${MOTD_DIRECTORY}/${script_name}"; then
                    debug_log \
                        "Restored mode ${mode}: ${MOTD_DIRECTORY}/${script_name}"
                else
                    rollback_failed=1
                fi
            fi
        done < "$mode_file"
    fi

    if [[ ! -f ${state_work_directory}/update-motd-directory.present ]]; then
        rmdir -- "$MOTD_DIRECTORY" 2>/dev/null || true
    fi

    if ((command_directory_preexisted == 0)); then
        rmdir -- "$COMMAND_DIRECTORY" 2>/dev/null || true
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    return 1
}

rollback_update() {
    local rollback_failed=0

    debug_log "Rolling back update"

    if ! restore_transaction_file "$TARGET_FILE" "target"; then
        rollback_failed=1
    else
        debug_log "Restored previous version: ${TARGET_FILE}"
    fi

    if ! restore_transaction_file "$COMMAND_FILE" "command"; then
        rollback_failed=1
    else
        debug_log "Restored previous command state: ${COMMAND_FILE}"
    fi

    restore_transaction_file \
        "${STATE_DIRECTORY}/payload.sha256" "state-payload" || \
        rollback_failed=1
    restore_transaction_file \
        "${STATE_DIRECTORY}/command.sha256" "state-command" || \
        rollback_failed=1
    restore_transaction_file \
        "${STATE_DIRECTORY}/source-ref" "state-source-ref" || \
        rollback_failed=1
    restore_transaction_file \
        "${STATE_DIRECTORY}/version" "state-version" || \
        rollback_failed=1
    if [[ -n $command_temp_file &&
        ( -e $command_temp_file || -L $command_temp_file ) ]]; then
        rm -f -- "$command_temp_file" || rollback_failed=1
        command_temp_file=""
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    preserve_temporary=1
    return 1
}

rollback_last_login_configuration() {
    local rollback_failed=0

    debug_log "Rolling back OpenSSH Last login configuration"

    if ((last_login_change_started == 1)); then
        restore_transaction_file \
            "$LAST_LOGIN_CONFIG_FILE" "last-login-config" || \
            rollback_failed=1
    fi

    restore_transaction_file \
        "${STATE_DIRECTORY}/last-login.sha256" \
        "state-last-login" || rollback_failed=1

    if ((last_login_change_started == 1)); then
        if ! sshd -t || ! reload_ssh_daemon; then
            rollback_failed=1
        else
            debug_log "Previous OpenSSH configuration: restored"
            last_login_change_started=0
        fi
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    preserve_temporary=1
    return 1
}

rollback_uninstallation() {
    local mode
    local rollback_failed=0
    local script_name

    debug_log "Rolling back uninstallation"

    if [[ ! -d $MOTD_DIRECTORY ]]; then
        install -d -o root -g root -m 0755 -- "$MOTD_DIRECTORY" || \
            rollback_failed=1
    fi

    if [[ ! -d $COMMAND_DIRECTORY ]]; then
        install -d -o root -g root -m 0755 -- "$COMMAND_DIRECTORY" || \
            rollback_failed=1
    fi

    restore_transaction_file "$TARGET_FILE" "target" || rollback_failed=1
    restore_transaction_file "$COMMAND_FILE" "command" || \
        rollback_failed=1
    restore_transaction_file "$MOTD_FILE" "motd" || rollback_failed=1
    restore_transaction_file "$ISSUE_FILE" "issue" || rollback_failed=1

    if ((last_login_change_started == 1)); then
        if ! restore_transaction_file \
                "$LAST_LOGIN_CONFIG_FILE" "last-login-config" ||
            ! sshd -t ||
            ! reload_ssh_daemon; then
            rollback_failed=1
        else
            last_login_change_started=0
        fi
    fi

    if [[ -f $rollback_mode_file ]]; then
        while IFS=$'\t' read -r mode script_name; do
            if [[ -n $mode && -n $script_name &&
                -f ${MOTD_DIRECTORY}/${script_name} &&
                ! -L ${MOTD_DIRECTORY}/${script_name} ]]; then
                chmod "$mode" -- "${MOTD_DIRECTORY}/${script_name}" || \
                    rollback_failed=1
            else
                rollback_failed=1
            fi
        done < "$rollback_mode_file"
    else
        rollback_failed=1
    fi

    if ((rollback_failed == 0)); then
        changes_started=0
        return 0
    fi

    preserve_temporary=1
    return 1
}

on_failure() {
    local exit_status=$1
    local line_number=$2
    local rollback_succeeded=0

    trap - ERR HUP INT TERM
    set +e
    mark_step_failed

    if ((changes_started == 1)); then
        case $operation_key in
            install)
                rollback_installation && rollback_succeeded=1
                ;;
            update)
                rollback_update && rollback_succeeded=1
                ;;
            last-login)
                rollback_last_login_configuration && rollback_succeeded=1
                ;;
            uninstall)
                rollback_uninstallation && rollback_succeeded=1
                ;;
        esac

        if ((rollback_succeeded == 1)); then
            printf '%s failed and all changes were rolled back.\n' \
                "$active_operation" >&2
        else
            printf '%s failed and automatic rollback was incomplete.\n' \
                "$active_operation" >&2

            if [[ -n $state_work_directory && -d $state_work_directory ]]; then
                printf 'Recovery data was kept in: %s\n' \
                    "$state_work_directory" >&2
            fi

            if [[ -n $temporary_directory && -d $temporary_directory ]]; then
                printf 'Temporary recovery data was kept in: %s\n' \
                    "$temporary_directory" >&2
            fi
        fi
    else
        printf '%s failed.\n' "$active_operation" >&2
    fi

    printf 'Failed near line %s.\n' "$line_number" >&2
    cleanup
    exit "$exit_status"
}

read_menu_choice() {
    local maximum=$1
    local default_choice=$2
    local answer

    while true; do
        if ! {
            printf 'Select an action [1-%s, default: %s]: ' \
                "$maximum" "$default_choice" > /dev/tty
            IFS= read -r answer < /dev/tty
        }; then
            fail "an interactive terminal is required"
        fi

        if [[ -z $answer ]]; then
            menu_choice=$default_choice
            return 0
        fi

        case $answer in
            1|2|3|4)
                if ((answer <= maximum)); then
                    menu_choice=$answer
                    return 0
                fi
                ;;
        esac

        printf 'Please select a number from 1 to %s.\n' \
            "$maximum" > /dev/tty
    done
}

confirm_yes_no() {
    local question=$1
    local answer

    while true; do
        if ! {
            printf '%s %s[y/N]%s ' \
                "$question" "$COLOR_YELLOW" "$COLOR_RESET" > /dev/tty
            IFS= read -r answer < /dev/tty
        }; then
            fail "an interactive terminal is required"
        fi

        # LC_ALL=C folds ASCII case only, so list Cyrillic forms explicitly.
        case "${answer,,}" in
            y|yes|д|Д|да|Да|ДА)
                return 0
                ;;
            ""|n|no|н|Н|нет|Нет|НЕТ)
                return 1
                ;;
            *)
                printf 'Please answer y or n.\n' > /dev/tty
                ;;
        esac
    done
}

prompt_install_action() {
    print_header
    printf 'Status: not installed\n\n'
    printf '  1) Install\n'
    printf '  2) Cancel\n\n'

    read_menu_choice 2 2

    case $menu_choice in
        1)
            selected_action="install"
            ;;
        2)
            selected_action="cancel"
            ;;
    esac
}

prompt_installed_action() {
    local last_login_status_text

    detect_effective_last_login

    case $last_login_effective in
        enabled) last_login_status_text="enabled" ;;
        disabled) last_login_status_text="disabled" ;;
        *) last_login_status_text="unavailable" ;;
    esac

    print_header
    printf 'Status: installed\n\n'
    printf 'OpenSSH Last login: %s\n\n' "$last_login_status_text"
    printf '  1) Update\n'
    printf '  2) Configure OpenSSH Last login\n'
    printf '  3) Uninstall\n'
    printf '  4) Cancel\n\n'

    read_menu_choice 4 4

    case $menu_choice in
        1)
            selected_action="update"
            ;;
        2)
            selected_action="last-login"
            ;;
        3)
            selected_action="uninstall"
            ;;
        4)
            selected_action="cancel"
            ;;
    esac
}

confirm_uninstallation() {
    case $target_status in
        missing)
            print_warning "the installed MOTD script is missing."
            ;;
        modified)
            print_warning \
                "the installed MOTD script was modified and will be removed."
            ;;
    esac

    case $command_status in
        missing)
            print_warning "the installed manual command is missing."
            ;;
        modified)
            print_warning \
                "the installed manual command was modified and will be removed."
            ;;
    esac

    if ((last_login_managed == 1)); then
        case $last_login_config_status in
            valid)
                ;;
            missing)
                print_warning \
                    "the managed OpenSSH Last login configuration is missing."
                ;;
            modified)
                print_warning \
                    "the modified OpenSSH Last login configuration will be kept."
                ;;
        esac
    fi

    confirm_yes_no \
        "Uninstall ${PROJECT_NAME} and restore the previous MOTD?"
}

confirm_update_repair() {
    local repair_required=0

    case $target_status in
        valid)
            ;;
        missing)
            print_warning "the installed MOTD script is missing."
            repair_required=1
            ;;
        modified)
            print_warning "the installed MOTD script was modified."
            repair_required=1
            ;;
        *)
            fail "unknown installed MOTD script status: ${target_status}"
            ;;
    esac

    case $command_status in
        valid)
            ;;
        missing)
            print_warning "the installed manual command is missing."
            repair_required=1
            ;;
        modified)
            print_warning "the installed manual command was modified."
            repair_required=1
            ;;
        *)
            fail "unknown installed manual command status: ${command_status}"
            ;;
    esac

    if ((repair_required == 0)); then
        return 0
    fi

    confirm_yes_no "Repair the installation from the repository?"
}

run_last_login_configuration() {
    local configuration_action=""
    local effective_status_text
    local previous_last_login_status
    local result_message

    active_operation="OpenSSH Last login configuration"
    operation_key="last-login"
    step_count=3

    begin_step 1 "Validating installation..."
    validate_installed_state
    detect_effective_last_login
    debug_log "OpenSSH Last login: ${last_login_effective}"
    complete_step

    if ((last_login_managed == 0)); then
        case $last_login_config_status in
            unmanaged)
                ;;
            unmanaged-conflict)
                fail \
                    "refusing to overwrite an unmanaged file: ${LAST_LOGIN_CONFIG_FILE}"
                ;;
            *)
                fail \
                    "unknown OpenSSH Last login configuration status: ${last_login_config_status}"
                ;;
        esac

        case $last_login_effective in
            enabled)
                cleanup
                trap - ERR HUP INT TERM
                print_success \
                    "OpenSSH Last login notices are already enabled outside this project."
                return 0
                ;;
            disabled)
                configuration_action="enable"
                result_message="OpenSSH Last login notices were enabled successfully."
                ;;
            *)
                fail "could not inspect the effective OpenSSH configuration"
                ;;
        esac
    else
        case $last_login_config_status in
            valid)
                if [[ $last_login_effective != "enabled" ]]; then
                    fail \
                        "managed configuration does not enable OpenSSH Last login notices"
                fi

                if confirm_yes_no \
                    "Stop managing OpenSSH Last login notices?"; then
                    configuration_action="stop"
                else
                    printf 'No changes were made.\n'
                    return 0
                fi
                ;;
            missing)
                print_warning \
                    "the managed OpenSSH Last login configuration is missing."
                ;;
            modified)
                print_warning \
                    "the managed OpenSSH Last login configuration was modified."
                ;;
            *)
                fail \
                    "unknown managed Last login status: ${last_login_config_status}"
                ;;
        esac

        if [[ -z $configuration_action ]]; then
            printf '\n'
            printf '  1) Repair the managed configuration\n'
            printf '  2) Stop managing OpenSSH Last login\n'
            printf '  3) Cancel\n\n'

            read_menu_choice 3 3

            case $menu_choice in
                1)
                    configuration_action="repair"
                    result_message="OpenSSH Last login configuration was repaired successfully."
                    ;;
                2)
                    configuration_action="stop"
                    ;;
                3)
                    printf 'No changes were made.\n'
                    return 0
                    ;;
            esac
        fi
    fi

    if [[ $configuration_action == "enable" ]]; then
        if ! confirm_yes_no "Enable OpenSSH Last login notices?"; then
            printf 'No changes were made.\n'
            return 0
        fi
    fi

    previous_last_login_status=$last_login_config_status

    if [[ $configuration_action != "stop" ||
        $previous_last_login_status == "valid" ]]; then
        if ! sshd -t; then
            fail "the current OpenSSH configuration is invalid"
        fi

        if ! select_ssh_reload_method; then
            fail "could not select a safe OpenSSH reload method"
        fi
    fi

    if ((debug_mode == 0)); then
        printf '\n'
    fi

    if [[ $configuration_action == "stop" ]]; then
        begin_step 2 "Stopping Last login management..."
    else
        begin_step 2 "Configuring OpenSSH Last login..."
    fi

    temporary_directory=$(mktemp -d \
        "/tmp/${PROJECT_ID}.last-login.XXXXXX")
    rollback_directory="${temporary_directory}/rollback"
    install -d -m 0700 -- "$rollback_directory"

    backup_transaction_file \
        "$LAST_LOGIN_CONFIG_FILE" "last-login-config"
    backup_transaction_file \
        "${STATE_DIRECTORY}/last-login.sha256" "state-last-login"

    changes_started=1

    if [[ $configuration_action == "stop" ]]; then
        case $previous_last_login_status in
            valid)
                debug_log "Removing: ${LAST_LOGIN_CONFIG_FILE}"
                last_login_change_started=1
                rm -f -- "$LAST_LOGIN_CONFIG_FILE"

                if ! sshd -t; then
                    mark_step_failed
                    print_error \
                        "OpenSSH rejected the configuration after removing the managed setting"
                    false
                fi

                if ! reload_ssh_daemon; then
                    mark_step_failed
                    print_error "could not reload OpenSSH"
                    false
                fi
                ;;
            missing)
                debug_log \
                    "Managed OpenSSH configuration is already absent"
                ;;
            modified)
                debug_log \
                    "Keeping modified OpenSSH configuration: ${LAST_LOGIN_CONFIG_FILE}"
                ;;
        esac

        debug_log \
            "Removing management state: ${STATE_DIRECTORY}/last-login.sha256"
        rm -f -- "${STATE_DIRECTORY}/last-login.sha256"
    else
        install_managed_last_login_config

        state_last_login_checksum_temp=$(mktemp \
            "${STATE_DIRECTORY}/.last-login.sha256.XXXXXX")
        printf '%s\n' "$desired_last_login_checksum" > \
            "$state_last_login_checksum_temp"
        chmod 0600 -- "$state_last_login_checksum_temp"
        mv -f -- \
            "$state_last_login_checksum_temp" \
            "${STATE_DIRECTORY}/last-login.sha256"
        state_last_login_checksum_temp=""
    fi

    complete_step
    begin_step 3 "Verifying OpenSSH configuration..."

    if [[ $configuration_action == "stop" ]]; then
        if [[ -e ${STATE_DIRECTORY}/last-login.sha256 ||
            -L ${STATE_DIRECTORY}/last-login.sha256 ]]; then
            mark_step_failed
            print_error "OpenSSH management state was not removed"
            false
        fi

        case $previous_last_login_status in
            valid|missing)
                if [[ -e $LAST_LOGIN_CONFIG_FILE ||
                    -L $LAST_LOGIN_CONFIG_FILE ]]; then
                    mark_step_failed
                    print_error \
                        "managed OpenSSH configuration was not removed"
                    false
                fi
                ;;
            modified)
                if [[ ! -f $LAST_LOGIN_CONFIG_FILE ||
                    -L $LAST_LOGIN_CONFIG_FILE ]] ||
                    ! cmp -s -- \
                        "$LAST_LOGIN_CONFIG_FILE" \
                        "${rollback_directory}/last-login-config" ||
                    [[ $(stat -c '%u:%g:%a' -- \
                            "$LAST_LOGIN_CONFIG_FILE") != \
                        "$(stat -c '%u:%g:%a' -- \
                            "${rollback_directory}/last-login-config")" ]]; then
                    mark_step_failed
                    print_error \
                        "modified OpenSSH configuration changed while management was removed"
                    false
                fi
                ;;
        esac

        detect_effective_last_login

        case $last_login_effective in
            enabled) effective_status_text="enabled" ;;
            disabled) effective_status_text="disabled" ;;
            *) effective_status_text="unavailable" ;;
        esac

        if [[ $previous_last_login_status == "valid" &&
            $last_login_effective == "unavailable" ]]; then
            mark_step_failed
            print_error \
                "could not inspect OpenSSH after removing the managed setting"
            false
        fi

        debug_log "Managed OpenSSH Last login: no"
        debug_log "OpenSSH Last login: ${effective_status_text}"
        result_message="OpenSSH Last login is no longer managed by ${PROJECT_NAME}."
    else
        if ! verify_managed_last_login_config ||
            [[ $(< "${STATE_DIRECTORY}/last-login.sha256") != \
                "$desired_last_login_checksum" ]]; then
            mark_step_failed
            print_error "managed OpenSSH configuration verification failed"
            false
        fi

        detect_effective_last_login

        if [[ $last_login_effective != "enabled" ]]; then
            mark_step_failed
            print_error "OpenSSH Last login notices are not enabled"
            false
        fi

        debug_log "Managed OpenSSH configuration: ${LAST_LOGIN_CONFIG_FILE}"
        debug_log "OpenSSH Last login: enabled"
    fi

    complete_step

    if [[ $configuration_action == "stop" ]]; then
        last_login_managed=0
        last_login_config_status="unmanaged"
        installed_last_login_checksum=""
    else
        last_login_managed=1
        last_login_config_status="valid"
        installed_last_login_checksum=$desired_last_login_checksum
    fi

    last_login_change_started=0
    changes_started=0

    cleanup
    trap - ERR HUP INT TERM
    print_success "$result_message"

    if [[ $configuration_action == "stop" ]]; then
        printf 'Effective OpenSSH Last login setting: %s.\n' \
            "$effective_status_text"
    fi
}

run_update() {
    local current_checksum
    local current_command_checksum
    local enabled_output
    local install_step_description
    local result_message
    local update_available=0
    local verification_step_description

    active_operation="Update"
    operation_key="update"
    step_count=6

    begin_step 1 "Validating installation..."
    validate_installed_state
    complete_step

    if ! confirm_update_repair; then
        printf 'No changes were made.\n'
        return 0
    fi

    if [[ $target_status != "valid" ||
        $command_status == "missing" ||
        $command_status == "modified" ]] && ((debug_mode == 0)); then
        printf '\n'
    fi

    download_and_verify_payload 2 3

    begin_step 4 "Comparing versions..."

    if [[ $actual_checksum != "$installed_checksum" ||
        $actual_command_checksum != "$installed_command_checksum" ||
        $source_version != "$installed_version" ||
        $SOURCE_REF != "$installed_source_ref" ]]; then
        update_available=1
    fi

    if ((update_available == 0)) &&
        [[ $target_status == "valid" && $command_status == "valid" ]]; then
        debug_log "Installed version ${installed_version} is already current"
        complete_step

        begin_step 5 "No update required..."
        complete_step

        begin_step 6 "Verifying installation..."
        "$TARGET_FILE" >/dev/null
        "$COMMAND_FILE" >/dev/null
        complete_step

        cleanup
        trap - ERR HUP INT TERM
        print_success \
            "${PROJECT_NAME} ${installed_version} is already up to date."
        return 0
    fi

    if ((update_available == 1)); then
        if [[ $actual_checksum != "$installed_checksum" ]]; then
            debug_log \
                "Payload update: ${installed_checksum} -> ${actual_checksum}"
        fi

        if [[ $actual_command_checksum != "$installed_command_checksum" ]]; then
            debug_log \
                "Command update:" \
                "${installed_command_checksum} ->" \
                "$actual_command_checksum"
        fi

        if [[ $source_version != "$installed_version" ]]; then
            debug_log \
                "Version update: ${installed_version} -> ${source_version}"
        fi

        if [[ $SOURCE_REF != "$installed_source_ref" ]]; then
            debug_log \
                "Source reference update: ${installed_source_ref} -> ${SOURCE_REF}"
        fi

        install_step_description="Installing update..."
        result_message="${PROJECT_NAME} ${source_version} was updated successfully."
        verification_step_description="Verifying update..."
    else
        debug_log "Repair required: MOTD script is ${target_status}"
        debug_log "Repair required: manual command is ${command_status}"
        active_operation="Repair"
        install_step_description="Repairing installation..."
        result_message="${PROJECT_NAME} ${source_version} was repaired successfully."
        verification_step_description="Verifying repair..."
    fi

    complete_step
    begin_step 5 "$install_step_description"

    rollback_directory="${temporary_directory}/rollback"
    install -d -m 0700 -- "$rollback_directory"
    backup_transaction_file "$TARGET_FILE" "target"
    backup_transaction_file "$COMMAND_FILE" "command"
    backup_transaction_file \
        "${STATE_DIRECTORY}/payload.sha256" "state-payload"
    backup_transaction_file \
        "${STATE_DIRECTORY}/command.sha256" "state-command"
    backup_transaction_file \
        "${STATE_DIRECTORY}/source-ref" "state-source-ref"
    backup_transaction_file \
        "${STATE_DIRECTORY}/version" "state-version"
    if [[ -L $COMMAND_DIRECTORY ||
        ( -e $COMMAND_DIRECTORY && ! -d $COMMAND_DIRECTORY ) ]]; then
        fail "expected a directory: ${COMMAND_DIRECTORY}"
    fi

    target_temp_file=$(mktemp "${MOTD_DIRECTORY}/.10-server-info.XXXXXX")
    install -o root -g root -m 0755 -- \
        "$downloaded_script" "$target_temp_file"

    command_temp_file=$(mktemp "${COMMAND_DIRECTORY}/.server-info.XXXXXX")
    install -o root -g root -m 0755 -- \
        "$downloaded_command" "$command_temp_file"

    changes_started=1
    mv -f -- "$target_temp_file" "$TARGET_FILE"
    target_temp_file=""
    mv -f -- "$command_temp_file" "$COMMAND_FILE"
    command_temp_file=""

    debug_log "Installed MOTD script: ${TARGET_FILE}"
    debug_log "Installed manual command: ${COMMAND_FILE}"
    complete_step
    begin_step 6 "$verification_step_description"

    current_checksum=$(sha256sum -- "$TARGET_FILE")
    current_checksum=${current_checksum%% *}
    current_command_checksum=$(sha256sum -- "$COMMAND_FILE")
    current_command_checksum=${current_command_checksum%% *}

    if [[ $current_checksum != "$actual_checksum" ]]; then
        mark_step_failed
        print_error "updated MOTD checksum verification failed"
        false
    fi

    if [[ $current_command_checksum != "$actual_command_checksum" ]]; then
        mark_step_failed
        print_error "updated command checksum verification failed"
        false
    fi

    if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
        mark_step_failed
        print_error "could not verify the updated MOTD scripts"
        false
    fi

    if [[ $enabled_output != "$TARGET_FILE" ]]; then
        mark_step_failed
        print_error \
            "unexpected enabled MOTD scripts were found after update"
        false
    fi

    "$TARGET_FILE" >/dev/null
    "$COMMAND_FILE" >/dev/null

    state_checksum_temp=$(mktemp \
        "${STATE_DIRECTORY}/.payload.sha256.XXXXXX")
    printf '%s\n' "$actual_checksum" > "$state_checksum_temp"
    chmod 0600 -- "$state_checksum_temp"

    state_command_checksum_temp=$(mktemp \
        "${STATE_DIRECTORY}/.command.sha256.XXXXXX")
    printf '%s\n' "$actual_command_checksum" > \
        "$state_command_checksum_temp"
    chmod 0600 -- "$state_command_checksum_temp"

    state_source_ref_temp=$(mktemp \
        "${STATE_DIRECTORY}/.source-ref.XXXXXX")
    printf '%s\n' "$SOURCE_REF" > "$state_source_ref_temp"
    chmod 0600 -- "$state_source_ref_temp"

    state_version_temp=$(mktemp \
        "${STATE_DIRECTORY}/.version.XXXXXX")
    printf '%s\n' "$source_version" > "$state_version_temp"
    chmod 0600 -- "$state_version_temp"

    mv -f -- "$state_checksum_temp" "${STATE_DIRECTORY}/payload.sha256"
    state_checksum_temp=""
    mv -f -- "$state_command_checksum_temp" \
        "${STATE_DIRECTORY}/command.sha256"
    state_command_checksum_temp=""
    mv -f -- "$state_source_ref_temp" "${STATE_DIRECTORY}/source-ref"
    state_source_ref_temp=""
    mv -f -- "$state_version_temp" "${STATE_DIRECTORY}/version"
    state_version_temp=""

    if [[ $(< "${STATE_DIRECTORY}/state-format") != \
            "$CURRENT_STATE_FORMAT" ||
        $(< "${STATE_DIRECTORY}/payload.sha256") != "$actual_checksum" ||
        $(< "${STATE_DIRECTORY}/command.sha256") != \
            "$actual_command_checksum" ||
        $(< "${STATE_DIRECTORY}/source-ref") != "$SOURCE_REF" ||
        $(< "${STATE_DIRECTORY}/version") != "$source_version" ]]; then
        mark_step_failed
        print_error "could not verify the updated installation state"
        false
    fi

    debug_log "Verified payload SHA-256: ${actual_checksum}"
    debug_log "Verified command SHA-256: ${actual_command_checksum}"
    debug_log "Verified version: ${source_version}"
    complete_step

    changes_started=0
    cleanup
    trap - ERR HUP INT TERM
    print_success "$result_message"
}

run_uninstallation() {
    local current_mode
    local enabled_output
    local expected_enabled_output=""
    local index
    local script_name
    local script_path

    active_operation="Uninstallation"
    operation_key="uninstall"
    step_count=4

    begin_step 1 "Validating installation..."
    validate_installed_state
    complete_step

    if ! confirm_uninstallation; then
        printf 'No changes were made.\n'
        return 0
    fi

    if ((last_login_managed == 1)) &&
        [[ $last_login_config_status == "valid" ]]; then
        if ! sshd -t; then
            fail "the current OpenSSH configuration is invalid"
        fi

        if ! select_ssh_reload_method; then
            fail "could not select a safe OpenSSH reload method"
        fi
    fi

    if ((debug_mode == 0)); then
        printf '\n'
    fi

    begin_step 2 "Restoring previous MOTD..."

    temporary_directory=$(mktemp -d "/tmp/${PROJECT_ID}.uninstall.XXXXXX")
    rollback_directory="${temporary_directory}/rollback"
    rollback_mode_file="${rollback_directory}/script-modes"

    install -d -m 0700 -- "$rollback_directory"
    backup_transaction_file "$TARGET_FILE" "target"
    backup_transaction_file "$COMMAND_FILE" "command"
    backup_transaction_file "$MOTD_FILE" "motd"
    backup_transaction_file "$ISSUE_FILE" "issue"

    if ((last_login_managed == 1)); then
        backup_transaction_file \
            "$LAST_LOGIN_CONFIG_FILE" "last-login-config"
    fi

    : > "$rollback_mode_file"

    for ((index = 0; index < ${#saved_script_names[@]}; index++)); do
        script_name=${saved_script_names[index]}
        script_path="${MOTD_DIRECTORY}/${script_name}"
        current_mode=$(stat -c '%a' -- "$script_path")
        printf '%s\t%s\n' "$current_mode" "$script_name" >> \
            "$rollback_mode_file"
    done

    changes_started=1

    restore_file "$MOTD_FILE" "motd"
    restore_file "$ISSUE_FILE" "issue"

    if ((last_login_managed == 1)) &&
        [[ $last_login_config_status == "valid" ]]; then
        debug_log "Removing: ${LAST_LOGIN_CONFIG_FILE}"
        last_login_change_started=1
        rm -f -- "$LAST_LOGIN_CONFIG_FILE"

        if ! sshd -t; then
            mark_step_failed
            print_error \
                "OpenSSH rejected the configuration restored during removal"
            false
        fi

        if ! reload_ssh_daemon; then
            mark_step_failed
            print_error "could not reload OpenSSH during removal"
            false
        fi

        debug_log "Previous OpenSSH Last login setting: restored"
    elif ((last_login_managed == 1)) &&
        [[ $last_login_config_status == "modified" ]]; then
        debug_log \
            "Keeping modified OpenSSH configuration: ${LAST_LOGIN_CONFIG_FILE}"
    fi

    for ((index = 0; index < ${#saved_script_names[@]}; index++)); do
        script_name=${saved_script_names[index]}
        script_path="${MOTD_DIRECTORY}/${script_name}"
        chmod "${saved_script_modes[index]}" -- "$script_path"
        debug_log \
            "Restored mode ${saved_script_modes[index]}: ${script_path}"
    done

    complete_step
    begin_step 3 "Removing installed files..."

    debug_log "Removing: ${TARGET_FILE}"
    rm -f -- "$TARGET_FILE"

    debug_log "Removing: ${COMMAND_FILE}"
    rm -f -- "$COMMAND_FILE"

    if ((command_directory_preexisted == 0)); then
        debug_log \
            "Removing installer-created directory: ${COMMAND_DIRECTORY}"

        if ! rmdir -- "$COMMAND_DIRECTORY" 2>/dev/null; then
            if [[ -L $COMMAND_DIRECTORY || ! -d $COMMAND_DIRECTORY ]]; then
                false
            fi

            debug_log "Keeping non-empty directory: ${COMMAND_DIRECTORY}"
        fi
    fi

    if ((motd_directory_preexisted == 0)); then
        debug_log "Removing installer-created directory: ${MOTD_DIRECTORY}"
        rmdir -- "$MOTD_DIRECTORY"
    fi

    complete_step
    begin_step 4 "Verifying removal..."

    if [[ -e $TARGET_FILE || -L $TARGET_FILE ]]; then
        mark_step_failed
        print_error "installed MOTD script still exists after removal"
        false
    fi

    if [[ -e $COMMAND_FILE || -L $COMMAND_FILE ]]; then
        mark_step_failed
        print_error "installed manual command still exists after removal"
        false
    fi

    if ((last_login_managed == 1)); then
        case $last_login_config_status in
            valid|missing)
                if [[ -e $LAST_LOGIN_CONFIG_FILE ||
                    -L $LAST_LOGIN_CONFIG_FILE ]]; then
                    mark_step_failed
                    print_error \
                        "managed OpenSSH configuration still exists after removal"
                    false
                fi
                ;;
            modified)
                if [[ ! -f $LAST_LOGIN_CONFIG_FILE ||
                    -L $LAST_LOGIN_CONFIG_FILE ]] ||
                    ! cmp -s -- \
                        "$LAST_LOGIN_CONFIG_FILE" \
                        "${rollback_directory}/last-login-config"; then
                    mark_step_failed
                    print_error \
                        "modified OpenSSH configuration changed during removal"
                    false
                fi
                ;;
        esac
    fi

    if ! verify_restored_file "$MOTD_FILE" "motd" ||
        ! verify_restored_file "$ISSUE_FILE" "issue"; then
        mark_step_failed
        print_error "previous MOTD files were not restored correctly"
        false
    fi

    if ((motd_directory_preexisted == 1)); then
        for script_name in "${saved_script_names[@]}"; do
            if [[ -n $expected_enabled_output ]]; then
                expected_enabled_output+=$'\n'
            fi

            expected_enabled_output+="${MOTD_DIRECTORY}/${script_name}"
        done

        if ! enabled_output=$(run-parts --test --lsbsysinit \
            "$MOTD_DIRECTORY"); then
            mark_step_failed
            print_error "could not verify the restored MOTD scripts"
            false
        fi

        if [[ $enabled_output != "$expected_enabled_output" ]]; then
            mark_step_failed
            print_error \
                "unexpected enabled MOTD scripts were found after removal"
            false
        fi
    elif [[ -e $MOTD_DIRECTORY || -L $MOTD_DIRECTORY ]]; then
        mark_step_failed
        print_error "installer-created MOTD directory still exists"
        false
    fi

    debug_log "Previous MOTD configuration: restored"
    debug_log "Removing installation state: ${STATE_DIRECTORY}"

    preserve_temporary=1
    changes_started=0

    if ! rm -rf -- "$STATE_DIRECTORY"; then
        mark_step_failed
        print_error \
            "MOTD was removed, but installation state cleanup failed"
        printf 'Recovery data was kept in: %s\n' \
            "$temporary_directory" >&2
        exit 1
    fi

    preserve_temporary=0
    last_login_change_started=0
    complete_step

    cleanup
    trap - ERR HUP INT TERM
    print_success \
        "${PROJECT_NAME} ${installed_version} was uninstalled successfully."
}

trap cleanup EXIT
trap 'on_failure "$?" "$LINENO"' ERR
trap 'on_failure 129 "$LINENO"' HUP
trap 'on_failure 130 "$LINENO"' INT
trap 'on_failure 143 "$LINENO"' TERM

debug_log "Installer: ${PROJECT_NAME}"
debug_log "Source reference: ${SOURCE_REF}"

if ((EUID != 0)); then
    fail "run this installer as root"
fi

if [[ ! -r /etc/os-release ]]; then
    fail "cannot read /etc/os-release"
fi

ID=""
NAME=""
VERSION_ID=""
# shellcheck disable=SC1091
. /etc/os-release

debug_log "Operating system: ${NAME:-$ID} ${VERSION_ID}"

if [[ $ID != "debian" || $VERSION_ID != "13" ]]; then
    fail "this installer currently supports Debian 13 only"
fi

for command_name in wget sha256sum run-parts sleep cmp awk; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required command not found: ${command_name}"
    fi
done

debug_log "Required commands: available"
calculate_desired_last_login_checksum

if [[ -e $STATE_DIRECTORY || -L $STATE_DIRECTORY ]]; then
    if [[ -L $STATE_DIRECTORY || ! -d $STATE_DIRECTORY ||
        -L ${STATE_DIRECTORY}/installed ||
        ! -f ${STATE_DIRECTORY}/installed ]]; then
        fail "invalid installation state: ${STATE_DIRECTORY}"
    fi

    debug_log "Installation state: installed"
    prompt_installed_action

    case $selected_action in
        update)
            if ((debug_mode == 1)); then
                debug_pacing=1
            fi

            printf '\n'
            run_update
            exit 0
            ;;
        last-login)
            if ((debug_mode == 1)); then
                debug_pacing=1
            fi

            printf '\n'
            run_last_login_configuration
            exit 0
            ;;
        uninstall)
            if ((debug_mode == 1)); then
                debug_pacing=1
            fi

            printf '\n'
            run_uninstallation
            exit 0
            ;;
        cancel)
            printf 'No changes were made.\n'
            exit 0
            ;;
    esac
fi

debug_log "Installation state: not installed"

if [[ -e $TARGET_FILE || -L $TARGET_FILE ]]; then
    fail "refusing to overwrite an unmanaged file: ${TARGET_FILE}"
fi

if [[ -e $COMMAND_FILE || -L $COMMAND_FILE ]]; then
    fail "refusing to overwrite an unmanaged file: ${COMMAND_FILE}"
fi

if [[ -L $MOTD_DIRECTORY ||
    ( -e $MOTD_DIRECTORY && ! -d $MOTD_DIRECTORY ) ]]; then
    fail "expected a directory: ${MOTD_DIRECTORY}"
fi

if [[ -L $COMMAND_DIRECTORY ||
    ( -e $COMMAND_DIRECTORY && ! -d $COMMAND_DIRECTORY ) ]]; then
    fail "expected a directory: ${COMMAND_DIRECTORY}"
fi

if [[ -d $COMMAND_DIRECTORY ]]; then
    command_directory_preexisted=1
else
    command_directory_preexisted=0
fi

for static_file in "$MOTD_FILE" "$ISSUE_FILE"; do
    if [[ -L $static_file ||
        ( -e $static_file && ! -f $static_file ) ]]; then
        fail "expected a regular file or an absent path: ${static_file}"
    fi
done

enabled_scripts=()

if [[ -d $MOTD_DIRECTORY ]]; then
    if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
        fail "cannot inspect ${MOTD_DIRECTORY}"
    fi

    while IFS= read -r script_path; do
        [[ -n $script_path ]] || continue

        if [[ $script_path != "${MOTD_DIRECTORY}/"* ||
            ! -f $script_path || -L $script_path ]]; then
            fail "unsupported MOTD script: ${script_path}"
        fi

        enabled_scripts+=("$script_path")
    done <<< "$enabled_output"
fi

if ((${#enabled_scripts[@]} == 0)); then
    debug_log "Enabled MOTD scripts: none"
else
    for script_path in "${enabled_scripts[@]}"; do
        debug_log "Enabled MOTD script: ${script_path}"
    done
fi

prompt_install_action

case $selected_action in
    install)
        ;;
    cancel)
        printf 'No changes were made.\n'
        exit 0
        ;;
esac

prompt_enable_last_login

if ((debug_mode == 1)); then
    debug_pacing=1
fi

printf '\n'

download_and_verify_payload 1 2
begin_step 3 "Installing MOTD..."

state_work_directory=$(mktemp -d "/var/lib/.${PROJECT_ID}.XXXXXX")
backup_directory="${state_work_directory}/backup"
mode_file="${state_work_directory}/enabled-script-modes"

debug_log "State work directory: ${state_work_directory}"

install -d -o root -g root -m 0700 -- "$backup_directory"

if [[ -d $MOTD_DIRECTORY ]]; then
    : > "${state_work_directory}/update-motd-directory.present"
fi

if ((command_directory_preexisted == 1)); then
    : > "${state_work_directory}/command-directory.present"
fi

backup_file "$MOTD_FILE" "motd"
backup_file "$ISSUE_FILE" "issue"

: > "$mode_file"

for script_path in "${enabled_scripts[@]}"; do
    script_mode=$(stat -c '%a' -- "$script_path")
    printf '%s\t%s\n' \
        "$script_mode" \
        "${script_path##*/}" >> "$mode_file"
    debug_log "Saved mode ${script_mode}: ${script_path}"
done

printf '%s\n' "$CURRENT_STATE_FORMAT" > \
    "${state_work_directory}/state-format"
printf '%s\n' "$SOURCE_REF" > "${state_work_directory}/source-ref"
printf '%s\n' "$source_version" > "${state_work_directory}/version"
printf '%s\n' "$actual_checksum" > "${state_work_directory}/payload.sha256"
printf '%s\n' "$actual_command_checksum" > \
    "${state_work_directory}/command.sha256"

if [[ -e $COMMAND_FILE || -L $COMMAND_FILE ]]; then
    fail "refusing to overwrite an unmanaged file: ${COMMAND_FILE}"
fi

if [[ -L $COMMAND_DIRECTORY ||
    ( -e $COMMAND_DIRECTORY && ! -d $COMMAND_DIRECTORY ) ]]; then
    fail "expected a directory: ${COMMAND_DIRECTORY}"
fi

changes_started=1

if [[ ! -d $MOTD_DIRECTORY ]]; then
    debug_log "Creating directory: ${MOTD_DIRECTORY}"
    install -d -o root -g root -m 0755 -- "$MOTD_DIRECTORY"
fi

if [[ ! -d $COMMAND_DIRECTORY ]]; then
    debug_log "Creating directory: ${COMMAND_DIRECTORY}"
    install -d -o root -g root -m 0755 -- "$COMMAND_DIRECTORY"
fi

debug_log "Installing: ${TARGET_FILE}"
install -o root -g root -m 0644 -- "$downloaded_script" "$TARGET_FILE"

debug_log "Installing: ${COMMAND_FILE}"
install -o root -g root -m 0755 -- "$downloaded_command" "$COMMAND_FILE"

for script_path in "${enabled_scripts[@]}"; do
    debug_log "Disabling MOTD script: ${script_path}"
    chmod a-x -- "$script_path"
done

debug_log "Clearing: ${MOTD_FILE}"
if [[ -e $MOTD_FILE || -L $MOTD_FILE ]]; then
    : > "$MOTD_FILE"
else
    install -o root -g root -m 0644 -- /dev/null "$MOTD_FILE"
fi

debug_log "Clearing: ${ISSUE_FILE}"
if [[ -e $ISSUE_FILE || -L $ISSUE_FILE ]]; then
    : > "$ISSUE_FILE"
else
    install -o root -g root -m 0644 -- /dev/null "$ISSUE_FILE"
fi

chmod 0755 -- "$TARGET_FILE"
debug_log "Installed mode 0755: ${TARGET_FILE}"
debug_log "Installed mode 0755: ${COMMAND_FILE}"

if ((last_login_requested == 1)); then
    install_managed_last_login_config
    printf '%s\n' "$desired_last_login_checksum" > \
        "${state_work_directory}/last-login.sha256"
    last_login_managed=1
    installed_last_login_checksum=$desired_last_login_checksum
    last_login_config_status="valid"
fi

complete_step
begin_step 4 "Verifying installation..."

if ! enabled_output=$(run-parts --test --lsbsysinit "$MOTD_DIRECTORY"); then
    mark_step_failed
    print_error "could not verify the installed MOTD scripts"
    false
fi

debug_log "Enabled after installation: ${enabled_output:-none}"

if [[ $enabled_output != "$TARGET_FILE" ]]; then
    mark_step_failed
    print_error "unexpected enabled MOTD scripts were found"
    false
fi

debug_log "Executing installed MOTD script for verification"
"$TARGET_FILE" >/dev/null

verification_checksum=$(sha256sum -- "$TARGET_FILE")
verification_checksum=${verification_checksum%% *}

if [[ $verification_checksum != "$actual_checksum" ]]; then
    mark_step_failed
    print_error "installed MOTD checksum verification failed"
    false
fi

verification_checksum=$(sha256sum -- "$COMMAND_FILE")
verification_checksum=${verification_checksum%% *}

if [[ $verification_checksum != "$actual_command_checksum" ]]; then
    mark_step_failed
    print_error "installed command checksum verification failed"
    false
fi

debug_log "Executing installed manual command for verification"
"$COMMAND_FILE" >/dev/null

if ((last_login_requested == 1)); then
    if ! verify_managed_last_login_config ||
        [[ $(< "${state_work_directory}/last-login.sha256") != \
            "$desired_last_login_checksum" ]]; then
        mark_step_failed
        print_error "managed OpenSSH configuration verification failed"
        false
    fi

    detect_effective_last_login

    if [[ $last_login_effective != "enabled" ]]; then
        mark_step_failed
        print_error "OpenSSH Last login notices are not enabled"
        false
    fi

    debug_log "OpenSSH Last login: enabled"
fi

complete_step

: > "${state_work_directory}/installed"
mv -- "$state_work_directory" "$STATE_DIRECTORY"

debug_log "Installation state saved: ${STATE_DIRECTORY}"

changes_started=0
last_login_change_started=0
state_work_directory=""
cleanup
trap - ERR HUP INT TERM
print_success "${PROJECT_NAME} ${source_version} was installed successfully."
printf 'Open a new SSH or local console session to see the MOTD.\n'
printf 'Run server-info at any time to show the same information manually.\n'
