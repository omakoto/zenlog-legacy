#!/usr/bin/env ruby
$VERBOSE = true

require 'ttyname'
require 'pp'

ZENLOG_ALWAYS_184_COMMANDS = 'ZENLOG_ALWAYS_184_COMMANDS'
ZENLOG_COMMAND_OUT = 'ZENLOG_COMMAND_OUT'
ZENLOG_DEBUG = 'ZENLOG_DEBUG'
ZENLOG_DIR = 'ZENLOG_DIR'
ZENLOG_LOGGER_OUT = 'ZENLOG_LOGGER_OUT'
ZENLOG_OUTER_TTY = 'ZENLOG_OUTER_TTY'
ZENLOG_PID = 'ZENLOG_PID'
ZENLOG_PREFIX_COMMANDS = 'ZENLOG_PREFIX_COMMANDS'
ZENLOG_START_COMMAND = 'ZENLOG_START_COMMAND'
ZENLOG_TTY = 'ZENLOG_TTY'

DEBUG = true #ENV[ZENLOG_DEBUG] == "1"

#-----------------------------------------------------------
# Core functions.
#-----------------------------------------------------------
module ZenCore
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

  # Remove ansi escape sequences from a string.
  def sanitize(str)
    str.gsub! %r[(
          \a                         # Bell
          | \e \x5B .*? [\x40-\x7E]  # CSI
          | \e \x5D .*? \x07         # Set terminal title
          | \e \( .                  # 3 byte sequence
          | \e [\x40-\x5A\x5C\x5F]   # 2 byte sequence
          )]x

    # Also clean up CR/LFs.
    str.gsub!(%r[ \s* \x0d* \x0a ]x, "\n") # Remove end-of-line CRs.
    str.gsub!(%r[ \s* \x0d ]x, "\n")       # Replace orphan CRs with LFs.

    # Also replace ^H's.
    str.gsub!(%r[ \x08 ]x, "^H");
    return str;
  end

end

include ZenCore

module ShellUtils
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

  # Split into words like shell.
  # (doesn't support ${...}, etc.)
  def shsplit(arg)
    ret = []
    current = ""
    arg.scan(%r[
        (?:
        \s+                      # Whitespace
        | \' [^\']* \'?          # Single quote
        | \$\'(?:                # C-like string
            \\[\"\'\\abeEfnrtv]      # Special character
            | \\c.                   # Control character
            | \\x[0-9a-fA-F]{0,2}
            | \\u[0-9a-fA-F]{0,4}
            | \\U[0-9a-fA-F]{0,8}
            | [^\']
            )* \'?
        | \" (?: \\. | [^\"] )* \"? # Double-quote
        | .
        )
        ]x).each do |token|
      if token =~ /^\s/
        (ret << current) if current != ""
        current = ""
      else
        current += token
      end
    end
    (ret << current) if current != ""
    return ret
  end
end

include ShellUtils

#-----------------------------------------------------------
# Zenlog built-in commands.
#-----------------------------------------------------------
module BuiltIns
  def in_zenlog
    tty = get_tty
    return (tty != nil) && (ENV[ZENLOG_TTY] == get_tty)
  end

  def fail_if_in_zenlog
    die "already in zenlog." if in_zenlog
    return true
  end

  def fail_unless_in_zenlog
    die "not in zenlog." unless in_zenlog
    return true
  end

  # Read from STDIN, and write to path, if in-zenlog.
  # Otherwise just write to STDOUT.
  def pipe_stdin_to_file(path, cr_needed)
    out = $stdout
    if in_zenlog
      out = open(path, "w") # TODO Error handling
    else
      cr_needed = false
    end

    $stdin.each_line do |line|
      line.chomp!
      $out.print(line, cr_needed ? "\r\n" : "\n")
    end
    return true
  end

  # Return a lambda that calls built-in command, or nil of the given
  # command doesn't exist.
  # We don't just use "respond_to?" to avoid leaking ruby functions.
  def get_builtin_command(command)
    case command
    when "in_zenlog"
      return ->(*args){in_zenlog}
    when "fail_if_in_zenlog"
      return ->(*args){fail_if_in_zenlog}
    when "fail_unless_in_zenlog"
      return ->(*args){fail_unless_in_zenlog}
    when "outer_tty"
      return ->(*args) {
        if in_zenlog
          puts ENV[ZENLOG_OUTER_TTY]
          return true
        else
          return false
        end
      }
    end
    return nil
  end
end

include BuiltIns

class ZenLogger
  def initialize(rc_file:nil)
    @rc_file = rc_file
  end

  def init_config()
    require_relative 'zenlog-defaults'

    if File.exist? @rc_file
      debug {"Loading #{@rc_file}...\n"}
      load @rc_file
    end

    @log_dir = ENV[ZENLOG_DIR] || DEFAULT_ZENLOG_DIR
    @start_command = ENV[ZENLOG_START_COMMAND] || DEFAULT_ZENLOG_START_COMMAND
    @prefix_commands = ENV[ZENLOG_PREFIX_COMMANDS] || \
        DEFAULT_ZENLOG_PREFIX_COMMANDS
    @always184commands = ENV[ZENLOG_ALWAYS_184_COMMANDS] || \
        DEFAULT_ZENLOG_ALWAYS_184_COMMANDS

    @prefix_commands_re = Regexp.compile('^' + @prefix_commands + '$')
    @always184commands_re = Regexp.compile('^' + @always184commands + '$')
  end

  def export_env()
    ENV[ZENLOG_PID] = $$.to_s
    ENV[ZENLOG_DIR] = @log_dir
    ENV[ZENLOG_OUTER_TTY] = get_tty
    ENV[ZENLOG_COMMAND_OUT] = "/proc/#{$$}/fd/#{@command_out.to_i}"
    ENV[ZENLOG_LOGGER_OUT] = "/proc/#{$$}/fd/#{@logger_out.to_i}"
  end

  FD_LOGGER_OUT = 62

  def init()
    init_config

    @logger_in, @logger_out = IO.pipe
    @command_in, @command_out = IO.pipe

    export_env

    $stdout.puts "Zenlog starting... [ZENLOG_PID=#{$$}, ZENLOG_DIR=#{@log_dir}]"

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

class Main
  def help()
    print <<~'EOF'

        Zenlog: log all command output

        EOF
  end

  def maybe_exec_builtin_command(command, args)
    builtin = BuiltIns.get_builtin_command command.gsub('-', '_')
    if builtin
      exit builtin.call(*args) ? 0 : 1
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
      exit ZenLogger.new(rc_file:"#{Dir.home()}/.zenlogrc.rb").start ? 0 : 1
    end

    # Run a subcommand.
    subcommand = args.shift

    # Builtin command?
    maybe_exec_builtin_command subcommand, args

    # External command?
    maybe_exec_external_command subcommand, args

    die "subcommand '#{subcommand}' not found."
    exit 1
  end
end

Main.new.main(ARGV)
