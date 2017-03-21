# Zenlog logger.

use strict;
use Time::HiRes qw(time);
use File::Path qw(make_path);
use File::Basename;

sub zen_logging($) {
  my ($reader) = @_;
  while (defined(my $line = <$reader>)) {
    print ">>> ", $line;
  }
  print "Logger finishing.\n";
}

1;
