#!/usr/bin/env bash
# Runs inside an unprivileged PID namespace where PID 999999 is occupied by a
# live process, which is the host state (kernel.pid_max = 4194304) under which
# both tests failed on origin/main.
set -u
export PATH="/home/fabien/.nvm/versions/node/v24.18.0/bin:$PATH"

label=$1
tree=$2
shift 2

# The namespace maps this account to uid 0; without this bind the remote
# entrypoint's own `unset HOME; cd ~` resolves root's inaccessible home and
# fails for a reason unrelated to the pid fixture under test.
mount --bind /tmp/fm-repro/passwd.ns /etc/passwd || { echo "could not align the account home"; exit 89; }

echo 999998 > /proc/sys/kernel/ns_last_pid || { echo "could not steer pid allocation"; exit 90; }
sleep 900 &
holder=$!
if [ "$holder" != 999999 ]; then echo "holder landed on $holder, not 999999"; kill "$holder"; exit 91; fi

echo "=== $label ($tree)"
echo "kernel.pid_max        : $(cat /proc/sys/kernel/pid_max)"
printf 'PID 999999            : held by a live process (%s)\n' "$(tr '\0' ' ' < /proc/999999/cmdline)"
if kill -0 999999 2>/dev/null; then
  echo "kill(999999, 0)       : ALIVE  <- the literal the old fixtures called a dead lock holder"
fi
echo

cd "$tree" || exit 92
status=0
for script in "$@"; do
  echo "----- bin/fm-test-run.sh $script"
  bin/fm-test-run.sh "$script" 2>&1
  rc=$?
  echo "----- exit=$rc"
  echo
  [ "$rc" -eq 0 ] || status=1
done
kill "$holder" 2>/dev/null
exit "$status"
