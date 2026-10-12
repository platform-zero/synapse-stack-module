#!/bin/bash
set -e
umask 077
if [ "$(id -u)" = "0" ]; then
    target_uid="${UID:-991}"
    target_gid="${GID:-991}"
    echo "Running as root, fixing /data permissions for UID=${target_uid}"
    mkdir -p /data
    chown "${target_uid}:${target_gid}" /data
    chmod 0775 /data
    find /data -mindepth 1 ! -name 'homeserver.yaml' -exec chown "${target_uid}:${target_gid}" {} +
    find /data -mindepth 1 ! -name 'homeserver.yaml' -exec chmod u+rwX {} +
    stat -c 'Synapse data permissions: %u:%g %a %n' /data
    echo "Re-executing as UID=${target_uid}"
    if command -v gosu >/dev/null 2>&1; then
        exec gosu "${target_uid}:${target_gid}" "$0" "$@"
    elif command -v su-exec >/dev/null 2>&1; then
        exec su-exec "${target_uid}:${target_gid}" "$0" "$@"
    else
        echo "ERROR: neither gosu nor su-exec is available; refusing unsafe fallback re-exec" >&2
        exit 1
    fi
fi
HOMESERVER_TEMPLATE="/data/homeserver.yaml"
HOMESERVER_CONFIG="/tmp/homeserver.yaml"
if [ ! -f "$HOMESERVER_TEMPLATE" ]; then
    echo "ERROR: homeserver.yaml template not found at $HOMESERVER_TEMPLATE"
    exit 1
fi
echo "Processing homeserver configuration with environment variables"
python3 -c "
import os
import re
import yaml
class UniqueYaml(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        seen = set()
        for key_node, _ in node.value:
            key = self.construct_object(key_node, deep=deep)
            if key in seen:
                raise ValueError('duplicate YAML key')
            seen.add(key)
        return super().construct_mapping(node, deep=deep)
with open('$HOMESERVER_TEMPLATE', 'r') as f:
    content = f.read()
content = re.sub(r'\\\$\{([^}]+)\}', lambda m: os.environ.get(m.group(1), m.group(0)), content)
try:
    parsed = yaml.load(content, Loader=UniqueYaml)
    if not isinstance(parsed, dict):
        raise ValueError('mapping required')
except Exception:
    raise SystemExit('Synapse configuration rejected: invalid or duplicate YAML')
fd = os.open('$HOMESERVER_CONFIG', os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
os.fchmod(fd, 0o600)
with os.fdopen(fd, 'w') as f:
    f.write(content)
print('Environment variables substituted')
"
echo "Using homeserver configuration at $HOMESERVER_CONFIG"
LOG_CONFIG="/tmp/${SYNAPSE_SERVER_NAME}.log.config"
LOG_LEVEL="${SYNAPSE_LOG_LEVEL:-WARNING}"
echo "Generating log config at $LOG_CONFIG with level $LOG_LEVEL"
cat > "$LOG_CONFIG" << EOF
version: 1
formatters:
  precise:
    format: '%(asctime)s - %(name)s - %(lineno)d - %(levelname)s - %(request)s - %(message)s'
handlers:
  console:
    class: logging.StreamHandler
    formatter: precise
loggers:
  synapse.storage.databases.main.event_push_actions:
    level: $LOG_LEVEL
  synapse.util.caches.lrucache:
    level: $LOG_LEVEL
  synapse.util.task_scheduler:
    level: $LOG_LEVEL
  synapse.storage.background_updates:
    level: $LOG_LEVEL
  synapse.storage.SQL:
    level: $LOG_LEVEL
root:
  level: $LOG_LEVEL
  handlers: [console]
disable_existing_loggers: false
EOF
exec python -m synapse.app.homeserver --config-path="$HOMESERVER_CONFIG"
