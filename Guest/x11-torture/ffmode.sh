#!/bin/bash
# ffmode.sh [core|xi2] [log] - Firefox on a long page, optionally forcing an
# input mode. With `log`, Firefox's widget log goes to the shared folder
# (~/Desktop/MSL-Project/fflogs on the Mac) - it shows every scroll event
# Firefox receives, and the ones it drops as duplicates.
[ "$1" = xi2 ] && export MOZ_USE_XINPUT2=1
[ "$1" = core ] && export MOZ_USE_XINPUT2=0
if [ "$2" = log ]; then
    export MOZ_LOG="Widget:5,WidgetPopup:5,sync"
    export MOZ_LOG_FILE=/mnt/mac/Desktop/MSL-Project/fflogs/ff
fi
exec firefox-esr about:license
