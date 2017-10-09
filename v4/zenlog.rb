#!/usr/bin/env ruby
$VERBOSE = true

require 'ttyname'
require 'pp'

DEBUG = true #ENV['ZENLOG_DEBUG'] == "1"

RC_FILE = "#{Dir.home()}/.zenlogrc.rb"

def say(*args, &block)
  message = args.join("") + (block ? block.call() : "")
  $stdout.print message.gsub(/\r*\n/, "\r\n") # Replace LFs with CRLFs # TODO Do it conditionally
end

def debug(*args, &block)
  return false unless DEBUG

  say "\x1b[0m\x1b[31m" # Red
  say args, &block
  say "\x1b[0m" # Reset
  return true
end

def die(message)
  say "zenlog: #{message}\n"
  exit 1
end

def help()
  print <<~'EOF'

      Zenlog: log all command output

      EOF
end

# Return the tty name for this process.
def get_tty
  # If any of stdin/stdout/stderr has a ttyname, just use it.
  begin
    tty = ($stdin.ttyname or $stdout.ttyname or $stderr.ttyname)
    return tty if tty
  rescue RuntimeError
  end

  # Otherwise, just ask the ps command...
  pstty = %x(ps -o tty -p $$ --no-header 2>/dev/null)
  pstty.chomp!
  tty = "/dev/" + pstty
  return File.exist?(tty) ? tty : nil
end

#-----------------------------------------------------------
# Shell-escape a single token.
#-----------------------------------------------------------
def shescape(arg)
  if arg =~ /[^a-zA-Z0-9\-\.\_\/\:\+\@]/
      return "'" + arg.gsub(/'/, "'\\\\''") + "'"
  else
      return arg;
  end
end

#-----------------------------------------------------------
# Shell-unescape a single token.
#-----------------------------------------------------------
def unshescape(arg)
  if arg !~ /[\'\"\\]/
    return arg
  end

  ret = ""
  pos = 0
  while pos < arg.length
    ch = arg[pos]

    case
    when ch == "'"
      pos += 1
      while pos < arg.length
        ch = arg[pos]
        pos += 1
        if ch == "'"
          break
        end
        ret += ch
      end
    when ch == '"'
      pos += 1
      while pos < arg.length
        ch = arg[pos]
        pos += 1
        if ch == '"'
          break
        elsif ch == '\\'
          if pos < arg.length
           ret += arg[pos]
          end
          pos += 1
        end
        ret += ch
      end
    when ch == '\\'
      pos += 1
      if pos < arg.length
        ret += arg[pos]
        pos += 1
      end
    when (ch == '$') && (arg[pos+1] == "'") # C-like string
      pos += 2
      ret, pos = _unescape_clike(arg, ret, pos)
    else
      ret += ch
      pos += 1
    end
  end

  return ret
end

def _unescape_clike(arg, ret, pos)
  while pos < arg.length
    ch = arg[pos]
    pos += 1
    case ch
    when "'"
      break
    when "\\"
      ch = arg[pos]
      pos += 1
      case
      when ch == '"';    ret += '"'
      when ch == "'";    ret += "'"
      when ch == '\\';   ret += '\\'
      when ch == 'a';    ret += "\a"
      when ch == 'b';    ret += "\b"
      when ch == 'e';    ret += "\e"
      when ch == 'E';    ret += "\e"
      when ch == 'f';    ret += "\f"
      when ch == 'n';    ret += "\n"
      when ch == 'r';    ret += "\r"
      when ch == 't';    ret += "\t"
      when ch == 'v';    ret += "\v"
      when ch == 'c'
        ch2 = arg[pos]&.downcase&.ord
        pos += 1
        code = ch2 ? (ch2 - 'a'.ord + 1) : 0
        ret << code.chr
      when (ch == 'x') && /\G([0-9a-fA-F]{1,2})/.match(arg, pos)
        code = $1
        pos += $1.length
        ret << code.to_i(16).chr("utf-8")
      when (ch == 'u') && /\G([0-9a-fA-F]{1,4})/.match(arg, pos)
        code = $1
        pos += $1.length
        ret << code.to_i(16).chr("utf-8")
      when (ch == 'U') && /\G([0-9a-fA-F]{1,8})/.match(arg, pos)
        code = $1
        pos += $1.length
        ret << code.to_i(16).chr("utf-8")
      when /\G([0-7]{1,3})/.match(arg, pos - 1)
        code = $1
        pos += $1.length - 1
        ret << code.to_i(8).chr("utf-8")
      else
        ret << "\\"
        ret << ch
      end
    else
      ret << ch
    end
  end
  return [ret, pos]
end

# Zenlog fundamentals.
def in_zenlog
  tty = get_tty
  return (tty != nil) && (ENV['ZENLOG_TTY'] == get_tty)
end

def fail_if_in_zenlog
  die "already in zenlog." if in_zenlog
  return true
end

def fail_unless_in_zenlog
  die "not in zenlog." unless in_zenlog
  return true
end

class ZenLogger
  def initialize(rc_file:nil)
    @rc_file = rc_file
  end

  def init_config()
    if File.exist? @rc_file
      debug {"Loading #{@rc_file}...\n"}
      load @rc_file
    end

    @log_dir = ENV['ZENLOG_DIR'] || Dir.home() + "/zenlog"
    @start_command = ENV['ZENLOG_START_COMMAND'] || "#{ENV['SHELL']} -l"
    @prefix_commands = ENV['ZENLOG_PREFIX_COMMANDS'] || "(?:command|builtin|time|sudo)"
    @always184commands = ENV['ZENLOG_ALWAYS_184_COMMANDS'] \
        || "(?:vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)"
  end

  def export_env()
    ENV['ZENLOG_PID'] = $$.to_s
    ENV['ZENLOG_DIR'] = @log_dir
    ENV['ZENLOG_OUTER_TTY'] = get_tty
    ENV['ZENLOG_COMMAND_OUT'] = "/proc/#{$$}/fd/#{@command_out.to_i}"
    ENV['ZENLOG_LOGGER_OUT'] = "/proc/#{$$}/fd/#{@logger_out.to_i}"
  end

  FD_LOGGER_OUT = 62

  def init()
    init_config

    @logger_in, @logger_out = IO.pipe
    @command_in, @command_out = IO.pipe

    export_env

    $stdout.puts "Starting zenlog [pid=#{$$}]: log directory=#{@log_dir}"

    debug{"Pipe1: [#{@logger_out.inspect}] -> [#{@logger_in.inspect}]\n"}
    debug{"Pipe2: [#{@command_out.inspect}] -> [#{@command_in.inspect}]\n"}

    spawn("ls", "-l", "/proc/#{$$}/fd") if debug
  end

  def start()
    init()

    $stdout.flush
    $stderr.flush
    pid = Process.fork

    if pid == nil
      # Child
      debug {"Child\n"}
      command = [
          "script",
          "-fqc",
          "export ZENLOG_SHELL_PID=#{$$};" +
          "export ZENLOG_TTY=$(tty);" +
          "exec #{@start_command}", # TODO Shescape?
          "/proc/self/fd/#{FD_LOGGER_OUT}", FD_LOGGER_OUT=>@logger_out]

      debug {"Starting: #{command}"}
      exec *command

      say "Failed to execute #{@start_command}: Starting bash...\n"
      exec "/bin/bash"
      exit 127
    else
      # Parent
      debug {"Parent\n"}
      @logger_out.close()

      Signal.trap("CHLD") do
        debug {"Received SIGCHLD\n"}
        @logger_in.close()
        @command_in.close()
        @command_out.close()
      end

      @logger_in.each_line do |line|
      end
      exit 0
    end
    return true
  end
end

module SubCommands
  def self.command_in_zenlog(*args)
    return in_zenlog
  end

  def self.command_fail_if_in_zenlog(*args)
    return fail_if_in_zenlog
  end

  def self.command_fail_unless_in_zenlog(*args)
    return fail_unless_in_zenlog
  end
end

class Main
  def maybe_exec_internal_command(command, args)
    int_name = "command_" + command.gsub('-', '_')

    if SubCommands.respond_to? int_name
      exit SubCommands.send(int_name, *args) ? 0 : 1
    end
  end

  def maybe_exec_external_command(command, args)
    # Look for a "zenlog-subcommand" executable file, in the the zenlog
    # install directory, or the PATH directories.
    my_file = __FILE__
    my_file = File.symlink?(my_file) ? File.readlink(my_file) : my_file
    debug {"my_file=#{my_file}\n"}
    my_path = File.dirname(my_file)

    ext_name = "zenlog-" + command.gsub('_', '-')

    [my_path, *(ENV['PATH'].split(":"))].each do |dir|
      file = dir + "/" + ext_name
      if File.executable? file
        debug {"Found #{file}\n"}
        exec file, *args
      end
    end
  end

  def main(args)
    # Help?
    if args[0] =~ /^(-h|--help)$/
      help
      exit 0
    end

    # Start a new zenlog session?
    if args.length == 0
      fail_if_in_zenlog
      exit ZenLogger.new(rc_file:RC_FILE).start ? 0 : 1
    end

    # Run a subcommand.
    subcommand = args.shift

    # Internal command?
    maybe_exec_internal_command subcommand, args

    # External command?
    maybe_exec_external_command subcommand, args

    die "subcommand '#{subcommand}' not found."
    exit 1
  end
end

Main.new.main(ARGV)
