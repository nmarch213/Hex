#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=operations-lock.sh disable=SC1091
source "$script_directory/operations-lock.sh"
# shellcheck source=compose-command.sh disable=SC1091
source "$script_directory/compose-command.sh"
compose=()
hex_compose_initialize "$script_directory"

usage() {
  printf '%s\n' \
    'Usage:' \
    '  device-admin.sh enroll DISPLAY_NAME PLATFORM OUTPUT_FILE [CAPABILITIES]' \
    '  device-admin.sh list' \
    '  device-admin.sh rotate DEVICE_ID OUTPUT_FILE' \
    '  device-admin.sh revoke DEVICE_ID' \
    '  device-admin.sh restore-reset' \
    '  device-admin.sh restore-complete' \
    '' \
    'CAPABILITIES defaults to dictation:write,service:health.' >&2
}

run_admin() {
  local running_proxy
  running_proxy="$("${compose[@]}" ps --status running --quiet hex-proxy)"
  if [[ -n "$running_proxy" ]]; then
    "${compose[@]}" exec -T hex-proxy node dist/device-admin.js "$@"
    return
  fi

  local repo_root
  local server_path
  repo_root="$(git -C "$script_directory" rev-parse --show-toplevel)"
  server_path="${script_directory#"$repo_root"/}"
  if [[ -n "$(git -C "$repo_root" status --porcelain --untracked-files=normal -- "$server_path")" ]]; then
    printf 'Refusing to build the offline administration image from an uncommitted server tree.\n' >&2
    return 1
  fi
  "${compose[@]}" build device-admin >/dev/null
  "${compose[@]}" run --rm --no-deps -T device-admin "$@"
}

write_new_credential() (
  local output_path="$1"
  shift
  local output_directory
  local output_directory_argument
  local output_directory_permissions
  local output_name
  local temporary_credential
  local temporary_status
  local temporary_device_id
  local device_id

  output_directory_argument="$(dirname "$output_path")"
  output_name="$(basename "$output_path")"
  if [[ "$output_name" == "." || "$output_name" == ".." ]]; then
    printf 'Credential output must name a file.\n' >&2
    return 1
  fi
  if [[ -L "$output_directory_argument" ]]; then
    printf 'Credential output directory must not be a symbolic link.\n' >&2
    return 1
  fi
  output_directory="$(cd "$output_directory_argument" && pwd -P)"
  if [[ ! -O "$output_directory" ]]; then
    printf 'Credential output directory must be owned by the current user.\n' >&2
    return 1
  fi
  if output_directory_permissions="$(stat -c '%a' "$output_directory" 2>/dev/null)"; then
    :
  else
    output_directory_permissions="$(stat -f '%Lp' "$output_directory")"
  fi
  if [[ ! "$output_directory_permissions" =~ ^[0-7]{3,4}$ ]] ||
    (( (8#$output_directory_permissions & 077) != 0 )); then
    printf 'Credential output directory must be owner-only.\n' >&2
    return 1
  fi
  output_path="$output_directory/$output_name"
  if [[ -e "$output_path" || -L "$output_path" ||
    -e "$output_path.device-id" || -L "$output_path.device-id" ]]; then
    printf 'Refusing to overwrite an existing credential or device-ID file.\n' >&2
    return 1
  fi
  umask 077
  temporary_credential="$(mktemp "$output_directory/.hex-device-credential.XXXXXX")"
  temporary_status="$(mktemp "$output_directory/.hex-device-status.XXXXXX")"
  temporary_device_id="$(mktemp "$output_directory/.hex-device-id.XXXXXX")"
  # The EXIT trap below invokes this cleanup function.
  # shellcheck disable=SC2329
  cleanup_credential_output() {
    rm -f "$temporary_credential" "$temporary_status" "$temporary_device_id"
  }
  trap cleanup_credential_output EXIT

  if ! run_admin "$@" >"$temporary_credential" 2>"$temporary_status"; then
    cat "$temporary_status" >&2
    return 1
  fi
  cat "$temporary_status" >&2

  local byte_count
  local final_byte
  byte_count="$(wc -c <"$temporary_credential" | tr -d ' ')"
  final_byte="$(tail -c 1 "$temporary_credential" | od -An -t u1 | tr -d ' ')"
  LC_ALL=C grep -Eq '^[0-9a-f]{64}$' "$temporary_credential" || {
    printf 'Device administration returned an invalid credential.\n' >&2
    return 1
  }
  [[ "$byte_count" == "65" && "$final_byte" == "10" ]] || {
    printf 'Device administration returned a malformed credential file.\n' >&2
    return 1
  }

  device_id="$(sed -nE \
    's/^.*(Enrolled|Rotated) device ([0-9a-f-]{36})\..*$/\2/p' \
    "$temporary_status" | tail -n 1)"
  [[ "$device_id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
    printf 'Device administration did not return a valid public device ID.\n' >&2
    return 1
  }

  printf '%s\n' "$device_id" >"$temporary_device_id"
  chmod 600 "$temporary_credential" "$temporary_device_id"
  mv "$temporary_credential" "$output_path"
  mv "$temporary_device_id" "$output_path.device-id"
  rm -f "$temporary_status"
  printf 'Credential and public device ID were written to separate owner-only files.\n'
)

command_name="${1:-}"
hex_operations_lock_acquire "$script_directory/runtime"
trap 'hex_operations_lock_release' EXIT
case "$command_name" in
  enroll)
    [[ "$#" -eq 4 || "$#" -eq 5 ]] || {
      usage
      exit 2
    }
    capabilities="${5:-dictation:write,service:health}"
    write_new_credential "$4" enroll "$2" "$3" "$capabilities"
    ;;
  list)
    [[ "$#" -eq 1 ]] || {
      usage
      exit 2
    }
    run_admin list
    ;;
  rotate)
    [[ "$#" -eq 3 ]] || {
      usage
      exit 2
    }
    write_new_credential "$3" rotate "$2"
    ;;
  revoke)
    [[ "$#" -eq 2 ]] || {
      usage
      exit 2
    }
    run_admin revoke "$2"
    ;;
  restore-reset|restore-complete)
    [[ "$#" -eq 1 ]] || {
      usage
      exit 2
    }
    run_admin "$command_name"
    ;;
  *)
    usage
    exit 2
    ;;
esac
