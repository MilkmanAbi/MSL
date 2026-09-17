# MSL first-boot trigger. Installed as
# /etc/profile.d/00-msl-firstboot.sh and sourced by every login shell.
#
# READ THIS BEFORE EDITING. Every `msl` command, the MSL app's terminal,
# and all app scanning traverse shellinit, and interactive sessions get a
# login shell - so this file runs in the path that everything depends on.
# If it wedges, MSL is bricked and the symptom looks like a vsock bug.
#
# Hence the guards, in this order and for these reasons:
#
#   1. Sentinel first, before anything else, so the steady state is one
#      `[ -e ]` test.
#   2. Both stdin and stdout must be terminals. One-shot commands
#      (`msl -- ls`, the app's .desktop scan) must never enter the wizard.
#   3. MSL_SKIP_SETUP=1 is an escape hatch you can set from the host.
#   4. Root only - the wizard sets passwords and shells. A non-root first
#      session leaves the sentinel alone so root still gets the wizard.
#   5. No `exit`, ever: this file is *sourced*, so an exit kills the login
#      shell. The wizard runs in a subshell and its failure is discarded.
#
# Removing /var/lib/msl/setup-done re-arms it.

if [ ! -e /var/lib/msl/setup-done ] && \
   [ -z "${MSL_SKIP_SETUP:-}" ] && \
   [ -t 0 ] && [ -t 1 ] && \
   [ "$(id -u 2>/dev/null || echo 1)" = 0 ] && \
   [ -x /usr/local/bin/msl-firstboot ]
then
    # Subshell + `|| true`: a broken wizard must not take the shell with it.
    ( /usr/local/bin/msl-firstboot ) || true
fi
