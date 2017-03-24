package Zenlog;

use strict;
use Cwd qw();
use File::Basename qw(dirname);
use POSIX;
use Time::HiRes qw(time);
use File::Path qw(make_path);
use File::Basename;
use File::Path;

use constant DEBUG => ($ENV{ZENLOG_DEBUG} or 0);

#=====================================================================
# Usage for the zenlog command.
#=====================================================================

sub usage() {
  print <<'EOF';

Zenlog

  Start a new shell where all input/output from each command will be
  saved in a separate log file.

  ** MAKE SURE **
  ** - Update PS1 and include $(zenlog prompt-marker) in it **
  ** - Execute "zenlog start-command COMMAND LINE" in PS0 (aka preexec) **

Usage:
  - zenlog
    Start a new shell.

  - zenlog prompt-marker
    Print the marker that must be set to PS1 to tell zenlog the end of
    each command.

  - zenlog prompt-marker
    Print the marker that must be set to PS1 to tell zenlog the end of
    each command.

  - zenlog write-to-outer
    Write the content from the stdin on console, but not to the log.

    Example:
      echo "This will not be logged, but shown on terminal." \
        | zenlog write-to-outer

  - zenlog write-to-logger
    Write the content from the stdin to the log, but not on terminal.

    Example:
      echo "This will be logged, not shown on terminal" \
        | zenlog write-to-logger


  - zenlog purge-log [-y] -p DAYS
    Purge logs older than N days and exit.

    Options:
      -y:   Skip confirmation.

  - zenlog free-space
    Show the free space size of the log disk in bytes.

  - zenlog du [du options]
    Execute du on the log directory.

    Example:
      zenlog_du -h

  - zenlog in-zenlog
    Return sucess iif in zenlog.

  - zenlog sh-helper
    Use it like ". <(zenlog sh-helper)" to install support
    functions to the current shell.

    Commands are:
      - in_zenlog
          Equaivalent to "zenlog in-zenlog".

      - 184 COMMAND [args...]
          Run the passed command without logging the output.
          Example:
            184 emacs

  - zenlog -s [deprecated]
    Use it like ". <(zenlog -s)" to install v1-compatible
    support functions to the current shell.

  Other subcommands:
  - zenlog history [-n NTH] [-r for raw file]
    Print the last log filenames on the current terminal.

    Run "zenlog history -h" for more options.

  - zenlog last-log [-r for raw file]
    Print the last log filename on the current terminal.

  Files:
    $HOME/.zenlogrc.pl
          Initialization file.
          (See dot_zenlogrc.pl as an example.)

  Environmental variables:
    ZENLOG_DIR
          Specify log file directory.

    ZENLOG_START_COMMAND
          If set, start this command instead of "$SHELL -l".

    ZENLOG_ALWAYS_184
          Regex to match command names that shouldn't be logged.
          (^ and $ are assumed.)
          Needs to be used with zenlog_echo_command.
          Example: export ZENLOG_ALWAYS_184="(vi|emacs|man|zenlog.*)"

    ZENLOG_COMMAND_PREFIX
          Regex to match "prefix" commands, such as "time" and
          "builtin". (^ and $ are assumed.)

          This allows, e.g., a command "time ls -l" to be handled as
          "ls -l".

          Example: export ZENLOG_COMMAND_PREFIX="(builtin|time|sudo)"

EOF
}

#=====================================================================
# Config and core functions.
#=====================================================================

sub debug(@) {
  if (DEBUG) {
    print("\x1b[0m\x1b[1;31m", map(s!\r*\n!\r\n!gr ,@_), "\x1b[0m"); #!
  }
}

my $PROMPT_MARKER =         "\x1b[0m\x1b[1m\x1b[00000m";
my $LOG_START_MARKER =      "\x1b[0m\x1b[4m\x1b[00000m";

my $RC_FILE =  "$ENV{HOME}/.zenlogrc.pl";

# Start this command instead of the default shell.
my $ZENLOG_START_COMMAND;

# Log directory.
my $ZENLOG_DIR = $ENV{ZENLOG_DIR};

my $ZENLOG_PID = $ENV{ZENLOG_PID};

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
my $ZENLOG_PREFIX_COMMANDS = $ENV{ZENLOG_PREFIX_COMMANDS};

# Always not log output from these commands.
my $ZENLOG_ALWAYS_184_COMMANDS = $ENV{ZENLOG_ALWAYS_184_COMMANDS};

sub export_vars() {
  $ENV{ZENLOG_PID} = $$;
  $ENV{ZENLOG_DIR} = $ZENLOG_DIR;
  $ENV{ZENLOG_PREFIX_COMMANDS} = $ZENLOG_PREFIX_COMMANDS;
  $ENV{ZENLOG_ALWAYS_184_COMMANDS} = $ZENLOG_ALWAYS_184_COMMANDS;

  # Deprecated; it's just for backward compatibility.  Don't use it.
  $ENV{ZENLOG_CUR_LOG_DIR} = $ZENLOG_DIR;
}

# Load the .zenlogrc.pl file to set up the $ZENLOG* variables.
sub load_rc() {
  if (-f $RC_FILE) {
    debug("Loading ", $RC_FILE, " ...\n");
    do $RC_FILE;
  }

  $ZENLOG_START_COMMAND =
      ($ENV{ZENLOG_START_COMMAND} // "$ENV{SHELL} -l");

  # Log directory.
  $ZENLOG_DIR =
      ($ENV{ZENLOG_DIR} // "/tmp/zenlog/"); #"

  # Prefix commands are ignored when command lines are parsed;
  # for example "sudo cat" will considered to be a "cat" command.
  $ZENLOG_PREFIX_COMMANDS =
      ($ENV{ZENLOG_PREFIX_COMMANDS} // "(?:builtin|time|sudo)");

  # Always not log output from these commands.
  $ZENLOG_ALWAYS_184_COMMANDS =
      ($ENV{ZENLOG_ALWAYS_184_COMMANDS}
      // "(?:vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)");

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

sub get_tty() {
  my $tty =
      POSIX::ttyname(0) ||
      POSIX::ttyname(1) ||
      POSIX::ttyname(2);
  return $tty if $tty;

  # None of 0, 1 nor 2 is associated with a tty, so
  # get the tty associated with the current process.
  # There's no easy way to do this, so it lets the ps command
  # figure it out.
  $tty = qx(ps -o tty -p $$ --no-header 2>/dev/null);
  chomp $tty;
  $tty = "/dev/$tty" if $tty;
  return $tty;
}

# Return true if in zenlog.
sub in_zenlog() {
  my $tty = get_tty();
  my $in_zenlog = (($ENV{ZENLOG_TTY} // "") eq $tty);
  return $in_zenlog;
}

# Die if in zenlog.
sub fail_if_in_zenlog() {
  in_zenlog and die "Already in zenlog.\n";
}

# Die if not in zenlog.
sub fail_unless_in_zenlog() {
  in_zenlog or die "Not in zenlog.\n";
}

sub get_logger_pipe() {
  my $pipe = $ENV{ZENLOG_LOGGER_PIPE} // "";
  if (in_zenlog and -e $pipe) {
    return $pipe;
  } else {
    return "";
  }
}

# Remove escape sequences for SAN log.
sub sanitize($) {
  my ($str) = @_;

  $str =~ s! (
        \a                         # Bell
        | \e \x5B .*? [\x40-\x7E]  # CSI
        | \e \x5D .*? \x07         # Set terminal title
        | \e \( .                  # 3 byte sequence
        | \e [\x40-\x5A\x5C\x5F]   # 2 byte sequence
        )
        !!gx;

  # Also clean up CR/LFs.
  $str =~ s! \s* \x0d* \x0a !\x0a!gx;       # Remove end-of-line CRs.
  $str =~ s! \s* \x0d !\x0a!gx;             # Replace orphan CRs with LFs.

  # Also replace ^H's.
  $str =~ s! \x08 !^H!gx;
  return $str;
}

# Read from STDIN, and write to $path, if in-zenlog.
# Otherwise just write to STDOUT.
sub pipe_stdin_to_file($$) {
  my ($path, $cr_needed) = @_;
  *OUT = *STDOUT;
  if (in_zenlog) {
    open(OUT, ">", $path) or die "Cannot open '$path': $!\n";
  } else {
    $cr_needed = 0;
  }
  while(defined(my $line = <STDIN>)) {
    if ($cr_needed) {
      $line =~ s!\r*\n!\r\n!g;
    }
    print OUT $line;
  }
  close OUT;
  return 1;
}

#=====================================================================
# Shell command parsing helpers.
#=====================================================================

# Extract the comment, if exists, from a command line string.
sub extract_comment($) {
  my ($str) = @_;

  my $i = 0;
  my $next_char = sub {
    return undef if $i >= length($str);
    return substr($str, $i++, 1);
  };
  my $ch;

  OUTER:
  while (defined($ch = &$next_char())) {
    if ($ch eq '#') {
      # Remove the leading spaces and return.
      return substr($str, $i) =~ s/^\s+//r; #/
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
# Log file creation.  Called by start-command in the shell side.
#=====================================================================

# Create the P and R links to the log files.
sub create_prev_links($$$) {
  my ($link_dir, $san_name, $raw_name) = @_;

  for my $mark ( "R", "P" ) {
    my $num = 10;
    unlink("${link_dir}/" . ($mark x $num));
    while ($num >= 2) {
      rename("${link_dir}/" . ($mark x ($num-1)), "${link_dir}/" . ($mark x $num));
      $num--;
    }
  }

  symlink($raw_name, "${link_dir}/R");
  symlink($san_name, "${link_dir}/P");
}

# Create symlinks.
sub create_links($$$$) {
  my ($parent_dir_name, $dir_name, $san_name, $raw_name) = @_;

  # Normalize the directory name.
  $dir_name =~ s! \s+ $!!xg;
  $dir_name =~ s! [ / \s ]+ !_!xg; # Don't include space and slashes.

  # Avoid typical errors... Don't create if the directory name would
  # be "." or "..";
  return if $dir_name =~ m!^ ( \. | \.\. ) $!x;

  my $full_dir_name = "$ZENLOG_DIR/$parent_dir_name/$dir_name/";

  my $t = time;
  my $raw_dir = sprintf('%s/RAW/%s',
      $full_dir_name,
      strftime('%Y/%m/%d', localtime($t)));

  $raw_dir =~ s!/+!/!g;
  my $san_dir = $raw_dir =~ s!/RAW/!/SAN/!r; #!

  make_path($raw_dir);
  make_path($san_dir);

  my $r = ($raw_name =~ s!^.*/!!r); #!
  my $s = ($san_name =~ s!^.*/!!r); #!

  symlink($raw_name, "$raw_dir/$r");
  symlink($san_name, "$san_dir/$s");

  create_prev_links($full_dir_name, $san_name, $raw_name);
}

# Create a new pair of RAW / SAN files and write the command line,
# and [omitted] marker if needed.
sub create_log($$) {
  my ($command, $omitted) = @_;

  my $t = time;
  my $raw_name = sprintf('%s/RAW/%s.%03d-%05d.log',
      $ZENLOG_DIR,
      strftime('%Y/%m/%d/%H-%M-%S', localtime($t)),
      ($t - int($t)) * 1000, $ZENLOG_PID);
  $raw_name =~ s!/+!/!g;
  my $san_name = $raw_name =~ s!/RAW/!/SAN/!r; #!

  make_path(dirname($raw_name));
  make_path(dirname($san_name));

  debug("Opening ", $raw_name, " and ", $san_name, "\n");

  open(my $raw, ">", $raw_name);
  open(my $san, ">", $san_name);
  my $line = "\$ \e[1;3;4;33m$command\e[0m\n";
  $line .= "[omitted]\n" if $omitted;
  print $raw $line;
  print $san sanitize($line);
  close $raw;
  close $san;

  # Create and update the P/R links, and also create the pids/$$/
  # links.
  # We always create pid links, even for 184 commands, to keep
  # "zenlog history" sane.
  create_prev_links($ZENLOG_DIR, $san_name, $raw_name);
  create_links("pids", $ZENLOG_PID, $san_name, $raw_name);

  return ($san_name, $raw_name);
}

# Write the san/raw log file names to the logger directly.
sub write_log_names($$) {
  my ($san_name, $raw_name) = @_;
  my $pipe = get_logger_pipe;
  return unless $pipe;

  debug("pipe=", $pipe, "\n");
  open(my $out, ">", $pipe) or die "Cannot open $pipe: $!\n";
  print $out ($LOG_START_MARKER, "\t", $san_name, "\t", $raw_name, "\n");
  close $out;
}

# Body of "zenlog start-command".
sub start_log(@) {
  my (@command_line) = @_;

  return 0 if !in_zenlog;

  my $command = (join(" ", @command_line) =~ s!\r*\n! !rg);
  debug("Start log: command=", $command, "\n");
  $command =~ s!^\s+!!;
  $command =~ s!\s+$!!;

  if ($command =~ /^exit(?:\s+\d+)?/x) {
    # Special case; don't log 'exit'.
    return 1;
  }

  # If the line starts with "184", then don't log.
  my $omit = ($command =~ m!^ [\s\(]* 184 \s+ !x) ? 1 : 0;

  # But 186 will overrule 184.
  my $no_omit = ($command =~ m!^ [\s\(]* 186 \s+ !x) ? 1 : 0;
  $omit = 0 if $no_omit;

  # Split up the command by &&, ||, | and ;.
  # TODO: Actually tokenize the command line to avoid splitting in the
  # middle of a string...
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
    if (!$no_omit and ($exe =~ /^$ZENLOG_ALWAYS_184_COMMANDS$/o)) {
      debug("Always no-log detected.\n");
      $omit = 1;
      last;
    }
    push @exes, $exe;
  }

  # Note even if omitting, we still create the log files.
  # This is to make sure "zenlog last-history" always returns something sane.
  my ($san_name, $raw_name) = create_log($command, $omit);

  return 1 if $omit;

  # Tell the logger the filenames.
  write_log_names($san_name, $raw_name);

  # 184 command not detected; create more links.
  for my $exe (@exes) {
    create_links("cmds", $exe, $san_name, $raw_name);
  }

  my $tag = extract_comment($command);
  create_links("tags", $tag, $san_name, $raw_name) if $tag;

  return 1;
}

#=====================================================================
# Subcommands
#=====================================================================

our %sub_commands = ();

$sub_commands{prompt_marker} = sub { print $PROMPT_MARKER; };

$sub_commands{in_zenlog} = sub { return in_zenlog; };
$sub_commands{fail_if_in_zenlog} = sub { return fail_if_in_zenlog; };
$sub_commands{fail_unless_in_zenlog} = sub { return fail_unless_in_zenlog; };

# Print outer-tty, only when in-zenlog.
$sub_commands{outer_tty} = sub {
  return 0 unless in_zenlog;
  print $ENV{ZENLOG_OUTER_TTY}, "\n";
  return 1;
};

# Pipe to the outer TTY.
# Example:
# echo "This will not be logged, but shown on terminal." | zenlog write-to-outer
$sub_commands{write_to_outer} = sub {
  return pipe_stdin_to_file($ENV{ZENLOG_OUTER_TTY}, 1);
};

# Make sure $ZENLOG_DIR is set.  (It still may not exist.)
$sub_commands{ensure_log_dir} = sub {
  if ($ZENLOG_DIR) {
    return 1;
  } else {
    print STDERR "Error: \$ZENLOG_DIR not set.\n";
    return 0;
  };
};

# Show the TTY associated with the current process.
$sub_commands{process_tty} = sub {
  my $tty = get_tty;
  if ($tty) {
    print $tty, "\n";
    return 1;
  } else {
    return 0;
  }
};

$sub_commands{logger_pipe} = sub {
  my $pipe = get_logger_pipe;
  if ($pipe) {
    print $pipe, "\n";
    return 1;
  } else {
    print "/dev/null\n";
    return 0;
  }
};

# Pipe directly to the logger.
# Example:
# echo "This will be logged, not shown on terminal" | zenlog write-to-logger
$sub_commands{write_to_logger} = sub {
  return pipe_stdin_to_file((get_logger_pipe() or "/dev/null"), 0);
};

# Print outer-tty, only when in-zenlog.
$sub_commands{show_command} = sub {
  # Don't fail, so PS0 would still be safe without zenlog.
  return 0 unless in_zenlog;

  return start_log(@_);
};

# Alias.
$sub_commands{start_command} = $sub_commands{show_command};

$sub_commands{sh_helper} = sub {
  print <<'EOF';
# Return sucess when in zenlog.
function in_zenlog() {
  zenlog in-zenlog
}

# Run a command without logging the output.
function _zenlog_nolog() {
  "${@}"
}
alias 184=_zenlog_nolog

# Run a command with forcing log, regardless of ZENLOG_ALWAYS_184_COMMANDS.
function _zenlog_force_log() {
  "${@}"
}
alias 186=_zenlog_force_log

EOF
};

sub zenlog_history($$;$) {
  my ($num, $raw, $pid) =  @_;
  Zenlog::fail_unless_in_zenlog;

  $pid //= $ZENLOG_PID; #/

  my $log_dir = "$ZENLOG_DIR/pids/$pid/";
  -d $log_dir or return ();

  my $name = $raw ? "R" : "P";

  # Collect the files.
  my @files = ();

  if ($num >= 0) {
    @files = ($log_dir . $name x ($num + 1));
  } else {
    @files = reverse(glob("${log_dir}${name}*"));
  }

  my @ret = ();
  for my $file (@files) {
    my $target = readlink($file);
    push @ret, $target if defined $target;
  }
  return @ret;
}

#=====================================================================
# Logger.  This is the only part that runs in the background.
#=====================================================================

# RAW/SAN file handles.
my ($raw, $san);

# Return true if we're currently logging.
sub logging() {
  return defined $raw;
}

# Close current log.
sub close_log() {
  return unless logging;

  debug("Closing log.\n");

  $raw->close() if defined $raw;
  $san->close() if defined $san;
  undef $raw;
  undef $san;
}

sub open_log($) {
  my ($start_line) = @_;
  close_log();

  my ($san_name, $raw_name) = split(/\t/, $start_line);

  open($raw, ">>", $raw_name);
  open($san, ">>", $san_name);

  $raw->autoflush();
  $san->autoflush();
}

sub write_log($) {
  return unless logging;

  my ($line) = @_;
  $raw->print($line);
  $san->print(sanitize($line));
}

sub zen_logging($) {
  my ($reader) = @_;

  make_path($ZENLOG_DIR);
  print "Logging to '$ZENLOG_DIR'...\n";

  my $force_log_next = 0;

  while (defined(my $line = <$reader>)) {

    # Command line and output marker.
    if ($line =~ m! \Q$LOG_START_MARKER\E\t(.*) !xo) {
      my $start_line = $1;
      open_log($start_line);
      next;
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
  $ENV{ZENLOG_OUTER_TTY} = get_tty;
  export_vars();
}

sub start() {
  load_rc;
  export_env;

  File::Path::remove_tree("$ZENLOG_DIR/pids/$$/", {keep_root => 1});

  my ($reader_fd, $writer_fd) = POSIX::pipe();
  $reader_fd or die "$0: pipe() failed: $!\n";

  debug("Pipe opened: read=$reader_fd, write=$writer_fd\n");

  my $child_pid;
  if (($child_pid = fork()) == 0) {
    # Child
    POSIX::close($reader_fd);

    my $start_command = $ZENLOG_START_COMMAND;
    my @command = ("script",
        "-fqc",
        "export ZENLOG_TTY=\$(tty);"
        . "export ZENLOG_SHELL_PID=\$\$;"
        . "export ZENLOG_LOGGER_PIPE=/proc/\$\$/fd/$writer_fd;"
        . "exec $start_command",
        "/proc/self/fd/$writer_fd");
    debug("Starting: ", join(" ", map(shescape($_), @command)), "\n");
    if (!exec(@command)) {
      # kill 'INT', getppid;
      warn "$0: failed to start script: $!\n";
      warn "Starting /bin/sh instead.\n";
      exec("/bin/sh -l");
    }
  }
  # Parent
  POSIX::close($writer_fd);
  open(my $reader, "<&=", $reader_fd) or die "$0: fdopen failed: $!\n";

  # Now $reader is the log input.

  zen_logging($reader);
  close $reader;
  waitpid $child_pid, 0;
  return 1;
}

#=====================================================================
# Entry point
#=====================================================================
sub main(@) {
  my (@args) = @_;

  my $real_exe = Cwd::abs_path($0);
  my $exe_dir = dirname($real_exe);

  # If no arguments are provided, start new zenlog.
  if (@args == 0) {
    fail_if_in_zenlog;
    exit(start() == 0 ? 1 : 0);
  }

  # if the first argument is -h or --help, show the usage.
  if ($args[0] =~ m!^-h|--help$!) {
    usage;
    exit 0;
  }

  # Otherwise, start a subcommand.

  # Delegate to the subcommand.
  my $subcommand = shift @args;
  debug("Running subcommand: ", $subcommand, "\n");

  my $subcommand_us = $subcommand =~ s!-!_!gr; #!
  my $subcommand_hy = $subcommand =~ s!_!-!gr; #!
  # See if there's a function for that.
  if (exists $sub_commands{$subcommand_us}) {
    exit(&{$sub_commands{$subcommand_us}}(@args) ? 0 : 1);
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
      if (-x $c) {
        exec($c, @args) or exit 1;
      }
    }
  }

  die "zenlog: Unknown subcommand '$subcommand'.\n";
}

1;
