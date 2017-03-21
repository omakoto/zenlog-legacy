# Zenlog subcommands.

package ZenlogCommands;

use strict;
use Zenlog;

our %commands = ();

$commands{prompt_marker} = sub { print Zenlog::PROMPT_MARKER; };
$commands{pause_marker} = sub { print Zenlog::PAUSE_MARKER; };
$commands{resume_marker} = sub { print Zenlog::RESUME_MARKER; };
$commands{no_log_marker} = sub { print Zenlog::NO_LOG_MARKER; };
$commands{command_start_marker} = sub { print Zenlog::COMMAND_START_MARKER; };
$commands{command_end_marker} = sub { print Zenlog::COMMAND_END_MARKER; };

$commands{in_zenlog} = sub { return Zenlog::in_zenlog; };
$commands{fail_if_in_zenlog} = sub { return Zenlog::fail_if_in_zenlog; };
$commands{fail_unless_in_zenlog} = sub { return Zenlog::fail_unless_in_zenlog; };

# Print outer-tty, only when in-zenlog.
$commands{outer_tty} = sub {
  return 0 unless Zenlog::in_zenlog;
  print $ENV{ZENLOG_OUTER_TTY}, "\n";
  return 1;
};

$commands{sh_helper} = sub {

  # Note in this script, ESC characters are converted into "\e", so that
  # output from the set command won't contain special characters.

# TODO This actually isn't really working as zenlog_prompt_marker can be
# embedded in PS1 anyway.
  my $output = <<'EOF';
zenlog_prompt_marker() {
  echo -e %s
}

zenlog_pause_marker() {
  echo -e %s
}

zenlog_resume_marker() {
  echo -e %s
}

# Run a command without logging the output.
zenlog_nolog() {
  echo -e %s
  "${@}"
}
alias 184=zenlog_nolog

# Run a command *with* logging the output, ignoring ZENLOG_ALWAYS_184_COMMANDS.
zenlog_no_auto_184() {
  # Note it doesn't have to do anything -- 186 will just fool zenlog.pl
  # and make it misunderstand the actual command name.
  "${@}"
}
alias 186=zenlog_no_auto_184

EOF
  printf($output, Zenlog::shescape_ee(Zenlog::NO_LOG_MARKER));
};


1
