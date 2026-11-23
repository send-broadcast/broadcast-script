#!/bin/bash
# The upgrade dry run, run as root inside a fresh disposable Ubuntu system
# container (the broadcast repo's .github/workflows/upgrade-dry-run.yml starts
# it with LXD on the home runner). Never run this on a real server or on a CI host: it installs
# Broadcast with ufw, fail2ban, Docker and root cron.
#
#   upgrade_dry_run.sh <from_version> <to_version> <branch>
#
# Reads the license from /root/license (pushed in as a file, so it is not on
# a command line). Installs <from_version> the way a customer does, fills it
# with the demo data, runs `broadcast.sh upgrade <to_version>` and checks the
# server and its data.
set -euo pipefail

FROM_VERSION="$1"
TO_VERSION="$2"
BRANCH="${3:-main}"
DOMAIN="smoke-test.local"
REPO="https://github.com/send-broadcast/broadcast-script.git"

step() { echo; echo "::group::$*"; }
end() { echo "::endgroup::"; }
fail() { echo "::error::$*"; exit 1; }

for v in "$FROM_VERSION" "$TO_VERSION"; do
  [[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9.]+)?$ ]] || fail "'$v' is not a release version"
done
[ -s /root/license ] || fail "/root/license is missing"
[ -f /run/.containerenv ] || systemd-detect-virt --container --quiet || fail "not inside a container; refusing to install on this machine"

wait_up() {
  for _ in $(seq 1 40); do
    curl -sf http://localhost/up >/dev/null && return 0
    sleep 10
  done
  return 1
}

counts() {
  docker exec app bin/rails runner \
    'puts [User, BroadcastChannel, Subscriber, Broadcast, Sequence, Segment, Template].map { |m| "#{m.name}=#{m.count}" }.join(" ")' | tail -1
}

step "Clone the scripts ($BRANCH)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq git curl jq >/dev/null
git clone --quiet --branch "$BRANCH" "$REPO" /opt/broadcast
git -C /opt/broadcast log --oneline -1
end

step "Prepare the install (domain, license, registry login)"
license=$(tr -d '\r\n' < /root/license)
response=$(curl -sf -X POST -H "Content-Type: application/json" \
  -d "{\"key\":\"${license}\", \"domain\":\"${DOMAIN}\"}" \
  https://sendbroadcast.net/license/check) || fail "license check failed"
login=$(jq -r .registry_login <<<"$response")
password=$(jq -r .registry_password <<<"$response")
echo "::add-mask::$login"
echo "::add-mask::$password"
mkdir -p /opt/broadcast/{app,db,ssl,logs,logs/cron}
echo "$DOMAIN" > /opt/broadcast/.domain
echo "$license" > /opt/broadcast/.license
printf 'BROADCAST_REGISTRY_URL=%s\nBROADCAST_REGISTRY_LOGIN=%s\nBROADCAST_REGISTRY_PASSWORD=%s\n' \
  "$(jq -r .registry_url <<<"$response")" "$login" "$password" > /opt/broadcast/.env
chmod -R o+rX /opt/broadcast/db/init-scripts
# A container cannot turn on swap. install.sh skips the swap file when
# /etc/fstab names /swapfile, so name it in a comment. Everything else in
# the install runs unchanged.
echo "# /swapfile: none in a CI container (upgrade_dry_run.sh)" >> /etc/fstab
end

step "Install the previous release ($FROM_VERSION)"
cd /opt/broadcast
BROADCAST_NO_REBOOT=1 BROADCAST_VERSION="$FROM_VERSION" ./broadcast.sh install
wait_up || fail "$FROM_VERSION did not answer /up"
end

step "Fill the demo data"
echo "DEMO_MODE=true" >> /opt/broadcast/app/.env
systemctl restart broadcast
wait_up || fail "$FROM_VERSION did not answer /up after DEMO_MODE"
docker exec app bundle exec rake cleanup:demo
before=$(counts)
echo "Before: $before"
[[ "$before" =~ (^|\ )Subscriber=0(\ |$) ]] && fail "the demo seed made no subscribers, so the dry run proves nothing"
end

step "Upgrade to $TO_VERSION (the customer path)"
./broadcast.sh upgrade "$TO_VERSION"
end

step "Check the upgraded server"
wait_up || fail "$TO_VERSION did not answer /up"
for c in app job postgres; do
  [ "$(docker inspect -f '{{.State.Running}}' "$c")" = "true" ] || fail "container $c is not running"
done
image=$(docker inspect -f '{{.Config.Image}}' app)
echo "app image: $image"
[[ "$image" == *":$TO_VERSION" ]] || fail "app runs $image, not $TO_VERSION"
[ "$(cat /opt/broadcast/.current_version)" = "$TO_VERSION" ] || fail ".current_version is not $TO_VERSION"
pending=$(docker exec app bin/rails db:migrate:status 2>/dev/null | grep -c '^\s*down' || true)
[ "$pending" = "0" ] || fail "$pending migrations are still down"
after=$(counts)
echo "Before: $before"
echo "After:  $after"
[ "$before" = "$after" ] || fail "the upgrade changed the record counts"
systemctl is-active --quiet broadcast-logs-watcher || fail "broadcast-logs-watcher is not active"
end

step "The demo reset still works on $TO_VERSION"
docker exec app bundle exec rake cleanup:demo
end

echo "Upgrade dry run passed: $FROM_VERSION -> $TO_VERSION"
