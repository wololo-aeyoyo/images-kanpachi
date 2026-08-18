#!/usr/bin/env bash
#
# Replaces both systemd units and drives the room lifecycle.
#
# Written against kanpachi 0.4.0. Three things changed from 0.3.0 that this
# script depends on; see the comments at each site:
#   - the daemon reopens its own saved room at startup, so `resume` here races it
#   - `kanpachi leave` clears the saved room, so it must NOT be the TERM handler
#   - `--yes` is a flag of host/join/upgrade only, never of resume
set -euo pipefail

log() { printf '[kanpachi] %s\n' "$*" >&2; }

# There is no default registry: without a seed the daemon cannot open a room at
# all, so fail here rather than three commands later.
: "${KANPACHI_SEED:?KANPACHI_SEED is required — kanpachi has no default registry}"
ROOM_NAME="${ROOM_NAME:-Merwebo Zomboid}"
GAME_ID="${GAME_ID:-project-zomboid}"
GAME_PORTS="${GAME_PORTS:-16261 16262}"
SHARED_DIR="${SHARED_DIR:-/shared}"

# Overridable only so the control flow can be exercised unprivileged, off the
# real paths. In the pod these are always the defaults.
RUN_DIR="${KANPACHI_RUN_DIR:-/run/kanpachi}"
STATE_DIR="${KANPACHI_STATE_DIR:-/var/lib/kanpachi}"
SOCK="$RUN_DIR/api.sock"

# The shipped unit gets these from RuntimeDirectory/StateDirectory, both at
# 0700. The daemon refuses to start without the data directory ("el directorio
# de datos /var/lib/kanpachi no está — lo crea el instalador con su ACL"), and a
# freshly provisioned PVC arrives empty.
install -d -m 0700 "$RUN_DIR"
install -d -m 0700 "$STATE_DIR"

# --console is the only mode that runs in the foreground on Linux: the daemon
# decides systemd started it purely from NOTIFY_SOCKET being set, and without
# that variable the service path bails out. Console mode defaults its socket to
# console.sock, which the CLI does not look for, so pin it with --pipe.
/usr/libexec/kanpachi/kanpachid --console --pipe "$SOCK" &
DAEMON=$!

# SIGTERM goes to the daemon and nowhere near `kanpachi leave`.
#
# Leaving is "close the room": it calls ClearRoom(), deletes hosted-room.json
# and tells the registry the room is over, so the next start would mint a NEW
# invite code and every link handed out would be dead. The daemon's own
# shutdown path takes the other branch (conservarParaReabrir) — it re-saves the
# room, tears the network down and KEEPS the file, which is what makes the PVC
# below worth having.
shutdown() {
  log "stopping; the room stays saved so it reopens with the same code"
  kill -TERM "$DAEMON" 2>/dev/null || true
}
trap shutdown TERM INT

for _ in $(seq 1 60); do
  [ -S "$SOCK" ] && break
  sleep 1
done
[ -S "$SOCK" ] || { log "the daemon never opened its socket"; exit 1; }

kanpachi seed "$KANPACHI_SEED"

# No --password flag exists, by design; a redirected stdin is the supported door.
if [ -n "${KANPACHI_SEED_PASSWORD:-}" ]; then
  printf '%s\n' "$KANPACHI_SEED_PASSWORD" | kanpachi password
fi

conn() { kanpachi --json status | jq -r '.conn // "unknown"'; }

if kanpachi --json pending | jq -e '.found' >/dev/null 2>&1; then
  # Do NOT call `resume` here. Since 0.4.0 the daemon reopens the saved room by
  # itself on every start, unconditionally, in a background goroutine launched
  # before the control socket starts answering. ResumeRoom returns ErrBusy the
  # moment that attempt leaves the Idle state, ErrBusy exits 1, and under
  # `set -e` that turns every restart into CrashLoopBackOff.
  #
  # So wait for the daemon's own attempt to settle. It takes about a minute:
  # two adapters have to come up, a credential has to be exchanged and the MTU
  # has to be measured.
  log "a saved room exists; waiting for the daemon to reopen it"
  # `idle` is ambiguous on its own: it is both "the goroutine has not started
  # yet" and "the attempt failed and gave up". Track whether the session was
  # ever active, which makes a RETURN to idle a definitive failure and saves
  # sitting out the whole timeout before falling back.
  seen_active=0
  for _ in $(seq 1 180); do
    c="$(conn)"
    if [ "$c" = connected ] || [ "$c" = degraded ]; then
      break
    fi
    if [ "$c" = resolving ] || [ "$c" = connecting ] || [ "$c" = reconnecting ]; then
      seen_active=1
    elif [ "$c" = idle ] && [ "$seen_active" = 1 ]; then
      log "the reopen attempt went back to idle, so it failed"
      break
    fi
    sleep 1
  done

  case "$(conn)" in
    connected|degraded)
      log "the saved room is open again, same code"
      ;;
    idle)
      # This is the case `resume` exists for: the automatic attempt FAILED and
      # left the session idle, so there is nothing to race any more. No --yes —
      # it belongs to host/join/upgrade only, and an unknown flag exits 2.
      log "the daemon's own reopen failed; resuming by hand"
      kanpachi resume
      ;;
    *)
      log "the room is still coming up after 180s; carrying on and letting the IP read below decide"
      ;;
  esac
else
  # --yes answers all three questions: displacing an open room, trusting the
  # registry, and opening a blocking firewall. Without a TTY and without --yes
  # a confirmation is refused rather than assumed, so this is not optional.
  log "nothing saved; opening a new room"
  kanpachi host --yes "$ROOM_NAME"
fi

# Idempotent, and applied on both paths on purpose. A fresh room comes up with
# no ports open and needs it; a reopened room restores its profile by itself,
# but re-applying costs nothing and self-heals a room that lost its game.
kanpachi game "$GAME_ID"

# The room IP is assigned per room and is NOT stable across rooms, so read it
# every start and never pin it in config.
ROOM_IP="$(kanpachi --json status | jq -r '.local_ip // empty')"
[ -n "$ROOM_IP" ] || { log "the room has no local_ip yet; refusing to start a relay to nowhere"; exit 1; }
POD_IP="$(hostname -i | awk '{print $1}')"
log "room IP $ROOM_IP, pod IP $POD_IP"

mkdir -p "$SHARED_DIR"
kanpachi --json status > "$SHARED_DIR/status.json"
kanpachi link | tee "$SHARED_DIR/invite-link.txt"

# The relay, and the reason it binds the ROOM IP rather than DNAT-ing to the pod
# IP: Kanpachi's gate chain is default-deny and its drops match on input
# interface, not just destination. Rewriting the destination in prerouting stops
# the per-member accept (which matches `ip daddr <room IP>`) from matching, and
# the packet falls through to `iif "kanpachi0" drop`. An accept in an earlier
# chain cannot rescue it either — in nftables accept is terminal only within its
# own chain, while drop is terminal across all of them.
#
# Binding the room IP means Kanpachi sees a listener exactly where it expects
# the game to be, its accepts match unmodified, and Zomboid stays on the pod IP
# so the tailscale Service, RCON and ClusterIP paths are untouched.
# ,fork gives each source address its own forwarding session.
for PORT in $GAME_PORTS; do
  log "relaying udp/$PORT from $ROOM_IP to $POD_IP"
  socat "UDP4-RECVFROM:$PORT,bind=$ROOM_IP,fork" \
        "UDP4-SENDTO:$POD_IP:$PORT" &
done

# The trap interrupts this wait, so wait again for the daemon to actually finish
# its shutdown rather than exiting out from under it.
wait "$DAEMON" || true
while kill -0 "$DAEMON" 2>/dev/null; do sleep 1; done
log "the daemon is down"
