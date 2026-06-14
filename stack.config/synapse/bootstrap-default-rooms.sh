#!/usr/bin/env sh
set -eu

config_path="${HOMESERVER_CONFIG:-/data/homeserver.yaml}"
internal_url="${MATRIX_HOMESERVER_INTERNAL_URL:-http://synapse:8008}"
roombot_localpart="${MATRIX_AUTOJOIN_LOCALPART:-roombot}"

if [ -z "${DOMAIN:-}" ]; then
  echo "[matrix-bootstrap] DOMAIN is required"
  exit 1
fi

matrix_server_name="matrix.${DOMAIN}"
roombot_user_id="@${roombot_localpart}:${matrix_server_name}"

registration_secret="$(sed -n 's/^registration_shared_secret: "\(.*\)"$/\1/p' "$config_path" | head -n 1)"
if [ -z "$registration_secret" ]; then
  echo "[matrix-bootstrap] Could not read registration_shared_secret from $config_path"
  exit 1
fi

for attempt in $(seq 1 60); do
  if curl -fsS "${internal_url}/_matrix/client/versions" >/dev/null 2>&1; then
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "[matrix-bootstrap] Synapse did not become ready in time"
    exit 1
  fi
  sleep 2
done

roombot_password="$(printf '%s' "${registration_secret}:matrix-roombot:v1" | sha256sum | awk '{print $1}')"

if [ -z "${POSTGRES_HOST:-}" ] || [ -z "${POSTGRES_SYNAPSE_PASSWORD:-}" ]; then
  echo "[matrix-bootstrap] POSTGRES_HOST and POSTGRES_SYNAPSE_PASSWORD are required"
  exit 1
fi

export MATRIX_AUTOJOIN_USER_ID="$roombot_user_id"
export MATRIX_AUTOJOIN_LOCALPART="$roombot_localpart"
export PGHOST="$POSTGRES_HOST"
export PGPORT="${POSTGRES_PORT:-5432}"
export PGDATABASE="${POSTGRES_DB:-synapse}"
export PGUSER="${POSTGRES_USER:-synapse}"
export PGPASSWORD="$POSTGRES_SYNAPSE_PASSWORD"

roombot_exists="$(python3 - <<'PY'
import os

import psycopg2

conn = psycopg2.connect(
    host=os.environ["PGHOST"],
    port=os.environ["PGPORT"],
    dbname=os.environ["PGDATABASE"],
    user=os.environ["PGUSER"],
    password=os.environ["PGPASSWORD"],
)

try:
    with conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM users WHERE name = %s", (os.environ["MATRIX_AUTOJOIN_USER_ID"],))
            print("true" if cur.fetchone() else "false")
finally:
    conn.close()
PY
)"

echo "[matrix-bootstrap] Ensuring Matrix auto-join bot ${roombot_user_id}"
if [ "$roombot_exists" = "true" ]; then
  echo "[matrix-bootstrap] Matrix auto-join bot ${roombot_user_id} already exists"
else
  register_new_matrix_user \
    --exists-ok \
    --no-admin \
    -t bot \
    -u "$roombot_localpart" \
    -p "$roombot_password" \
    -k "$registration_secret" \
    "$internal_url" >/dev/null
fi

roombot_token="$(python3 - <<'PY'
import base64
import os
import random
import string
import time
import zlib

import psycopg2

alphabet = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
user_id = os.environ["MATRIX_AUTOJOIN_USER_ID"]
localpart = os.environ["MATRIX_AUTOJOIN_LOCALPART"]

conn = psycopg2.connect(
    host=os.environ["PGHOST"],
    port=os.environ["PGPORT"],
    dbname=os.environ["PGDATABASE"],
    user=os.environ["PGUSER"],
    password=os.environ["PGPASSWORD"],
)

try:
    with conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT token FROM access_tokens WHERE user_id = %s ORDER BY id DESC LIMIT 1",
                (user_id,),
            )
            row = cur.fetchone()
            if row:
                print(row[0])
            else:
                encoded = base64.b64encode(localpart.encode("utf-8")).decode("ascii").rstrip("=")
                random_part = "".join(random.choice(string.ascii_letters + string.digits) for _ in range(20))
                base = f"syt_{encoded}_{random_part}"
                crc = zlib.crc32(base.encode("ascii")) & 0xFFFFFFFF
                crc_chars = []
                while crc:
                    crc, remainder = divmod(crc, 62)
                    crc_chars.append(alphabet[remainder])
                suffix = ("".join(reversed(crc_chars)) or "0").rjust(6, "0")
                token = f"{base}_{suffix}"

                cur.execute("SELECT COALESCE(MAX(id), 0) + 1 FROM access_tokens")
                next_id = cur.fetchone()[0]
                now_ms = int(time.time() * 1000)
                cur.execute(
                    """
                    INSERT INTO access_tokens (
                        id,
                        user_id,
                        token,
                        device_id,
                        valid_until_ms,
                        puppets_user_id,
                        last_validated,
                        refresh_token_id,
                        used
                    ) VALUES (%s, %s, %s, NULL, NULL, NULL, %s, NULL, FALSE)
                    """,
                    (next_id, user_id, token, now_ms),
                )
                print(token)
finally:
    conn.close()
PY
)"

matrix_curl() {
  for attempt in $(seq 1 30); do
    if curl -fsS "$@"; then
      return 0
    fi
    if [ "$attempt" -eq 30 ]; then
      return 1
    fi
    sleep 2
  done
}

ensure_room() {
  alias_localpart="$1"
  room_name="$2"
  room_topic="$3"
  alias_encoded="%23${alias_localpart}%3A${matrix_server_name}"
  alias_display="#${alias_localpart}:${matrix_server_name}"

  if matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/directory/room/${alias_encoded}" >/dev/null 2>&1; then
    echo "[matrix-bootstrap] Room ${alias_display} already exists"
    return
  fi

  payload="$(cat <<EOF
{"name":"${room_name}","topic":"${room_topic}","visibility":"public","preset":"public_chat","room_alias_name":"${alias_localpart}","creation_content":{"m.federate":false}}
EOF
)"

  matrix_curl \
    -X POST \
    -H "Authorization: Bearer ${roombot_token}" \
    -H "Content-Type: application/json" \
    --data "$payload" \
    "${internal_url}/_matrix/client/v3/createRoom" >/dev/null

  echo "[matrix-bootstrap] Created room ${alias_display}"
}

ensure_call_permissions() {
  alias_localpart="$1"
  alias_encoded="%23${alias_localpart}%3A${matrix_server_name}"
  alias_display="#${alias_localpart}:${matrix_server_name}"

  room_id="$(matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/directory/room/${alias_encoded}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["room_id"])')"

  current_power_levels="$(matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/rooms/${room_id}/state/m.room.power_levels")"

  updated_power_levels="$(POWER_LEVELS="$current_power_levels" python3 - <<'PY'
import json
import os
import sys

power_levels = json.loads(os.environ["POWER_LEVELS"])
events = power_levels.setdefault("events", {})

# Let normal members start and participate in Element Call/MatrixRTC calls
# without lowering the default permission for every state event in the room.
for event_type in (
    "m.call.invite",
    "m.call.answer",
    "m.call.hangup",
    "m.call.candidates",
    "m.call.reject",
    "m.call.select_answer",
    "m.call.negotiate",
    "m.call.member",
    "org.matrix.msc3401.call.member",
):
    events[event_type] = 0

print(json.dumps(power_levels, separators=(",", ":")))
PY
)"

  matrix_curl \
    -X PUT \
    -H "Authorization: Bearer ${roombot_token}" \
    -H "Content-Type: application/json" \
    --data "$updated_power_levels" \
    "${internal_url}/_matrix/client/v3/rooms/${room_id}/state/m.room.power_levels" >/dev/null

  echo "[matrix-bootstrap] Ensured member call permissions for ${alias_display}"
}

remove_legacy_jitsi_widgets() {
  alias_localpart="$1"
  alias_encoded="%23${alias_localpart}%3A${matrix_server_name}"
  alias_display="#${alias_localpart}:${matrix_server_name}"

  room_id="$(matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/directory/room/${alias_encoded}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["room_id"])')"

  room_state="$(matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/rooms/${room_id}/state")"

  legacy_widgets="$(ROOM_STATE="$room_state" python3 - <<'PY'
import json
import os
from urllib.parse import quote

for event in json.loads(os.environ["ROOM_STATE"]):
    event_type = event.get("type")
    if event_type not in ("m.widget", "im.vector.modular.widgets"):
        continue

    content = event.get("content") or {}
    haystack = json.dumps(content, separators=(",", ":"), sort_keys=True).lower()
    if "jitsi" not in haystack and "meet.element.io" not in haystack:
        continue

    state_key = event.get("state_key", "")
    print(f"{quote(event_type, safe='')}\t{quote(state_key, safe='')}")
PY
)"

  if [ -z "$legacy_widgets" ]; then
    echo "[matrix-bootstrap] No legacy Jitsi widgets found for ${alias_display}"
    return
  fi

  printf '%s\n' "$legacy_widgets" | while IFS="$(printf '\t')" read -r event_type_encoded state_key_encoded; do
    matrix_curl \
      -X PUT \
      -H "Authorization: Bearer ${roombot_token}" \
      -H "Content-Type: application/json" \
      --data '{}' \
      "${internal_url}/_matrix/client/v3/rooms/${room_id}/state/${event_type_encoded}/${state_key_encoded}" >/dev/null
  done

  echo "[matrix-bootstrap] Removed legacy Jitsi widgets for ${alias_display}"
}

ensure_room_encryption() {
  alias_localpart="$1"
  alias_encoded="%23${alias_localpart}%3A${matrix_server_name}"
  alias_display="#${alias_localpart}:${matrix_server_name}"

  room_id="$(matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/directory/room/${alias_encoded}" \
    | python3 -c 'import json, sys; print(json.load(sys.stdin)["room_id"])')"

  if matrix_curl \
    -H "Authorization: Bearer ${roombot_token}" \
    "${internal_url}/_matrix/client/v3/rooms/${room_id}/state/m.room.encryption" >/dev/null 2>&1; then
    echo "[matrix-bootstrap] Room encryption already enabled for ${alias_display}"
    return
  fi

  matrix_curl \
    -X PUT \
    -H "Authorization: Bearer ${roombot_token}" \
    -H "Content-Type: application/json" \
    --data '{"algorithm":"m.megolm.v1.aes-sha2"}' \
    "${internal_url}/_matrix/client/v3/rooms/${room_id}/state/m.room.encryption" >/dev/null

  echo "[matrix-bootstrap] Enabled room encryption for ${alias_display}"
}

ensure_room "general" "General" "Default chat room for the platform."
ensure_room "voice-lounge" "Voice Lounge" "Default room for drop-in voice and video calls."
ensure_call_permissions "general"
ensure_call_permissions "voice-lounge"
remove_legacy_jitsi_widgets "general"
remove_legacy_jitsi_widgets "voice-lounge"
ensure_room_encryption "general"
ensure_room_encryption "voice-lounge"
