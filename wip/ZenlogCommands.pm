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

$commands{sh_helper} = sub {
  my $output = <<'EOF';
export ZENLOG_DIR=%s
export ZENLOG_CUR_LOG_DIR=%s
EOF
  printf($output,
      Zenlog::shescape($Zenlog::ZENLOG_DIR),
      Zenlog::shescape($Zenlog::ZENLOG_CUR_LOG_DIR));
};


1
