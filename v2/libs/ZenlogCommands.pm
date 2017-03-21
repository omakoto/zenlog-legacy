# Zenlog subcommands.

use strict;
use Zenlog;

our %sub_commands = ();

$sub_commands{prompt_marker} = sub { print PROMPT_MARKER; };
$sub_commands{pause_marker} = sub { print PAUSE_MARKER; };
$sub_commands{resume_marker} = sub { print RESUME_MARKER; };
$sub_commands{no_log_marker} = sub { print NO_LOG_MARKER; };
# They're not needed by the outer world.
# $sub_commands{command_start_marker} = sub { print COMMAND_START_MARKER; };
# $sub_commands{command_end_marker} = sub { print COMMAND_END_MARKER; };

# Aliases.
$sub_commands{pause} = $sub_commands{pause_marker};
$sub_commands{resume} = $sub_commands{resume_marker};
$sub_commands{no_log} = $sub_commands{no_log_marker};

$sub_commands{in_zenlog} = sub { return in_zenlog; };
$sub_commands{fail_if_in_zenlog} = sub { return fail_if_in_zenlog; };
$sub_commands{fail_unless_in_zenlog} = sub { return fail_unless_in_zenlog; };

# Print outer-tty, only when in-zenlog.
$sub_commands{outer_tty} = sub {
  return 0 unless in_zenlog;
  print $ENV{ZENLOG_OUTER_TTY}, "\n";
  return 1;
};

# Print outer-tty, only when in-zenlog.
$sub_commands{show_command} = sub {
  return 0 unless in_zenlog;
  print(COMMAND_START_MARKER, join(" ", @_), COMMAND_END_MARKER);
};

$sub_commands{sh_helper} = sub {

  # Note in this script, ESC characters are converted into "\e", so that
  # output from the set command won't contain special characters.

  my $output = <<'EOF';
# Run a command without logging the output.
function zenlog_nolog() {
  echo -e %s
  "${@}"
}
alias 184=zenlog_nolog

# Run a command *with* logging the output, ignoring ZENLOG_ALWAYS_184_COMMANDS.
function zenlog_no_auto_184() {
  # Note it doesn't have to do anything -- 186 will just fool zenlog.pl
  # and make it misunderstand the actual command name.
  "${@}"
}
alias 186=zenlog_no_auto_184

EOF
  printf($output,
      shescape_ee(NO_LOG_MARKER),
      );
};

sub get_subcommands() {
  return \%sub_commands;
}

1;
