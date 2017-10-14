# Basic zenlog setup for bash

# Include this file from .bash_profile like:
# . PATH-TO-THIS-FILE/zenlog.bash

# Zenlog top directory, which is the parent of this directory.
ZENLOG_TOP="$(dirname "$(readlink -e "${BASH_SOURCE[0]}")")"/..

# Zenlog main command file.
ZENLOG="${ZENLOG_TOP}/current/zenlog"

ZENLOG_VIEWER=less

# Install the basic shell helper functions.
. <("$ZENLOG" sh-helper)

# Stop the current logging before every prompt.
_prompt_command() {
  "$ZENLOG" stop-log
}

# Before starting a command, tell zenlog to start logging, with the
# full command line.
_preexec_command() {
  "$ZENLOG" start-command $(bash_last_command)
}

PROMPT_COMMAND="_prompt_command"
PS0='$(_preexec_command)'

# Press ALT+1 on prompt to open the last log.
bind -x '"\e1": "$ZENLOG open-current-log"'
