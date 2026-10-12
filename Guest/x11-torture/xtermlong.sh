#!/bin/bash
# xterm with a screenful of scrollback to wheel through
exec xterm -geometry 80x24 -e bash -c 'seq 1 400; exec bash'
