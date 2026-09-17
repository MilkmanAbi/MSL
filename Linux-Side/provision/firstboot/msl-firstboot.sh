#!/bin/sh
# MSL first-boot setup. Runs once, on the first interactive root session,
# from /etc/profile.d/00-msl-firstboot.sh. See that file for the guards.
#
# It configures the EXISTING `msl` account rather than creating another
# one: renaming or replacing the account you may currently be running
# inside is a bad time, and the image already ships with `msl` because
# `msl <instance> -u msl` depends on it.
#
# Everything here is optional and skippable. The one hard rule: the
# sentinel gets written no matter how this ends - completed, failed, or
# Ctrl-C'd. A wizard that re-prompts forever because someone interrupted it
# is worse than one that never ran.

set -u

SENTINEL_DIR=/var/lib/msl
SENTINEL="$SENTINEL_DIR/setup-done"

finish() {
    mkdir -p "$SENTINEL_DIR" 2>/dev/null || true
    {
        echo "completed: $(date 2>/dev/null || echo unknown)"
        echo "# delete this file to run /usr/local/bin/msl-firstboot again"
    } > "$SENTINEL" 2>/dev/null || true
}
# INT/TERM/HUP as well as normal exit - a dropped vsock connection during
# the wizard must still count as "done".
trap 'finish; exit 0' INT TERM HUP
trap 'finish' EXIT

ask() {   # ask <prompt> <default>; answer on stdout
    printf '%s [%s]: ' "$1" "$2" >&2
    if read -r _reply; then
        [ -n "$_reply" ] && echo "$_reply" || echo "$2"
    else
        echo "$2"   # EOF - take the default rather than looping
    fi
}

yes_no() {  # yes_no <prompt> <default y|n>
    _d="$2"
    printf '%s [%s]: ' "$1" "$(if [ "$_d" = y ]; then echo 'Y/n'; else echo 'y/N'; fi)" >&2
    read -r _r || _r=""
    [ -z "$_r" ] && _r="$_d"
    case "$_r" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

DISTRO_NAME=Linux
[ -r /etc/os-release ] && . /etc/os-release 2>/dev/null && DISTRO_NAME="${PRETTY_NAME:-${NAME:-Linux}}"

cat <<BANNER

  ┌─────────────────────────────────────────────┐
  │   MSL — first boot                          │
  │   $(printf '%-43s' "$DISTRO_NAME")│
  └─────────────────────────────────────────────┘

  A few one-time questions. Press Enter to accept every default,
  or Ctrl-C to skip the lot — either way you will not be asked again.
  (Run \`msl-firstboot\` by hand later if you change your mind.)

BANNER

# --- hostname -----------------------------------------------------------
CURRENT_HOST=$(hostname 2>/dev/null || echo msl)
NEW_HOST=$(ask "  Hostname" "$CURRENT_HOST")
if [ "$NEW_HOST" != "$CURRENT_HOST" ]; then
    hostname "$NEW_HOST" 2>/dev/null || true
    echo "$NEW_HOST" > /etc/hostname 2>/dev/null || true
    # Without a matching /etc/hosts line, sudo and anything else that
    # resolves its own hostname stalls on a failed lookup.
    grep -q "127.0.1.1" /etc/hosts 2>/dev/null \
        || echo "127.0.1.1 $NEW_HOST" >> /etc/hosts 2>/dev/null || true
fi

# --- the msl user -------------------------------------------------------
if id msl >/dev/null 2>&1; then
    echo ""
    echo "  The unprivileged account 'msl' exists (use it with: msl <instance> -u msl)."
    if yes_no "  Set a password for it?" n; then
        passwd msl || echo "  (passwd failed - carrying on)"
    fi

    # zsh is installed but is deliberately not anyone's login shell in the
    # image. Offering the switch here makes it a per-user choice instead of
    # a decision baked into every image.
    if command -v zsh >/dev/null 2>&1; then
        if yes_no "  Make zsh the login shell for 'msl'? (bash stays default otherwise)" n; then
            ZSH_PATH=$(command -v zsh)
            grep -q "^$ZSH_PATH$" /etc/shells 2>/dev/null || echo "$ZSH_PATH" >> /etc/shells 2>/dev/null || true
            chsh -s "$ZSH_PATH" msl 2>/dev/null || sed -i "s|^msl:\(.*\):[^:]*$|msl:\1:$ZSH_PATH|" /etc/passwd 2>/dev/null || true
        fi
    fi
fi

# --- timezone -----------------------------------------------------------
# The guest has no idea what the Mac's timezone is - the host does not pass
# it in - so an unset guest clock reads UTC and every file timestamp in the
# Finder share looks hours wrong.
if [ -d /usr/share/zoneinfo ]; then
    CURRENT_TZ=$(readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||')
    [ -n "$CURRENT_TZ" ] || CURRENT_TZ=UTC
    NEW_TZ=$(ask "  Timezone (e.g. Asia/Singapore)" "$CURRENT_TZ")
    if [ "$NEW_TZ" != "$CURRENT_TZ" ] && [ -e "/usr/share/zoneinfo/$NEW_TZ" ]; then
        ln -sf "/usr/share/zoneinfo/$NEW_TZ" /etc/localtime 2>/dev/null || true
        echo "$NEW_TZ" > /etc/timezone 2>/dev/null || true
    elif [ "$NEW_TZ" != "$CURRENT_TZ" ]; then
        echo "  (no such zone '$NEW_TZ' - leaving it as $CURRENT_TZ)"
    fi
fi

# --- what they got ------------------------------------------------------
cat <<SUMMARY

  Set up. What is here:

    /mnt/mac        your Mac home directory (also at ~/mac)
    shellinit       running - this session came through it
    fileopsd        running - backs the Finder share
    x11tunnel       installed, started on demand by \`msl gui\`

  git, curl, wget and zsh are installed. zsh is not the login shell
  unless you just asked for it.

  Growing the disk later: resize the image from the Mac, then run
  \`resize2fs /dev/vda\` in here to make the filesystem use the space.

SUMMARY

finish
