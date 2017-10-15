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

open_last_log() {
  "$ZENLOG" open-current-log
}

open_last_raw() {
  local log="$("$ZENLOG" current-log -r)"
  local temp="$(tempfile)"

  a2h "$log" > "$temp" || {
    echo "Failed to execute A2H. Install it from https://github.com/omakoto/a2h-rs."
    return 1
  }
  "${ZENLOG_RAW_VIEWER:-google-chrome}" "$temp"
}

# Press ALT+1 on prompt to open the last log.
# See README.md.
bind -x '"\e1": "open_last_log"'

# Press ALT+2 on prompt to open the last log file on the web browser *with color*.
bind -x '"\e2": "open_last_raw"'
