package Zenlog;

use strict;
use POSIX;
use Time::HiRes qw(time);
use File::Path qw(make_path);
use File::Basename;

use constant DEBUG => ($ENV{ZENLOG_DEBUG} or 0);

#=====================================================================
# Config and core functions.
#=====================================================================

sub debug(@) {
  if (DEBUG) {
    print("\x1b[0m\x1b[1;31m", map(s!\r*\n!\r\n!gr ,@_), "\x1b[0m"); #!
  }
}

my $PROMPT_MARKER =         "\x1b[0m\x1b[1m\x1b[00000m";
# my $PAUSE_MARKER =          "\x1b[0m\x1b[2m\x1b[00000m";
# my $RESUME_MARKER =         "\x1b[0m\x1b[3m\x1b[00000m";
my $NO_LOG_MARKER =         "\x1b[0m\x1b[4m\x1b[00000m";
my $COMMAND_START_MARKER =  "\x1b[0m\x1b[5m\x1b[00000m";
my $COMMAND_END_MARKER =    "\x1b[0m\x1b[6m\x1b[00000m";

my $RC_FILE =  "$ENV{HOME}/.zenlogrc.pl";

# Start this command instead of the default shell.
my $ZENLOG_START_COMMAND;

# Log directory.
my $ZENLOG_DIR;

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
my $ZENLOG_PREFIX_COMMANDS;

# Always not log output from these commands.
my $ZENLOG_ALWAYS_184_COMMANDS;

# Load the .zenlogrc.pl file to set up the $ZENLOG* variables.
sub load_rc() {
  if (-f $RC_FILE) {
    debug("Loading ", $RC_FILE, " ...\n");
    do $RC_FILE;
  }

  $ZENLOG_START_COMMAND = ($ENV{ZENLOG_START_COMMAND} or "$ENV{SHELL} -l");

  # Log directory.
  $ZENLOG_DIR = ($ENV{ZENLOG_DIR} or "/tmp/zenlog/");

  # Prefix commands are ignored when command lines are parsed;
  # for example "sudo cat" will considered to be a "cat" command.
  $ZENLOG_PREFIX_COMMANDS = ($ENV{ZENLOG_PREFIX_COMMANDS}
      or "(?:builtin|time|sudo)");

  # Always not log output from these commands.
  $ZENLOG_ALWAYS_184_COMMANDS = ($ENV{ZENLOG_ALWAYS_184_COMMANDS}
      or "(?:vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)");

  debug("ZENLOG_DIR=", $ZENLOG_DIR, "\n");
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

#=====================================================================
# Shell command parsing helpers.
#=====================================================================

# Extract the comment, if exists, from a command line.
sub extract_comment($) {
  my ($file) = @_;

  my $i = 0;
  my $next_char = sub {
    return undef if $i >= length($file);
    return substr($file, $i++, 1);
  };
  my $ch;

  OUTER:
  while (defined($ch = &$next_char())) {
    if ($ch eq '#') {
      # Remove the leading spaces and return.
      return substr($file, $i) =~ s/^\s+//r; #/
    }
    if ($ch eq '\\') {
      $i++;
      next;
    }
    if ($ch eq "\'") {
      while (defined($ch = &$next_char())) {
        if ($ch eq "\'") {
          next OUTER;
        }
      }
      return "";
    }
    if ($ch eq "\"") {
      while (defined($ch = &$next_char())) {
        if ($ch eq '\\') {
          $i++;
          next;
        }
        if ($ch eq "\"") {
          next OUTER;
        }
      }
      return "";
    }
  }
  return "";
}

#=====================================================================
# Subcommands
#=====================================================================

our %sub_commands = ();

$sub_commands{prompt_marker} = sub { print $PROMPT_MARKER; };
# $sub_commands{pause_marker} = sub { print $PAUSE_MARKER; };
# $sub_commands{resume_marker} = sub { print $RESUME_MARKER; };
$sub_commands{no_log_marker} = sub { print $NO_LOG_MARKER; };
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

$sub_commands{ensure_log_dir} = sub {
  if ($ENV{ZENLOG_DIR}) {
    return 1;
  } else {
    print STDERR "Error: \$ZENLOG_DIR not set.\n";
    return 0;
  };
};

# Print outer-tty, only when in-zenlog.
$sub_commands{show_command} = sub {
  return 0 unless in_zenlog;
  print($COMMAND_START_MARKER, join(" ", @_), $COMMAND_END_MARKER);
};

$sub_commands{sh_helper} = sub {

  # Note in this script, ESC characters are converted into "\e", so that
  # output from the set command won't contain special characters.

  my $output = <<'EOF';
# Equivalent to zenlog in-zenlog.  Inlined for performance.
function in_zenlog() {
  [[ "$ZENLOG_TTY" == $(tty) ]]
}

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
      shescape_ee($NO_LOG_MARKER),
      );
};

#=====================================================================
# Logger
#=====================================================================

# raw/san filehandles and filenames.
my ($raw, $san, $cur_raw_name, $cur_san_name);

# Log sequence number.
my $log_seq_number = 0;

# Return true if we're currently logging.
sub logging() {
  return defined $cur_raw_name;
}

# Close current log.
sub close_log() {
  return unless logging;

  debug("Closing log.\n");

  $raw->close() if defined $raw;
  $san->close() if defined $san;
  undef $raw;
  undef $san;
  undef $cur_raw_name;
  undef $cur_san_name;
}

# Create the P and R links to the current log files.
sub create_prev_links($) {
  my ($link_dir) = @_;

  return unless logging();

  for my $mark ( "R", "P" ) {
    my $num = 10;
    unlink("${link_dir}/" . ($mark x $num));
    while ($num >= 2) {
      rename("${link_dir}/" . ($mark x ($num-1)), "${link_dir}/" . ($mark x $num));
      $num--;
    }
  }

  symlink($cur_raw_name, "${link_dir}/R");
  symlink($cur_san_name, "${link_dir}/P");
}

# Create symlinks.
sub create_links($$) {
  my ($parent_dir_name, $dir_name) = @_;

  return unless logging();

  # Normalzie the directory name.
  $dir_name =~ s! \s+ $!!xg;
  $dir_name =~ s! [ / \s ]+ !_!xg;

  # Avoid typical errors...; don't create if the directory name would
  # be "." or "..";
  return if $dir_name =~ m!^ ( \. | \.\. ) $!x;

  my $t = time;

  my $full_dir_name = "$ZENLOG_DIR/$parent_dir_name/$dir_name/";

  my $raw_dir = sprintf('%s/RAW/%s',
      $full_dir_name,
      strftime('%Y/%m/%d', localtime($t)));
  $raw_dir =~ s!/+!/!g;
  my $san_dir = $raw_dir =~ s!/RAW/!/SAN/!r; #!

  make_path($raw_dir);
  make_path($san_dir);

  my $raw_file = ($cur_raw_name =~ s!^.*/!!r); #!
  my $san_file = ($cur_san_name =~ s!^.*/!!r); #!

  symlink($cur_raw_name, "$raw_dir/$raw_file");
  symlink($cur_san_name, "$san_dir/$san_file");

  create_prev_links($full_dir_name);
}

sub open_log() {
  close_log();

  my $t = time;

  my $raw_name = sprintf('%s/RAW/%s.%03d-%05d-%04d.log',
      $ZENLOG_DIR,
      strftime('%Y/%m/%d/%H-%M-%S', localtime($t)),
      ($t - int($t)) * 1000, $$, $log_seq_number++);
  $raw_name =~ s!/+!/!g;
  my $san_name = $raw_name =~ s!/RAW/!/SAN/!r; #!

  make_path(dirname($raw_name));
  make_path(dirname($san_name));

  $cur_raw_name = $raw_name;
  $cur_san_name = $san_name;

  debug("Opening ", $cur_raw_name, " and ", $cur_san_name, "\n");

  open($raw, ">$cur_raw_name");
  open($san, ">$cur_san_name");

  $raw->autoflush();
  $san->autoflush();

  # Create and update the P/R links, and also create
  # the pids/$$/ links.
  create_prev_links($ZENLOG_DIR);
  create_links("pids", $$);
}

sub write_log($) {
  return unless logging;

  my ($line) = @_;
  $raw->print($line);

  # Sanitize
  $line =~ s! (
        \a                         # Bell
        | \e \x5B .*? [\x40-\x7E]  # CSI
        | \e \x5D .*? \x07         # Set terminal title
        | \e \( .                  # 3 byte sequence
        | \e [\x40-\x5A\x5C\x5F]   # 2 byte sequence
        )
        !!gx;
  # Also clean up CR/LFs.
  $line =~ s! \s* \x0d* \x0a !\x0a!gx;       # Remove end-of-line CRs.
  $line =~ s! \s* \x0d !\x0a!gx;             # Replace orphan CRs with LFs.

  # Also replace ^H's.
  $line =~ s! \x08 !^H!gx;
  $san->print($line) if defined $san;
}

sub zen_logging($) {
  my ($reader) = @_;

  make_path($ZENLOG_DIR);
  print "Logging to '$ZENLOG_DIR'...\n";

  # my $paused = 0;

  OUTER:
  while (defined(my $line = <$reader>)) {
    # if ($paused) {
    #   # When pausing, just skip until the next resume marker.
    #   if ($line =~ m!\Q$RESUME_MARKER\E!o) {
    #     $paused = 0;
    #   }
    #   next;
    # }

    # if ($line =~ m!\Q$PAUSE_MARKER\E!o) {
    #   # Pause marker detected.
    #   debug("Still paused.\n");
    #   $paused = 1;
    #   next;
    # }

    if ($line =~ m!\Q$NO_LOG_MARKER\E!o) {
      # 184 marker, skip the next command.
      debug("No-log marker detected.\n");
      write_log("[retracted]\n");
      close_log();
      next;
    }

    # Command line and output marker.
    if ($line =~ m! \Q$COMMAND_START_MARKER\E (.*?) \Q$COMMAND_END_MARKER\E !xo) {
      my $command = $1;

      $command =~ s!^\s+!!;
      $command =~ s!\s+$!!;

      if ($command =~ /^exit(?:\s+\d+)?$/x) {
        # Special case; don't log 'exit'.
        next OUTER;
      }

      # Split up the command by &&, ||, | and ;.
      # TODO: Actually tokenize the command line to avoid splitting in strings...
      my @exes = ();
      for my $single_command ( split(/(?: \&\& | \|\|? | \; )/x, $command)) {
        $single_command =~ s!^ [ \s \( ]+ !!x; # Remove prefixing ('s.

        # Remove prefix commands, such as "builtin" and "time".
        while ($single_command =~ s!^${ZENLOG_PREFIX_COMMANDS}\s+!!o) { #!
        }

        # Get the first token, which is the command.
        my $exe = (split(/\s+/, $single_command, 2))[0];

        $exe =~ s!^ \\ !!x; # Remove first '\'.
        $exe =~ s!^ .*/ !!x; # Remove file path

        debug("Exe: ", $exe, "\n");
        if ($exe =~ /^$ZENLOG_ALWAYS_184_COMMANDS$/o) {
          debug("Always no-log detected.\n");
          next OUTER;
        }
        push @exes, $exe;
      }
      # Always-184 command not detected.
      # Open the log, and write the command in italic-bold.
      open_log();
      write_log("\$ \e[1;3;4m$command\e\[0m\n");
      for my $exe (@exes) {
        create_links("cmds", $exe);
      }

      my $tag = extract_comment($command);
      create_links("tags", $tag) if $tag;

      next OUTER;
    }
    next unless logging;

    if ($line =~ m!^ (.*) \Q$PROMPT_MARKER\E !xo) {
      debug("Prompt detected.\n");
      # Prompt detected.
      my $rest = $1;
      write_log $rest if $1;
      close_log;
      next;
    }
    write_log($line);
  }
  close_log();
  debug "Logger finishing.\n";
}

#=====================================================================
# Forker
#=====================================================================
sub export_env() {
  $ENV{ZENLOG_PID} = $$;
  $ENV{ZENLOG_OUTER_TTY} = `tty 2>/dev/null` or die "$0: Unable to get tty: $!\n";
  $ENV{ZENLOG_DIR} = $ZENLOG_DIR;

  # Deprecated; it's just for backward compatibility.  Don't use it.
  $ENV{ZENLOG_CUR_LOG_DIR} = $ENV{ZENLOG_DIR};
}

sub start() {
  load_rc;
  export_env;

  my ($reader_fd, $writer_fd) = POSIX::pipe();
  $reader_fd or die "$0: pipe() failed: $!\n";

  debug("Pipe opened: read=$reader_fd, write=$writer_fd\n");

  if (my $pid = fork()) {
    POSIX::close($reader_fd);
    # Parent
    my $start_command = $ZENLOG_START_COMMAND;
    my @command = ("script",
        "-fqc",
        "export ZENLOG_TTY=\$(tty); exec $start_command",
        "/proc/self/fd/$writer_fd");
    debug("Starting: ", join(" ", map(shescape($_), @command)), "\n");
    kill 'INT', getppid;
    exec(@command);

    die "$0: failed to start script: $!\n";
  }
  # Child
  POSIX::close($writer_fd);
  open(my $reader, "<&=", $reader_fd) or die "$0: fdopen failed: $!\n";

  # Now $reader is the log input.

  zen_logging($reader);
  close $reader;
  return 1;
}

#=====================================================================
# Entry point
#=====================================================================
sub main(@) {
  my (@args) = @_;

  my $exe_dir = $0 =~ s!/[^/]+?$!!r; #!

  # If no arguments are provided, start new zenlog.
  if (@args == 0) {
    fail_if_in_zenlog;
    exit(start() == 0 ? 1 : 0);
  }

  # Otherwise, start a subcommand.

  # Delegate to the subcommand.
  my $subcommand = shift @args;
  debug("Running subcommand: ", $subcommand, "\n");

  my $subcommand_us = $subcommand =~ s!-!_!gr; #!
  my $subcommand_hy = $subcommand =~ s!_!-!gr; #!

  # See if there's a function for that.
  if (exists $sub_commands{$subcommand_us}) {
    exit(&{$sub_commands{$subcommand_us}} ? 0 : 1);
  }

  # Otherwise, try to locate the command and execute it.
  for my $command (
      "zenlog-$subcommand",
      "zenlog-$subcommand_hy",
      "zenlog_$subcommand_us") {
    # Find along with PATH, but check the script dir first.
    for my $path ($exe_dir, split(/:/, $ENV{PATH})) {
      my $c = "$path/$command";
      debug("Checking ", $c, "\n");
      if (-X $c) {
        exec($c, @args) or exit 1;
      }
    }
  }

  die "zenlog: Unknown subcommand '$subcommand'.\n";
}

1;
