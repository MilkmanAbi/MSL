#!/bin/sh
# Regression test for the first-boot hook's guards.
#
# These guards are the only thing standing between a wizard bug and a guest
# where no `msl` command works, so they are worth a test that can be re-run
# rather than a careful read.
#
# DESTRUCTIVE. It overwrites /usr/local/bin/msl-firstboot (test 6 installs a
# deliberately broken stub) and removes /var/lib/msl/setup-done. Run it in a
# throwaway container, never on a guest you care about:
#
#   docker run --rm --platform=linux/arm64 -v "$PWD/../..:/proj:ro" alpine:latest \
#     sh -c 'cp -rL /proj/Linux-Side /work && /work/provision/firstboot/test-guards.sh'
#
# Result, 2026-09-09: 6/6 passing on alpine:latest arm64.
#
# These test the hook's LOGIC by sourcing it directly. To test the
# MECHANISM - that a real login shell reaches /etc/profile.d at all, which
# depends on each distro's /etc/profile having the glob loop and on this
# file's name matching it - drive an actual login shell instead:
#
#   printf '\n\n\n\n\n' | script -q -c 'bash -l -c "echo MARKER"' /dev/null
#
# Feed it newlines. A pty with nothing typing at it hangs, because the
# wizard is correctly sitting at a prompt. Verified 2026-09-09 on Alpine:
# the wizard fires, MARKER still prints, the sentinel is written, and the
# second login is silent.

set -u
if [ ! -e /.dockerenv ] && [ "${MSL_ALLOW_DESTRUCTIVE_TEST:-}" != 1 ]; then
    echo "test-guards: refusing to run outside a container." >&2
    echo "test-guards: set MSL_ALLOW_DESTRUCTIVE_TEST=1 if you really mean it." >&2
    exit 2
fi

SELF_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FAIL=0
ok()   { echo "  ok - $*"; }
bad()  { echo "  FAIL - $*"; FAIL=1; }

mkdir -p /var/lib/msl /usr/local/bin /etc/profile.d
cp "$SELF_DIR/msl-firstboot.sh" /usr/local/bin/msl-firstboot
chmod +x /usr/local/bin/msl-firstboot
cp "$SELF_DIR/profile-hook.sh" /etc/profile.d/00-msl-firstboot.sh

# A login shell that sources the hook and then proves it is still alive.
source_hook() { sh -c ". /etc/profile.d/00-msl-firstboot.sh; echo MARKER" 2>&1; }

echo "1: a non-interactive session must not enter the wizard"
# This is the one that matters most: `msl -- ls` and the app's .desktop scan
# both land here, and a wizard prompting at them would hang MSL itself.
rm -f /var/lib/msl/setup-done
OUT=$(source_hook </dev/null)
case "$OUT" in
    *"first boot"*) bad "wizard ran with no tty" ;;
    *MARKER*)       ok "skipped, shell survived" ;;
    *)              bad "shell did not survive: $OUT" ;;
esac
[ -e /var/lib/msl/setup-done ] \
    && bad "sentinel written by a non-interactive session - root would never get the wizard" \
    || ok "sentinel untouched"

echo "2: an existing sentinel short-circuits"
: > /var/lib/msl/setup-done
case "$(source_hook)" in *MARKER*) ok "skipped" ;; *) bad "shell did not survive" ;; esac

echo "3: MSL_SKIP_SETUP=1 escape hatch"
rm -f /var/lib/msl/setup-done
case "$(MSL_SKIP_SETUP=1 source_hook)" in *MARKER*) ok "skipped" ;; *) bad "not honoured" ;; esac

echo "4: EOF on stdin still writes the sentinel"
# Otherwise a session that drops mid-wizard re-prompts on every future login.
rm -f /var/lib/msl/setup-done
/usr/local/bin/msl-firstboot </dev/null >/dev/null 2>&1
[ -e /var/lib/msl/setup-done ] && ok "sentinel written" || bad "would re-prompt forever"

echo "5: SIGINT still writes the sentinel"
rm -f /var/lib/msl/setup-done
( /usr/local/bin/msl-firstboot >/dev/null 2>&1 & P=$!; sleep 1; kill -INT $P 2>/dev/null; wait $P 2>/dev/null )
[ -e /var/lib/msl/setup-done ] && ok "sentinel written" || bad "Ctrl-C would mean re-prompting forever"

echo "6: a broken wizard must not take the login shell with it"
# The hook is *sourced*, so a bare `exit` in it would end the session.
rm -f /var/lib/msl/setup-done
printf '#!/bin/sh\nexit 42\n' > /usr/local/bin/msl-firstboot
chmod +x /usr/local/bin/msl-firstboot
case "$(source_hook)" in *MARKER*) ok "shell survived" ;; *) bad "shell died with the wizard" ;; esac

echo
[ "$FAIL" = 0 ] && { echo "ALL GUARD TESTS PASSED"; exit 0; } || { echo "SOME GUARD TESTS FAILED"; exit 1; }
