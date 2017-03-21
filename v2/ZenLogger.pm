# Zenlog logger.

use strict;
use Time::HiRes qw(time);
use File::Path qw(make_path);
use File::Basename;

use Zenlog;

# Config.
my $LOG_DIR = get_var('log_dir');
my $PREFIX_COMMANDS = get_var('prefix_commands');
my $ALWAYS_184_COMMANDS = get_var('always_184_commands');

# raw/san filehandles and filenames.
my ($raw, $san, $cur_raw_name, $cur_san_name);

# Log sequence number.
my $log_seq_number = 0;

# Close current log.
sub close_log() {
  $raw->close() if defined $raw;
  $san->close() if defined $san;
  undef $raw;
  undef $san;
  undef $cur_raw_name;
  undef $cur_san_name;
}

# Return true if we're currently logging.
sub logging() {
  return defined $cur_raw_name;
}

# Create the P and R links to the current log files.
sub create_prev_links($) {
  my ($link_dir) = @_;

  return unless logging();

  $link_dir = "$LOG_DIR/$link_dir";

  for my $mark ( "R", "P" ) {
    my $num = 10;
    unlink("${link_dir}/" . ($mark x $num));
    while ($num >= 2) {
      rename("${link_dir}/" . ($mark x ($num-1)), "${link_dir}/" . ($mark x $num));
      $num--;
    }
  }

  symlink($raw, "${link_dir}/R");
  symlink($san, "${link_dir}/P");
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

  my $full_dir_name = "$parent_dir_name/$dir_name/";

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

  create_prev_links($cur_raw_name, $cur_san_name, $full_dir_name);
}

sub open_log() {
  close_log();

  my $t = time;

  my $raw_name = sprintf('%s/RAW/%s.%03d-%05d-%04d.log',
      $LOG_DIR,
      strftime('%Y/%m/%d/%H-%M-%S', localtime($t)),
      ($t - int($t)) * 1000, $$, $log_seq_number++);
  $raw_name =~ s!/+!/!g;
  my $san_name = $raw_name =~ s!/RAW/!/SAN/!r; #!

  make_path(dirname($raw_name));
  make_path(dirname($san_name));

  $cur_raw_name = $raw_name;
  $cur_san_name = $san_name;

  open($raw, ">$cur_raw_name");
  open($san, ">$cur_san_name");

  $raw->autoflush();
  $san->autoflush();

  # Create and update the P/R links, and also create
  # the pids/$$/ links.
  create_prev_links($cur_raw_name, $cur_san_name, $log_dir);
  create_links("pids", $zenlog_pid);
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

# Stop logging, used for "184".
sub stop_log() {
  write_log("[retracted]\n");
  close_log();
}

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

sub _test_extract_comment($) {
  sub check_extract_tag($$) {
    my ($expected, $input) = @_;
    my $actual = extract_tag($input);
    die "Expected '$expected' for '$input', but got '$actual'\n" unless $actual eq $expected;
  }
  check_extract_tag('', '');
  check_extract_tag('', 'abc');
  check_extract_tag('', 'abc def');
  check_extract_tag('XYZ DEF #AB', 'abc def #  XYZ DEF #AB');
  check_extract_tag('AB', 'abc def \\#  XYZ DEF #AB');
  check_extract_tag('XYZ DEF #AB', 'abc def \\\\#  XYZ DEF #AB');
  check_extract_tag('AB', "abc def ' # '  XYZ DEF #AB");
  check_extract_tag('AB', 'abc def " # "  XYZ DEF #AB');
  check_extract_tag('AB', 'abc def " \"# "  XYZ DEF #AB');
  check_extract_tag('AB', 'abc def " \"# "  XYZ DEF ""#AB');
  check_extract_tag('', 'abc def " \"# "  XYZ DEF ""\\#AB');
}












sub zen_logging($) {
  my ($reader) = @_;

  print "Logging to '$LOG_DIR'...\n";

  my $paused = 0;

  my $PROMPT_MARKER = PROMPT_MARKER;
  my $PAUSE_MARKER = PAUSE_MARKER;
  my $RESUME_MARKER = RESUME_MARKER;
  my $NO_LOG_MARKER = NO_LOG_MARKER;
  my $COMMAND_START_MARKER = COMMAND_START_MARKER;
  my $PREFIX_COMMANDS = get_var('prefix_commands');
  my $ALWAYS_184_COMMANDS = get_var('always_184_commands');

  my $no_log_next_command = 0;

  OUTER:
  while (defined(my $line = <$reader>)) {
    if ($paused) {
      # When pausing, just skip until the next resume marker.
      if ($line =~ m!$RESUME_MARKER!o) {
        $paused = 0;
      }
      next;
    }

    if ($line =~ m!$PAUSE_MARKER!o) {
      # Pause marker detected.
      $paused = 1;
      next;
    }

    if ($line =~ m! $NO_LOG_MARKER !xo) {
      # 184 marker, skip the next command.
      $no_log_next_command = 1;
      next;
    }

    # Command line and output marker.
    if ($line =~ m! $COMMAND_START_MARKER (.*?) $COMMAND_END_MARKER !xo) {
      my $command = $1;

      if ($no_log_next_command) {
        $no_log_next_command = 0;
        next OUTER;
      }

      $command =~ s!^\s+!!;
      $command =~ s!\s+$!!;

      # Split up the command by &&, ||, | and ;.
      # TODO: Actually tokenize the command line to avoid splitting in strings...
      for my $single_command ( split(/( \&\& | \|\|? | \; )/xn, $command)) {
        $single_command =~ s!^ [ \s \( ]+ !!x; # Remove prefixing ('s.

        # Remove prefix commands, such as "builtin" and "time".
        while ($single_command =~ s!^${PREFIX_COMMANDS}\s+!!on) { #!
        }

        # Get the first token, which is the command.
        my $exe = (split(/\s+/, $single_command, 2))[0];

        $exe =~ s!^ \\ !!x; # Remove first '\'.
        $exe =~ s!^ .*/ !!x; # Remove file path

        if ($exe =~ /^ALWAYS_184_COMMANDS$/o) {
          next OUTER:
        }
        if (!logging) {
          # Open the log, and write the command in italic-bold.
          open_log();
          write_log("\$ \e[1;3;4m$command\e\[0m\n");
        }
        create_links("cmds", $exe);
      }

      my $tag = extract_comment($command);
      create_links("tags", $tag) if $tag;

      next OUTER;
    }
    next unless logging;

    if ($line =~ m!^ (.*) $PROMPT_MARKER !xo) {
      # Prompt detected.
      my $rest = $1;
      write_log $rest if $1;
      next;
    }
    if ($line =~ m! \e\[0m\e\[4m\e\[00000m !xo) {
      # 184 marker
      my ($pre) = ($1);

      write_log($pre);
      stop_log();

      next;
    }
    write_log($line);
  }
  close_log();
  print "Logger finishing.\n" if DEBUG;
}

1;
