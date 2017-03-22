#!/usr/bin/ruby2.1

DEBUG = true;

reader, writer = IO.pipe;
writer.close_on_exec = false;  # STOPSHIP Figure out why it won't work.
printf "Reader=%d Writer=%d\n", reader, writer if DEBUG;

child_pid = fork do
  puts ">> In child." if DEBUG;
  exec "ls", "-l", "/proc/self/fd", close_others: false;
  exit 0;
end
puts ">> In parent." if DEBUG;
writer.close

Process.waitpid child_pid
exit 0;
