# Zenlog main code (fork + logging.)

package ZenlogMain;

use strict;
use POSIX;
use Time::HiRes qw(time);
use File::Path qw(make_path);
use File::Basename;

use Zenlog;
use ZenlogCommands;

use constant DEBUG => Zenlog::DEBUG;

sub init_env() {
  $ENV{ZENLOG_PID} = $$;
  $ENV{ZENLOG_OUTER_TTY} = `tty 2>/dev/null` or die "$0: Unable to get tty: $!\n";
}

sub start() {
  init_env;

  my ($reader_fd, $writer_fd) = POSIX::pipe();
  $reader_fd or die "$0: pipe() failed: $!\n";

  printf STDERR ("# pipe opened, read=%d, write=%d\n",
      $reader_fd, $writer_fd) if DEBUG;

  if (my $pid = fork()) {
    POSIX::close($reader_fd);
    # Parent
    exec("script",
      "-fqc",
      "export ZENLOG_TTY=\$(tty); exec /bin/bash -l",
      "/proc/self/fd/$writer_fd") or die "$0: failed to start script: $!\n";
  }
  # Child
  POSIX::close($writer_fd);
  open(my $reader, "<&=", $reader_fd) or die "$0: fdopen failed: $!\n";

  while (defined(my $line = <$reader>)) {
    print ">>> ", $line;
  }
  print "Logger finishing.\n";
}




1;
