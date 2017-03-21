package ZenlogCommands;

use strict;
use Zenlog;

our %commands = ();

$commands{prompt_marker} = sub { print Zenlog::PROMPT_MARKER; return 0};
$commands{pause_marker} = sub { print Zenlog::PAUSE_MARKER; return 0};
$commands{resume_marker} = sub { print Zenlog::RESUME_MARKER; return 0};
$commands{no_log_marker} = sub { print Zenlog::NO_LOG_MARKER; return 0};
$commands{command_start_marker} = sub { print Zenlog::COMMAND_START_MARKER; return 0};
$commands{command_end_marker} = sub { print Zenlog::COMMAND_END_MARKER; return 0};

$command{sh_helper} = sub {
  print "export ZENLOG_CUR_LOG_DIR=";


EOF
};


1
