#!/usr/bin/perl -w

# Zenlog log writer.

use strict;
use Time::HiRes qw(time);
use POSIX qw(strftime);
use File::Path qw(make_path);
use File::Basename;

my $zenlog_pid = $ENV{ZENLOG_PID};
my $log_dir = $ENV{ZENLOG_CUR_LOG_DIR};
my %always_iyayo = map {$_ => 1} split(/\s+/, $ENV{ZENLOG_ALWAYS_184});
my $command_prefix = $ENV{ZENLOG_COMMAND_PREFIX};

my ($raw, $san, $cur_raw_name, $cur_san_name);

my $run_test = -t STDIN;

sub close_log() {
  $raw->close() if defined $raw;
  $san->close() if defined $san;
  undef $raw;
  undef $san;
  undef $cur_raw_name;
  undef $cur_san_name;
}

sub logging() {
  return defined $cur_raw_name;
}

sub create_prev_links($$$) {
  my ($raw, $san, $link_dir) = @_;

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
  my ($dir, $name) = @_;

  return unless logging();

  # Normalzie.
  $name =~ s! \s+ $!!xg;
  $name =~ s! [ / \s ]+ !_!xg;

  # Avoid typical errors...
  return if $name =~ m!^ ( \. | \.\. ) $!x;

  my $t = time;

  my $command_dir = "$log_dir/$dir/$name/";
  my $raw_dir = sprintf('%s/RAW/%s/',
      $command_dir,
      strftime('%Y/%m/%d', localtime($t)));
  $raw_dir =~ s!/+!/!g;
  my $san_dir = $raw_dir =~ s!/RAW/!/SAN/!r; #!

  make_path($raw_dir);
  make_path($san_dir);

  my $raw_file = ($cur_raw_name =~ s!^.*/!!r); #!
  my $san_file = ($cur_san_name =~ s!^.*/!!r); #!

  symlink($cur_raw_name, "$raw_dir$raw_file");
  symlink($cur_san_name, "$san_dir$san_file");

  create_prev_links($cur_raw_name, $cur_san_name, $command_dir);
}

my $seq = 0;
sub open_log() {
  close_log();

  my $t = time;

  my $raw_name = sprintf('%s/RAW/%s.%03d-%05d-%04d.log',
      $log_dir,
      strftime('%Y/%m/%d/%H-%M-%S', localtime($t)),
      ($t - int($t)) * 1000, $zenlog_pid, $seq++);
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

  create_prev_links($cur_raw_name, $cur_san_name, $log_dir);
  create_links("pids", $zenlog_pid);
}

sub reopen() {
  close $raw;
  close $san;
  open($raw, ">$cur_raw_name");
  open($san, ">$cur_san_name");

  $raw->autoflush();
  $san->autoflush();
}

sub write_log($) {
  return unless defined $raw;

  my ($l) = @_;
  $raw->print($l);

  # Sanitize
  $l =~ s! (
        \a                         # Bell
        | \e \x5B .*? [\x40-\x7E]  # CSI
        | \e \x5D .*? \x07         # Set terminal title
        | \e \( .                  # 3 byte sequence
        | \e [\x40-\x5A\x5C\x5F]   # 2 byte sequence
        )
        !!gx;
  # Also clean up CR/LFs.
  $l =~ s! \s* \x0d* \x0a !\x0a!gx;       # Remove end-of-line CRs.
  $l =~ s! \s* \x0d !\x0a!gx;             # Replace orphan CRs with LFs.

  # Also replace ^H's.
  $l =~ s! \x08 !^H!gx;
  $san->print($l) if defined $san;
}

sub stop_log() {
  write_log("[retracted]\n");
  close_log();
}

sub extract_tag($) {
  my ($file) = @_;

  my $i = 0;
  my $next_char = sub {
    return undef if $i >= length($file);
    return substr($file, $i++, 1);
  };
  my $ch;

  outer:
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
          next outer;
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
          next outer;
        }
      }
      return "";
    }
  }
  return "";
}


if ($run_test) {
  print "Running tests...\n";
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

  exit 0;
}

sub main() {
  open_log();

  my $paused = 0;

  while (defined(my $line = <>)) {
    if ($paused) {
      if ($line =~ m! \e\[0m\e\[7m\e\[00000m !x) {
        $paused = 0;
      }
      next;
    }

    if ($line =~ m! \e\[0m\e\[6m\e\[00000m !x) {
      $paused = 1;
      next;
    }

    # Command line and output marker.
    if ($line =~ m! \e\[0m\e\[3m\e\[00000m (.*?) \e\[0m\e\[4m\e\[00000m !x) {
      my $command = $1;

      $command =~ s!^\s+!!;
      $command =~ s!\s+$!!;
      # write_log($line);

      reopen();
      write_log("\$ \e[1;3;4m$command\e[0m\n");

      for my $single_command ( split(/(?: \&\& | \|\|? | \; )/x, $command)) {
        $single_command =~ s!^ [ \s \( ]+ !!x; # Remove prefixing ('s.

        # Remove prefixes, such as "builtin" and "time".
        while ($single_command =~ s!^$command_prefix\s+!!o) {
        }

        my $exe = (split(/\s+/, $single_command, 2))[0];

        $exe =~ s!^ \\ !!x; # Remove first '\'.
        $exe =~ s!^ .*/ !!x; # Remove file path

        if (exists($always_iyayo{$exe})) {
          stop_log();
        } else {
          create_links("cmds", $exe);
        }
      }

      if (logging()) { # not iyayo?
        my $tag = extract_tag($command);
        create_links("tags", $tag) if $tag;
      }
      next;
    }

    if ($line =~ m! ^ (.*?)  \e\[0m\e\[1m\e\[00000m (.*) !x) {
      # separator

      my ($pre, $post) = ($1, $2);
      write_log($pre);

      open_log();

      write_log($post);

      next;
    }
    if ($line =~ m!^ (.*?) \e\[0m\e\[2m\e\[00000m !x) {
      # 184 marker
      my ($pre) = ($1);

      write_log($pre);
      stop_log();

      next;
    }

    write_log($line);
  }
  close_log()
}


main;
