#!/usr/bin/env bash
#
# Two-host, one-NIC-per-host WFB-NG link test with synthetic traffic.
#
# Usage:
#   scripts/link_test_2host.sh run --robot HOST --controller HOST [options]
#   scripts/link_test_2host.sh report --robot HOST --controller HOST [options]
#
# "run" starts the responder on the robot host and the initiator on the
# controller host (over SSH), waits for both to finish, copies their report
# files back and prints the combined report.
#
# "report" only fetches already-written report files and prints the combined
# report, so a manually-run two-host test can be summarized with one command.
#
# Both hosts must already have WFB-NG configured and running (wfb-server) with
# their own NIC. Passwordless SSH is required unless the host is "local".

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(dirname "${script_dir}")"

usage() {
    cat <<EOF
Usage: $0 [run|report] --robot HOST --controller HOST [options]

HOST may be an SSH destination (user@host) or "local" for this machine.

Options:
  --robot HOST             robot-side SSH target (env: OAL_ROBOT_HOST)
  --controller HOST        controller-side SSH target (env: OAL_CONTROLLER_HOST)
  --robot-repo DIR         repo path on the robot (env: OAL_ROBOT_REPO)
  --controller-repo DIR    repo path on the controller (env: OAL_CONTROLLER_REPO)
  --dir DIR                local combined-report dir (default: /tmp/oal-linktest-2host)
  --remote-dir DIR         report dir on both hosts (default: /tmp/oal-linktest)
  --duration SEC           test duration (default: 30; robot runs 5 s longer)
  --rate HZ                probe rate (default: 200)
  --size BYTES             probe payload size (default: 340)
  --ssh-port PORT          SSH port (default: 22)
  --robot-arg ARG          extra oal_linktest argument (repeatable)
  --controller-arg ARG     extra oal_linktest argument (repeatable)
  -h, --help               show this help

SSH options can be overridden with OAL_SSH_OPTS, e.g.
  OAL_SSH_OPTS="-o StrictHostKeyChecking=no" $0 run ...

The default repo path on both hosts is the path of this checkout. Override it
with --robot-repo/--controller-repo when the hosts use different locations.
EOF
}

mode="run"
if [[ $# -gt 0 ]]; then
    case "$1" in
        run|report) mode="$1"; shift ;;
        -h|--help) usage; exit 0 ;;
    esac
fi

robot_host="${OAL_ROBOT_HOST:-}"
controller_host="${OAL_CONTROLLER_HOST:-}"
robot_repo="${OAL_ROBOT_REPO:-${repo_root}}"
controller_repo="${OAL_CONTROLLER_REPO:-${repo_root}}"
local_dir="${OAL_2HOST_REPORT_DIR:-/tmp/oal-linktest-2host}"
remote_dir="${OAL_2HOST_REMOTE_DIR:-/tmp/oal-linktest}"
duration="${OAL_2HOST_DURATION:-30}"
rate="${OAL_2HOST_RATE:-200}"
size="${OAL_2HOST_SIZE:-340}"
ssh_port="${OAL_SSH_PORT:-22}"
robot_args=()
controller_args=()

require_value() {
    if [[ $# -lt 2 ]]; then
        echo "error: $1 requires a value" >&2
        exit 2
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --robot|-r) require_value "$@"; robot_host="$2"; shift 2 ;;
        --controller|-c) require_value "$@"; controller_host="$2"; shift 2 ;;
        --robot-repo) require_value "$@"; robot_repo="$2"; shift 2 ;;
        --controller-repo) require_value "$@"; controller_repo="$2"; shift 2 ;;
        --dir) require_value "$@"; local_dir="$2"; shift 2 ;;
        --remote-dir) require_value "$@"; remote_dir="$2"; shift 2 ;;
        --duration) require_value "$@"; duration="$2"; shift 2 ;;
        --rate) require_value "$@"; rate="$2"; shift 2 ;;
        --size) require_value "$@"; size="$2"; shift 2 ;;
        --ssh-port) require_value "$@"; ssh_port="$2"; shift 2 ;;
        --robot-arg) require_value "$@"; robot_args+=("$2"); shift 2 ;;
        --controller-arg) require_value "$@"; controller_args+=("$2"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *)
            echo "error: unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ -z "${robot_host}" || -z "${controller_host}" ]]; then
    echo "error: both --robot and --controller are required" >&2
    usage >&2
    exit 2
fi

for value in "${duration}" "${rate}" "${size}" "${ssh_port}"; do
    if [[ ! "${value}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        echo "error: expected a number, got '${value}'" >&2
        exit 2
    fi
done

is_local_host() {
    local host="$1"
    case "${host}" in
        ""|local|localhost|127.0.0.1|::1) return 0 ;;
    esac
    [[ "${host}" == "$(hostname)" ]] && return 0
    [[ "${host}" == "$(hostname -f 2>/dev/null || true)" ]] && return 0
    return 1
}

ssh_opts=(-o BatchMode=yes -o ConnectTimeout=10 -p "${ssh_port}")
if [[ -n "${OAL_SSH_OPTS:-}" ]]; then
    read -r -a extra_ssh_opts <<< "${OAL_SSH_OPTS}"
    ssh_opts+=("${extra_ssh_opts[@]}")
fi

run_on_host() {
    local host="$1"
    local command="$2"
    if is_local_host "${host}"; then
        bash -c "${command}"
    else
        ssh "${ssh_opts[@]}" "${host}" "${command}"
    fi
}

shell_quote() {
    printf '%q' "$1"
}

join_quoted() {
    local out=""
    local arg
    for arg in "$@"; do
        out+="$(shell_quote "${arg}") "
    done
    printf '%s' "${out% }"
}

check_host() {
    local host="$1"
    local repo="$2"
    local role="$3"
    local command
    command="test -x $(shell_quote "${repo}/build/oal_linktest") && test -x $(shell_quote "${repo}/scripts/link_test.sh")"
    if ! run_on_host "${host}" "${command}"; then
        echo "error: ${role} host ${host} is missing ${repo}/build/oal_linktest" >&2
        echo "       build it first: cmake -S ${repo} -B ${repo}/build && cmake --build ${repo}/build" >&2
        exit 1
    fi
}

remote_test_command() {
    local repo="$1"
    local role="$2"
    local test_duration="$3"
    shift 3
    local -a args=(
        --duration "${test_duration}"
        --rate "${rate}"
        --size "${size}"
        --report "${remote_dir}/${role}.report"
    )
    args+=("$@")
    printf 'cd %s && OAL_LINKTEST_REPORT_DIR=%s %s %s %s' \
        "$(shell_quote "${repo}")" \
        "$(shell_quote "${remote_dir}")" \
        "$(shell_quote "${repo}/scripts/link_test.sh")" \
        "$(shell_quote "${role}")" \
        "$(join_quoted "${args[@]}")"
}

prepare_remote_reports() {
    local host="$1"
    local role="$2"
    run_on_host "${host}" \
        "rm -f $(shell_quote "${remote_dir}/${role}.report") \
                $(shell_quote "${remote_dir}/${role}.fec_start") \
                $(shell_quote "${remote_dir}/${role}.fec_end")"
}

fetch_file() {
    local host="$1"
    local remote_path="$2"
    local local_path="$3"
    if ! run_on_host "${host}" "test -f $(shell_quote "${remote_path}")"; then
        return 1
    fi
    if is_local_host "${host}"; then
        cp "${remote_path}" "${local_path}"
    else
        ssh "${ssh_opts[@]}" "${host}" "cat $(shell_quote "${remote_path}")" > "${local_path}"
    fi
}

collect_reports() {
    local role
    local host
    for role in robot controller; do
        if [[ "${role}" == "robot" ]]; then
            host="${robot_host}"
        else
            host="${controller_host}"
        fi

        if ! fetch_file "${host}" "${remote_dir}/${role}.report" "${local_dir}/${role}.report"; then
            echo "warning: ${role}.report not found on ${host}:${remote_dir}" >&2
        fi
        fetch_file "${host}" "${remote_dir}/${role}.fec_start" \
            "${local_dir}/${role}.fec_start" || true
        fetch_file "${host}" "${remote_dir}/${role}.fec_end" \
            "${local_dir}/${role}.fec_end" || true
    done
}

mkdir -p "${local_dir}"
rm -f "${local_dir}/robot.report" "${local_dir}/controller.report" \
      "${local_dir}/robot.fec_start" "${local_dir}/robot.fec_end" \
      "${local_dir}/controller.fec_start" "${local_dir}/controller.fec_end"

if [[ "${mode}" == "run" ]]; then
    check_host "${robot_host}" "${robot_repo}" robot
    check_host "${controller_host}" "${controller_repo}" controller

    run_on_host "${robot_host}" "mkdir -p $(shell_quote "${remote_dir}")"
    run_on_host "${controller_host}" "mkdir -p $(shell_quote "${remote_dir}")"
    prepare_remote_reports "${robot_host}" robot
    prepare_remote_reports "${controller_host}" controller

    robot_duration="$(awk -v d="${duration}" 'BEGIN { printf "%.3f", d + 5 }')"
    robot_command="$(remote_test_command "${robot_repo}" robot "${robot_duration}" "${robot_args[@]}")"
    controller_command="$(remote_test_command "${controller_repo}" controller "${duration}" "${controller_args[@]}")"

    echo "==> starting responder on ${robot_host} (${robot_duration} s)"
    run_on_host "${robot_host}" "${robot_command}" &
    robot_pid=$!

    cleanup() {
        kill "${robot_pid}" 2>/dev/null || true
    }
    trap cleanup INT TERM

    robot_ready_port=5631
    for ((i = 0; i < ${#robot_args[@]}; ++i)); do
        case "${robot_args[i]}" in
            --rx-port) robot_ready_port="${robot_args[i + 1]:-${robot_ready_port}}" ;;
            --rx-port=*) robot_ready_port="${robot_args[i]#*=}" ;;
        esac
    done

    echo "==> waiting for responder to listen on UDP port ${robot_ready_port}"
    responder_ready=false
    for _ in $(seq 1 100); do
        if run_on_host "${robot_host}" \
            "ss -lun 2>/dev/null | grep -q '[:.]${robot_ready_port} '"; then
            responder_ready=true
            break
        fi
        sleep 0.2
    done
    if [[ "${responder_ready}" != true ]]; then
        echo "warning: responder did not open port ${robot_ready_port} within 20 s; starting initiator anyway" >&2
    fi

    echo "==> starting initiator on ${controller_host} (${duration} s)"
    set +e
    run_on_host "${controller_host}" "${controller_command}"
    controller_rc=$?
    wait "${robot_pid}"
    robot_rc=$?
    set -e
    trap - INT TERM

    if [[ ${controller_rc} -ne 0 || ${robot_rc} -ne 0 ]]; then
        echo "warning: test process exited with controller=${controller_rc}, robot=${robot_rc}" >&2
    fi
fi

echo "==> collecting reports into ${local_dir}"
collect_reports

set +e
"${script_dir}/link_report.sh" --dir "${local_dir}" | tee "${local_dir}/report.txt"
report_rc=${PIPESTATUS[0]}
set -e

if [[ ${report_rc} -eq 0 ]]; then
    echo "report saved to ${local_dir}/report.txt"
else
    echo "report saved to ${local_dir}/report.txt (result: FAIL/INCOMPLETE)" >&2
fi
exit "${report_rc}"
