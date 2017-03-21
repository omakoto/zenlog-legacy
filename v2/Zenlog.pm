# Zenlog core functions/variables.

use strict;
use constant DEBUG => 1;

sub PROMPT_MARKER()        { "\x1b[0m\x1b[1m\x1b[00000m" }
sub PAUSE_MARKER()         { "\x1b[0m\x1b[2m\x1b[00000m" }
sub RESUME_MARKER()        { "\x1b[0m\x1b[3m\x1b[00000m" }
sub NO_LOG_MARKER()        { "\x1b[0m\x1b[4m\x1b[00000m" }
sub COMMAND_START_MARKER() { "\x1b[0m\x1b[5m\x1b[00000m" }
sub COMMAND_END_MARKER()   { "\x1b[0m\x1b[6m\x1b[00000m" }

sub RC_FILE() { "$ENV{HOME}/.zenlogrc.pl" }

my %vars = ();

# Start this command instead of the default shell.
my $ZENLOG_START_COMMAND = ($ENV{ZENLOG_START_COMMAND} or "$ENV{SHELL} -l");

# Log directory.
my $ZENLOG_DIR = ($ENV{ZENLOG_DIR} or "/tmp/zenlog/");

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
my $ZENLOG_PREFIX_COMMANDS = ($ENV{ZENLOG_PREFIX_COMMANDS}
    or "(?:builtin|time|sudo)");

# Always not log output from these commands.
my $ZENLOG_ALWAYS_184_COMMANDS = ($ENV{ZENLOG_ALWAYS_184_COMMANDS}
    or "(?:vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)");

$vars{start_command} = \$ZENLOG_START_COMMAND;
$vars{log_dir} = \$ZENLOG_DIR;
$vars{prefix_commands} = \$ZENLOG_PREFIX_COMMANDS;
$vars{always_184_commands} = \$ZENLOG_ALWAYS_184_COMMANDS;

# Load the .zenlogrc.pl file to set up the $ZENLOG* variables.
sub load_rc() {
  require (RC_FILE) if -f RC_FILE;

  $ENV{ZENLOG_DIR} = $ZENLOG_DIR;
  # Deprecated; it's just for backward compatibility.  Don't use it.
  $ENV{ZENLOG_CUR_LOG_DIR} = $ENV{ZENLOG_DIR};
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

# shescape + convert ESC's to '\e'.
sub shescape_ee($) {
  my ($arg) = @_;
  return (shescape($arg) =~ s!\x1b!\\e!rg); #!
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

sub get_var($) {
  my ($name) = @_;
  die "Internal error: undefined var '$name'\n" unless exists $vars{$name};
  return ${$vars{$name}};
}

1;
