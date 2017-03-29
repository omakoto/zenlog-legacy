#!/bin/bash

set -e

export ZENLOG_START_COMMAND="/usr/bin/zsh -l"
export PATH="$(dirname "$0"):$PATH"
export ZENLOG_DIR=/tmp/zenlog

export ZENLOG_DEBUG=1

xterm /usr/bin/zsh &
