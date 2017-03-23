#!/usr/bin/perl -w

use strict;
use Test::More;
use Cwd qw();
use File::Basename qw(dirname);
use lib (dirname(Cwd::abs_path($0)) . "/../");
use Zenlog;

my $tests = 0;

sub check_extract_tag($$) {
  my ($expected, $input) = @_;
  my $actual = Zenlog::extract_comment($input);
  is($actual, $expected, "extract_comment: '$input'");

  $tests++;
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

done_testing $tests;
