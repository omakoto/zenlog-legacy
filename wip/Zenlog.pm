package Zenlog;

use strict;

use constant
    DEBUG => 0,
    ;

sub PROMPT_MARKER()        { "XX\x1b[0m\x1b[1m\x1b[00000m" }
sub PAUSE_MARKER()         { "XX\x1b[0m\x1b[2m\x1b[00000m" }
sub RESUME_MARKER()        { "XX\x1b[0m\x1b[3m\x1b[00000m" }
sub NO_LOG_MARKER()        { "XX\x1b[0m\x1b[4m\x1b[00000m" }
sub COMMAND_START_MARKER() { "XX\x1b[0m\x1b[5m\x1b[00000m" }
sub COMMAND_END_MARKER()   { "XX\x1b[0m\x1b[6m\x1b[00000m" }

sub RC_FILE() { "$ENV{HOME}/.zenlogrc.pl" }

# Start this command instead of the default shell.
our $ZENLOG_START_COMMAND = "$ENV{SHELL} -l";

# Log directory.
our $ZENLOG_DIR = "/tmp/zenlog/";

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
our $ZENLOG_PREFIX_COMMANDS = "(builtin|time|sudo)";

# Always do not log output from these commands.
our $ZENLOG_ALWAYS_184_COMMANDS = "(vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)";

# Load the .zenlogrc.pl file to set up the $ZENLOG* variables.
sub init_env() {
  require (RC_FILE) if -f RC_FILE;
}

# Escape a string for shell.
sub shescape($) {
  my ($arg) = @_;
  if ( $arg =~ /[^a-zA-Z0-9\-\.\_\/]/ ) {
      return("'" . ($arg =~ s/'/'\\''/gr) . "'"); #/
  } else {
      return($arg);
  }
}






1;
