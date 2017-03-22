#!/usr/bin/perl -w

use strict;

BEGIN {
  require ($0 =~ s!/[^/]+$!!r) . "/../Zenlog.pm"; #!
}

sub test_extract_comment() {
  sub check_extract_tag($$) {
    my ($expected, $input) = @_;
    my $actual = Zenlog::extract_comment($input);
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

test_extract_comment();
