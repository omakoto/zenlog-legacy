# Zenlog shell helper.

# Show it in the prompt.  zenlog uses it to split log files.
_zenlog_prompt_marker=$(echo -e '\e[0m\e[1m\e[00000m')
zenlog_prompt_marker() {
  echo $_zenlog_prompt_marker
}

_zenlog_remove_marker=$(echo -e '\e[0m\e[5m\e[00000m')
zenlog_remove_marker() {
  echo $_zenlog_remove_marker
}

_zenlog_pause_marker=$(echo -e '\e[0m\e[6m\e[00000m')
zenlog_pause_marker() {
  echo $_zenlog_pause_marker
}

_zenlog_resume_marker=$(echo -e '\e[0m\e[7m\e[00000m')
zenlog_resume_marker() {
  echo $_zenlog_resume_marker
}

zenlog_pause() {
  echo $_zenlog_pause_marker >/dev/tty
}

zenlog_resume() {
  echo $_zenlog_resume_marker >/dev/tty
}

# execute command without logging output.
zenlog_nolog() {
  echo -en '\e[0m\e[2m\e[00000m'
  "${@}"
}

alias 184=zenlog_nolog

# Use it to avoid ZENLOG_ALWAYS_184.
zenlog_no_auto_184() {
  "${@}"
}
alias 186=zenlog_no_auto_184

# Use it to echo back the entire command in pre-exec hook.
# (Optional)
zenlog_echo_command() {
  echo -en "\e[0m\e[3m\e[00000m$(tr -s '\r\n' '  ' <<< "${*}")\e[0m\e[4m\e[00000m"
  echo -e "\e[0m"
}

in_zenlog() {
  [[ "$ZENLOG_TTY" == $(tty) ]]
}

zenlog_fail_if_not_in_zenlog() {
  if ! in_zenlog ; then
    echo "zenlog: Error: not in zenlog." 1>&2
    return 1
  fi
  return 0
}

zenlog_history() {
  local filename="PPPPPPPPPPX"
  local nth=""
  local no_zenlog_check=0
  local pid=$ZENLOG_PID

  local OPTIND
  local OPTARG
  while getopts "xrp:n:" opt; do
    case "$opt" in
      r) filename="RRRRRRRRRRX" ;;
      p) pid="$OPTARG" ;;
      n) nth="$OPTARG" ;;
      x) no_zenlog_check=1 ;;
      *) return 1;;
    esac
  done
  shift $(($OPTIND - 1))
  if (( ! $no_zenlog_check )) ; then
    zenlog_fail_if_not_in_zenlog || return 1
  fi

  {
    if [[ -n "$nth" ]] ; then
      command ls "$ZENLOG_CUR_LOG_DIR/pids/$pid/${filename:0:$(($nth + 1))}"
    else
      command ls "$ZENLOG_CUR_LOG_DIR"/pids/$pid/${filename:0:1}* | sort -r
    fi
  } 2>/dev/null | while read n ; do
    [[ -f "$n" ]] && {
      # Resolve symlink, but only one level.
      command ls -l "$n" | sed -e 's/.* -> //'
    }
  done
}

zenlog_last_log() {
  # Provide the default "n" at the beginning, so it can be overridden.
  zenlog_history -n 1 "${@}"
}

zenlog_open_viewer() {
  local file="$1"
  if [[ -n "$file" ]] ; then
    echo "zenlog: Opening $file ..."
    ${ZENLOG_VIEWER:-$PAGER} "$file"
  fi
}

zenlog_open_last_log() {
  zenlog_fail_if_not_in_zenlog || return 1

  zenlog_open_viewer "$(zenlog_last_log "${@}")"
}

zenlog_cat_last_log() {
  zenlog_fail_if_not_in_zenlog || return 1

  cat "$(zenlog_last_log "${@}")"
}

zenlog_cat_last_log_content() {
  zenlog_fail_if_not_in_zenlog || return 1

  sed -e "1d" -- "$(zenlog_last_log "${@}" -r)"
}

# Useful: when used with -p PID.
zenlog_current_log() {
  zenlog_history -n 0 "${@}"
}

# Useful: when used with -p PID.
zenlog_open_current_log() {
  zenlog_fail_if_not_in_zenlog || return 1

  zenlog_open_viewer "$(zenlog_current_log "${@}")"
}

zenlog_du() {
  du "${ZENLOG_CUR_LOG_DIR:-$ZENLOG_DIR}" "$@"
}
