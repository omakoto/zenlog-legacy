# Zenlog main code (start script and get the log FD.)

use strict;
use POSIX;

use Zenlog;
use ZenlogCommands;
use ZenLogger;

sub init_env() {
  $ENV{ZENLOG_PID} = $$;
  $ENV{ZENLOG_OUTER_TTY} = `tty 2>/dev/null` or die "$0: Unable to get tty: $!\n";
}

sub start() {
  init_env;

  my ($reader_fd, $writer_fd) = POSIX::pipe();
  $reader_fd or die "$0: pipe() failed: $!\n";

  debug("# pipe opened, read=%d, write=%d\n", $reader_fd, $writer_fd);

  if (my $pid = fork()) {
    POSIX::close($reader_fd);
    # Parent
    my $start_command = get_var("start_command");
    my @command = ("script",
        "-fqc",
        "export ZENLOG_TTY=\$(tty); exec $start_command",
        "/proc/self/fd/$writer_fd");
    debug("Starting: ", join(" ", map(shescape($_), @command)), "\n");

    exec(@command) or die "$0: failed to start script: $!\n";
  }
  # Child
  POSIX::close($writer_fd);
  open(my $reader, "<&=", $reader_fd) or die "$0: fdopen failed: $!\n";

  # Now $reader is the log input.

  zen_logging($reader);
  close $reader;
}

1;
