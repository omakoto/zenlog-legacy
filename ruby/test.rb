#!/usr/bin/ruby2.1

DEBUG = true;

# f = File.open("/tmp/abc", "w");
# f.close_on_exec = false;
# f.write("test\n");
# system "ls", "-l", "/proc/self/fd";

reader, writer = IO.pipe;
writer.close_on_exec = false;  # STOPSHIP Figure out why it won't work.
printf "Reader=%d Writer=%d\n", reader, writer if DEBUG;
system "ls", "-l", "/proc/self/fd" if DEBUG;
writer.write "abc";
system "ls", "-l", "/proc/self/fd" if DEBUG;

fork do
  puts ">> In child." if DEBUG;
  exec "ls", "-l", "/proc/self/fd" if DEBUG;
  exit 0;
end
puts ">> In parent." if DEBUG;
writer.close

exit 0;
