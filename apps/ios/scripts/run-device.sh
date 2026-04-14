#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DERIVED_DATA_ROOT="${HOME}/Library/Developer/Xcode/DerivedData"
APP_PATH="$(/bin/ls -dt "${DERIVED_DATA_ROOT}"/Litter-*/Build/Products/Debug-iphoneos/Litter.app 2>/dev/null | head -1 || true)"
BUNDLE_ID="com.sigkitten.litter"
APP_EXECUTABLE_NAME="$(basename "${APP_PATH}" .app)"

PROFILE_ENABLED="${IOS_DEVICE_PROFILE:-1}"
PROFILE_TEMPLATE="${IOS_DEVICE_PROFILE_TEMPLATE:-Time Profiler}"
PROFILE_TIME_LIMIT="${IOS_DEVICE_PROFILE_TIME_LIMIT:-}"
ARTIFACTS_ROOT="${IOS_RUN_ARTIFACTS_DIR:-${ROOT_DIR}/artifacts/ios-device-run}"
TIMESTAMP="$(date +"%Y%m%d-%H%M%S")"
RUN_DIR="${ARTIFACTS_ROOT}/${TIMESTAMP}"
CONSOLE_LOG_PATH="${RUN_DIR}/device-console.log"
LAUNCH_JSON_PATH="${RUN_DIR}/launch.json"
TRACE_PATH="${RUN_DIR}/profile.trace"
PROFILE_LOG_PATH="${RUN_DIR}/profile.log"
CONSOLE_PID=""
PROFILE_PID=""
PROFILE_ATTACH_RETRY_LIMIT="${IOS_DEVICE_PROFILE_ATTACH_RETRY_LIMIT:-15}"
PROFILE_ATTACH_RETRY_DELAY="${IOS_DEVICE_PROFILE_ATTACH_RETRY_DELAY:-0.5}"
IOS_DEVICE_OVERRIDE="${IOS_DEVICE_ID:-${IOS_DEVICE_UDID:-}}"

mkdir -p "${RUN_DIR}"

if [[ -z "${APP_PATH}" ]]; then
  echo "ERROR: Litter.app not found in DerivedData" >&2
  exit 1
fi

DEVICE_LIST_JSON="${RUN_DIR}/devices.json"
xcrun devicectl list devices --json-output "${DEVICE_LIST_JSON}" >/dev/null 2>&1 || true

DEVICE_SELECTION="$(
  python3 - "${DEVICE_LIST_JSON}" "${IOS_DEVICE_OVERRIDE}" <<'PY'
import json
import os
import sys

path = sys.argv[1]
override = sys.argv[2].strip()

if not os.path.exists(path):
    sys.exit(0)

try:
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

devices = payload.get("result", {}).get("devices", [])

def summarize(device):
    identifier = device.get("identifier", "")
    hardware = device.get("hardwareProperties", {})
    props = device.get("deviceProperties", {})
    conn = device.get("connectionProperties", {})
    udid = hardware.get("udid", "")
    ecid = str(hardware.get("ecid", "") or "")
    name = props.get("name", "")
    tunnel_state = conn.get("tunnelState", "")
    pairing_state = conn.get("pairingState", "")
    ddi_available = props.get("ddiServicesAvailable", False)
    xctrace_id = udid or name or identifier
    state_rank = 0
    if tunnel_state == "connected":
        state_rank = 3
    elif tunnel_state and tunnel_state != "unavailable":
        state_rank = 2
    elif ddi_available:
        state_rank = 1
    return {
        "identifier": identifier,
        "udid": udid,
        "ecid": ecid,
        "name": name,
        "tunnel_state": tunnel_state,
        "pairing_state": pairing_state,
        "ddi_available": ddi_available,
        "xctrace_id": xctrace_id,
        "state_rank": state_rank,
    }

summaries = [summarize(device) for device in devices]

selected = None
if override:
    for candidate in summaries:
        if override in {
            candidate["identifier"],
            candidate["udid"],
            candidate["ecid"],
            f'ecid_{candidate["ecid"]}' if candidate["ecid"] else "",
        }:
            selected = candidate
            break

if selected is None:
    paired = [candidate for candidate in summaries if candidate["pairing_state"] == "paired"]
    ranked = sorted(
        paired,
        key=lambda candidate: (
            candidate["state_rank"],
            bool(candidate["udid"]),
            candidate["name"],
        ),
        reverse=True,
    )
    if ranked:
        selected = ranked[0]

if selected is None:
    sys.exit(0)

print(
    "\t".join(
        [
            selected["identifier"],
            selected["xctrace_id"],
            selected["name"],
            selected["tunnel_state"],
            selected["pairing_state"],
            "1" if selected["ddi_available"] else "0",
            str(selected["state_rank"]),
        ]
    )
)
PY
)"

if [[ -z "${DEVICE_SELECTION}" ]]; then
  echo "ERROR: no paired iOS device found via devicectl" >&2
  exit 1
fi

IFS=$'\t' read -r DEVICE_ID XCTRACE_DEVICE_ID DEVICE_NAME DEVICE_TUNNEL_STATE DEVICE_PAIRING_STATE DEVICE_DDI_AVAILABLE DEVICE_STATE_RANK <<<"${DEVICE_SELECTION}"

if [[ -z "${DEVICE_ID}" ]]; then
  echo "ERROR: failed to resolve a usable device identifier" >&2
  exit 1
fi

if [[ "${DEVICE_STATE_RANK}" == "0" ]]; then
  echo "ERROR: selected device is paired but currently unreachable:" >&2
  echo "  name=${DEVICE_NAME}" >&2
  echo "  identifier=${DEVICE_ID}" >&2
  echo "  xctrace_device=${XCTRACE_DEVICE_ID}" >&2
  echo "  tunnel_state=${DEVICE_TUNNEL_STATE:-unknown}" >&2
  echo "  ddi_services_available=${DEVICE_DDI_AVAILABLE}" >&2
  echo "Reconnect/unlock the device or pass IOS_DEVICE_ID/IOS_DEVICE_UDID to override." >&2
  exit 1
fi

lookup_running_pid() {
  local output_json=$1
  xcrun devicectl device info processes --device "${DEVICE_ID}" --json-output "${output_json}" >/dev/null 2>&1 || return 0
  python3 - "${output_json}" "${APP_EXECUTABLE_NAME}" <<'PY'
import json
import os
import sys
from urllib.parse import urlparse

path = sys.argv[1]
expected_name = sys.argv[2]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)
except (OSError, json.JSONDecodeError):
    sys.exit(0)

matches = []
for process in payload.get("result", {}).get("runningProcesses", []):
    executable = process.get("executable", "")
    parsed = urlparse(executable)
    executable_path = parsed.path or executable
    if executable_path.endswith(f"/{expected_name}.app/{expected_name}"):
        pid = process.get("processIdentifier")
        if pid:
            matches.append(pid)

if matches:
    print(max(matches))
PY
}

start_profiler_with_retry() {
  local pid="$1"
  shift
  local -a record_args=("$@")
  local attempt=1
  local attach_log=""

  : > "${PROFILE_LOG_PATH}"

  while (( attempt <= PROFILE_ATTACH_RETRY_LIMIT )); do
    {
      echo "==> profiler attach attempt ${attempt}/${PROFILE_ATTACH_RETRY_LIMIT} for pid ${pid}"
      printf '==> command:'
      printf ' %q' "${record_args[@]}"
      printf '\n'
    } >> "${PROFILE_LOG_PATH}"

    "${record_args[@]}" >>"${PROFILE_LOG_PATH}" 2>&1 &
    local candidate_pid=$!
    sleep 1

    if kill -0 "${candidate_pid}" 2>/dev/null; then
      PROFILE_PID="${candidate_pid}"
      return 0
    fi

    wait "${candidate_pid}" 2>/dev/null || true
    attach_log="$(tail -n 20 "${PROFILE_LOG_PATH}" 2>/dev/null || true)"
    if [[ "${attach_log}" != *"Cannot find process for provided pid"* ]]; then
      return 1
    fi

    sleep "${PROFILE_ATTACH_RETRY_DELAY}"
    pid="$(lookup_running_pid "${RUN_DIR}/processes.json")"
    if [[ -z "${pid}" ]]; then
      ((attempt++))
      continue
    fi

    record_args=()
    if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
      record_args=(
        xcrun xctrace record
        --template "${PROFILE_TEMPLATE}"
        --device "${XCTRACE_DEVICE_ID}"
        --attach "${pid}"
        --output "${TRACE_PATH}"
        --no-prompt
        --time-limit "${PROFILE_TIME_LIMIT}"
      )
    else
      record_args=(
        xcrun xctrace record
        --template "${PROFILE_TEMPLATE}"
        --device "${XCTRACE_DEVICE_ID}"
        --attach "${pid}"
        --output "${TRACE_PATH}"
        --no-prompt
      )
    fi
    ((attempt++))
  done

  return 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM

  if [[ -n "${PROFILE_PID}" ]]; then
    echo
    echo "==> Stopping profiler and finalizing trace..."
    kill -INT "${PROFILE_PID}" 2>/dev/null || true
    wait "${PROFILE_PID}" 2>/dev/null || true
  fi

  if [[ -n "${CONSOLE_PID}" ]]; then
    kill "${CONSOLE_PID}" 2>/dev/null || true
    wait "${CONSOLE_PID}" 2>/dev/null || true
  fi

  exit "${exit_code}"
}
trap cleanup EXIT INT TERM

echo "==> Installing on device ${DEVICE_ID}..."
xcrun devicectl device install app --device "${DEVICE_ID}" "${APP_PATH}"

echo "==> Artifacts:"
echo "    console log: ${CONSOLE_LOG_PATH}"
if [[ "${PROFILE_ENABLED}" == "1" ]]; then
  echo "    profile trace: ${TRACE_PATH}"
  echo "    profile log: ${PROFILE_LOG_PATH}"
fi

echo "==> Launching app and attaching console (Ctrl+C stops console streaming)..."
xcrun devicectl device process launch --device "${DEVICE_ID}" --terminate-existing \
  --console --json-output "${LAUNCH_JSON_PATH}" "${BUNDLE_ID}" \
  2>&1 | tee >(
    perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 } print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_' > "${CONSOLE_LOG_PATH}"
  ) | perl -MPOSIX=strftime -ne 'BEGIN { $| = 1 } print strftime("[%Y-%m-%d %H:%M:%S] ", localtime), $_' &
CONSOLE_PID=$!

if [[ "${PROFILE_ENABLED}" == "1" ]]; then
  PID=""
  for _ in $(seq 1 50); do
    PID="$(lookup_running_pid "${RUN_DIR}/processes.json")"
    if [[ -n "${PID}" ]]; then
      sleep 0.5
      latest_pid="$(lookup_running_pid "${RUN_DIR}/processes.json")"
      if [[ -n "${latest_pid}" ]]; then
        PID="${latest_pid}"
      fi
      break
    fi
    sleep 0.2
  done

  if [[ -n "${PID}" ]]; then
    RECORD_ARGS=(
      xcrun xctrace record
      --template "${PROFILE_TEMPLATE}"
      --device "${XCTRACE_DEVICE_ID}"
      --attach "${PID}"
      --output "${TRACE_PATH}"
      --no-prompt
    )
    if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
      RECORD_ARGS+=(--time-limit "${PROFILE_TIME_LIMIT}")
      echo "==> Starting ${PROFILE_TEMPLATE} for pid ${PID} (${PROFILE_TIME_LIMIT})..."
    else
      echo "==> Starting ${PROFILE_TEMPLATE} for pid ${PID} for the full run..."
    fi
    if start_profiler_with_retry "${PID}" "${RECORD_ARGS[@]}"; then
      if [[ -n "${PROFILE_TIME_LIMIT}" ]]; then
        echo "==> Profiler will stop automatically when the time limit is reached."
      else
        echo "==> Profiler will stop when this run stops and then finalize ${TRACE_PATH}."
      fi
    else
      PROFILE_PID=""
      echo "WARN: failed to attach profiler after ${PROFILE_ATTACH_RETRY_LIMIT} attempts; see ${PROFILE_LOG_PATH}" >&2
    fi
  else
    echo "WARN: could not resolve ${APP_EXECUTABLE_NAME} pid on device; skipping profiler capture" >&2
  fi
else
  echo "==> Profiler disabled (IOS_DEVICE_PROFILE=${PROFILE_ENABLED})."
fi

wait "${CONSOLE_PID}"
