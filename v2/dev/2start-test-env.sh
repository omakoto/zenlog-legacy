#!/bin/bash

set -e

export ZENLOG_START_COMMAND="/bin/bash --norc --noprofile "
export PATH="$(dirname "$0"):$PATH"
export ZENLOG_DIR=/tmp/zenlog

export ZENLOG_DEBUG=1

unset PROMPT_COMMAND
xterm -e "/bin/bash --norc --noprofile" &
