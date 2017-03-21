package Zenlog;

use strict;

use constant DEBUG => 1;

sub PROMPT_MARKER()        { "\x1b[0m\x1b[1m\x1b[00000m" }
sub PAUSE_MARKER()         { "\x1b[0m\x1b[2m\x1b[00000m" }
sub RESUME_MARKER()        { "\x1b[0m\x1b[3m\x1b[00000m" }
sub NO_LOG_MARKER()        { "\x1b[0m\x1b[4m\x1b[00000m" }
sub COMMAND_START_MARKER() { "\x1b[0m\x1b[5m\x1b[00000m" }
sub COMMAND_END_MARKER()   { "\x1b[0m\x1b[6m\x1b[00000m" }

sub RC_FILE() { "$ENV{HOME}/.zenlogrc.pl" }

# Start this command instead of the default shell.
our $ZENLOG_START_COMMAND = ($ENV{ZENLOG_START_COMMAND} or "$ENV{SHELL} -l");

# Log directory.
our $ZENLOG_DIR = ($ENV{ZENLOG_DIR} or "/tmp/zenlog/");

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
our $ZENLOG_PREFIX_COMMANDS = ($ENV{ZENLOG_PREFIX_COMMANDS}
    or "(builtin|time|sudo)");

# Always do not log output from these commands.
our $ZENLOG_ALWAYS_184_COMMANDS = ($ENV{ZENLOG_ALWAYS_184_COMMANDS}
    or "(vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)");

# Load the .zenlogrc.pl file to set up the $ZENLOG* variables.
sub load_rc() {
  require (RC_FILE) if -f RC_FILE;

  $ENV{ZENLOG_DIR} = $ZENLOG_DIR;
}

# Escape a string for shell.
sub shescape($) {
  my ($arg) = @_;
  if ( $arg =~ /[^a-zA-Z0-9\-\.\_\/]/ ) {
      return ("'" . ($arg =~ s/'/'\\''/gr) . "'"); #/
  } else {
      return $arg;
  }
}

# Return true if in zenlog.
sub in_zenlog() {
  my $tty = `tty`;
  chomp $tty;
  my $in_zenlog = ($ENV{ZENLOG_TTY} eq $tty);
  # print "in-zenlog -> $in_zenlog\n" if DEBUG;
  return $in_zenlog;
}

# Die if in zenlog.
sub fail_if_in_zenlog() {
  in_zenlog and die "Already in zenlog.\n";
}

# Die if *not* in zenlog.
sub fail_unless_in_zenlog() {
  in_zenlog or die "Not in zenlog.\n";
}

1;
