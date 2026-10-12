import Foundation

/// `~/Mac` in every Linux home: the Mac's home folder, one `cd` away.
///
/// The share has always been mounted at `/mnt/mac`, but nobody finds a path
/// under `/mnt` on their own, and typing it every time is the kind of small
/// friction that makes the Mac side feel far away. A symlink in each home
/// makes it `cd ~/Mac`, and it shows up in every Linux file manager's home
/// view.
///
/// Done at runtime by mslhd after every start rather than baked into the
/// images, so images that already exist get it too. Idempotent: it only
/// creates a link that is missing and never replaces anything already at
/// `~/Mac` - a user's own folder or link of that name wins. The link is
/// chowned to the home's owner, or `HomeOwnership`'s scan would count it as
/// a wrongly owned file. `/etc/skel` gets one too, so accounts created later
/// start with it.
public enum GuestHomeLinks {
    public static let linkName = "Mac"

    public static let script = """
    set -u
    [ -d \(GuestPathMapper.macHomeMountPoint) ] || { echo "MSL-MACLINK-NOSHARE"; exit 0; }
    for home in /root /home/* /etc/skel; do
        [ -d "$home" ] || continue
        link="$home/\(linkName)"
        if [ -e "$link" ] || [ -L "$link" ]; then continue; fi
        ln -s \(GuestPathMapper.macHomeMountPoint) "$link" 2>/dev/null || continue
        owner=$(stat -c '%u:%g' "$home" 2>/dev/null) && chown -h "$owner" "$link" 2>/dev/null
        echo "MSL-MACLINK $link"
    done
    echo "MSL-MACLINK-OK"
    """
}
