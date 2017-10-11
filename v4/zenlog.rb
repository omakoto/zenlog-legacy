#!/usr/bin/env ruby
$VERBOSE = true

require 'ttyname'
require 'pp'
require_relative 'shellhelper'

ZENLOG_PREFIX = 'ZENLOG4'
ZENLOG_ALWAYS_NO_LOG_COMMANDS = ZENLOG_PREFIX + '_ALWAYS_NO_LOG_COMMANDS'
ZENLOG_COMMAND_IN = ZENLOG_PREFIX + '_COMMAND_IN'
ZENLOG_DEBUG = ZENLOG_PREFIX + '_DEBUG'
ZENLOG_DIR = ZENLOG_PREFIX + '_DIR'
ZENLOG_LOGGER_OUT = ZENLOG_PREFIX + '_LOGGER_OUT'
ZENLOG_OUTER_TTY = ZENLOG_PREFIX + '_OUTER_TTY'
ZENLOG_PID = ZENLOG_PREFIX + '_PID'
ZENLOG_PREFIX_COMMANDS = ZENLOG_PREFIX + '_PREFIX_COMMANDS'
ZENLOG_SHELL_PID = ZENLOG_PREFIX + '_SHELL_PID'
ZENLOG_START_COMMAND = ZENLOG_PREFIX + '_START_COMMAND'
ZENLOG_TTY = ZENLOG_PREFIX + '_TTY'

ZENLOG_RC = ZENLOG_PREFIX + '_RC'

RC_FILE = ENV[ZENLOG_RC] || Dir.home() + '/.zenlogrc.rb'

DEBUG = true #ENV[ZENLOG_DEBUG] == "1"

#-----------------------------------------------------------
# Core functions.
#-----------------------------------------------------------

$is_logger = false # Just to change the debug log color...

module ZenCore
  def say(*args, &block)
    message = args.join('') + (block ? block.call() : '')
    $stdout.print message.gsub(/\r*\n/, "\r\n") # Replace LFs with CRLFs # TODO Do it conditionally
  end

  def debug(*args, &block)
    return false unless DEBUG

    say $is_logger ? "\x1b[0m\x1b[32m" : "\x1b[0m\x1b[31m"
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
    tty = '/dev/' + pstty
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
    str.gsub!(%r[ \x08 ]x, '^H');
    return str;
  end

end

include ZenCore

#-----------------------------------------------------------
# Zenlog built-in commands.
#-----------------------------------------------------------
module BuiltIns
  COMMAND_MARKER = "\x01\x09\x07\x03\x02\x05zenlog:"
  COMMAND_START_MARKER = COMMAND_MARKER + 'START_COMMAND:'
  STOP_LOG_MARKER = COMMAND_MARKER + 'STOP_LOG:'
  STOP_LOG_ACK_MARKER = COMMAND_MARKER + 'STOP_LOG_ACK:'

  def in_zenlog
    tty = get_tty
    return (tty != nil) && (ENV[ZENLOG_TTY] == get_tty)
  end

  def fail_if_in_zenlog
    die 'already in zenlog.' if in_zenlog
    return true
  end

  def fail_unless_in_zenlog
    die 'not in zenlog.' unless in_zenlog
    return true
  end

  # Tell zenlog to start logging for a command line.
  def start_command(*command_line_words)
    debug {"[Command start: #{command_line_words.join(" ")}]\n"}

    if in_zenlog
      # Send "command start" to the logger directly.
      open ENV[ZENLOG_LOGGER_OUT], "w" do |out|
        out.print(
            COMMAND_START_MARKER,
            command_line_words.join(" ").gsub(/\r*\n/, " "),
            "\n")
      end
    end
    return true
  end

  # Tell zenlog to stop logging the current command.
  def stop_log
    debug "[Stop log]\n"
    if in_zenlog
      # Send "stop log" to the logger directly.
      fingerprint = Time.now.to_f.to_s
      open ENV[ZENLOG_LOGGER_OUT], "w" do |out|
        out.print(STOP_LOG_MARKER, fingerprint, "\n")
      end

      # Wait for ack to make sure the log file was actually written.
      ack = get_stop_log_ack(fingerprint)
      open ENV[ZENLOG_COMMAND_IN], "r" do |i|
        i.each_line do |line|
          if line == ack
            debug "[Ack received]\n"
            break
          end
        end
      end
    end
  end

  # Print the outer TTY device file.
  def outer_tty
    if in_zenlog
      puts ENV[ZENLOG_OUTER_TTY]
      return true
    else
      return false
    end
  end

  def write_to_outer
    pipe_stdin_to_file ENV[ZENLOG_OUTER_TTY], cr_needed:false
  end

  # Called by the logger to see if an incoming line is of a command start
  # marker, and if so, returns the command line.
  def match_command_start(in_line)
    if (in_line =~ /#{Regexp.quote COMMAND_START_MARKER}(.*)/o)
      return $1
    else
      return nil
    end
  end

  # Called by the logger to see if an incoming line is of a stop log
  # marker, and if so, returns the last log line (everything before the marker,
  # in case the command last output line doesn't end with a NL) and a
  # fingerprint, which needs to be sent back with an ACK.
  def match_stop_log(in_line)
    if (in_line =~ /(.*?)#{Regexp.quote STOP_LOG_MARKER}(.*)/o)
      return $1, $2
    else
      return nil
    end
  end

  # Create an ACK marker with a fingerprint.
  def get_stop_log_ack(stop_log_fingerprint)
    return STOP_LOG_ACK_MARKER + stop_log_fingerprint + "\n"
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

    newline = cr_needed ? "\r\n" : "\n"
    $stdin.each_line do |line|
      line.chomp!
      out.print(line, newline)
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

    when "start_command"
      return ->(*args){start_command args}

    when "stop_log"
      return ->(*args){stop_log}

    when "stop_log"
      return ->(*args){stop_log}

    when "outer_tty"
      return ->(*args) {outer_tty}

    when "write_to_outer"
      return ->(*args) {write_to_outer}
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
    @always_no_log_commands = ENV[ZENLOG_ALWAYS_NO_LOG_COMMANDS] || \
        DEFAULT_ZENLOG_ALWAYS_NO_LOG_COMMANDS

    @prefix_commands_re = Regexp.compile('^' + @prefix_commands + '$')
    @always_no_log_commands_re = Regexp.compile('^' + @always_no_log_commands + '$')
  end

  def export_env()
    ENV[ZENLOG_PID] = $$.to_s
    ENV[ZENLOG_DIR] = @log_dir
    ENV[ZENLOG_OUTER_TTY] = get_tty
  end

  FD_LOGGER_OUT = 62
  FD_COMMAND_IN = 63

  def init()
    init_config

    @logger_in, @logger_out = IO.pipe
    @command_in, @command_out = IO.pipe

    export_env

    $stdout.puts "Zenlog starting... [ZENLOG_PID=#{$$}, ZENLOG_DIR=#{@log_dir}]"

    debug{"Pipe1: [#{@logger_out.inspect}] -> [#{@logger_in.inspect}]\n"}
    debug{"Pipe2: [#{@command_out.inspect}] -> [#{@command_in.inspect}]\n"}

    # spawn("ls", "-l", "/proc/#{$$}/fd") if debug
  end

  def start()
    init()

    $stdout.flush
    $stderr.flush
    pid = Process.fork

    if pid == nil
      # Child
      debug {"Child: PID=#{$$}\n"}

      logger_out_name = "/proc/#{$$}/fd/#{FD_LOGGER_OUT}"
      command_in_name = "/proc/#{$$}/fd/#{FD_COMMAND_IN}"

      command = [
          "script",
          "-fqc",
          "export #{ZENLOG_SHELL_PID}=#{$$};" +
          "export #{ZENLOG_LOGGER_OUT}=#{shescape logger_out_name};" +
          "export #{ZENLOG_COMMAND_IN}=#{shescape command_in_name};" +
          "export #{ZENLOG_TTY}=$(tty);" +
          "exec #{@start_command}", # TODO Shescape?
          logger_out_name,
          FD_LOGGER_OUT=>@logger_out,
          FD_COMMAND_IN=>@command_in]
      debug {"Starting: #{command}\n"}
      exec *command

      say "Failed to execute #{@start_command}: Starting bash...\n"
      exec "/bin/bash"
      exit 127
    else
      # Parent
      $is_logger = true
      debug {"Parent\n"}
      @logger_out.close()
      @command_in.close()

      Signal.trap("CHLD") do
        @logger_in.close()
        @command_out.close()
      end

      logger_main_loop

      debug {"Logger process finishing...\n"}
      exit 0
    end
    return true
  end

  # Start logging for a command.
  # Open the raw/san streams, create symlinks, etc.
  def start_logging(command_line)
    tokens = shsplit(command_line)

    command_names = []
    comment = nil

    nolog_detected = false

    if tokens.length > 0
      # If the last token starts with "#", it's a comment.
      last = tokens[-1]
      if last =~ /^\#/
        # Compress consecutive spaces into one.
        comment = last.sub(/^#\s*/, '').sub(/\s\s+/, " ")
      end

      command_start = true
      tokens.each do |token|
        # Extract the first token as a command name.
        if command_start && !is_shell_op(token) && token !~ @prefix_commands_re
          command_names << token
          command_start = false

          nolog_detected = true if token =~ @always_no_log_commands_re
        end

        command_start |= (token =~ /^(?: \| | \|\| | \&\& | \; )$/x)
      end
      debug {"Commands=#{command_names.inspect}#{nolog_detected ? " *nolog" : ""}" +
          ", comment=#{comment}\n"}
    end
  end

  def stop_logging()
  end

  def logger_main_loop
    @logger_in.each_line do |line|
      command = BuiltIns.match_command_start(line)
      if command != nil
        debug {"Command started: \"#{command}\"\n"}

        start_logging(command)
        next
      end

      last_line, fingerprint = BuiltIns.match_stop_log(line)
      if fingerprint
        debug {"Command finished: #{fingerprint}\n"}

        stop_logging
        @command_out.print(BuiltIns.get_stop_log_ack(fingerprint))
        next
      end
    end
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
      exit ZenLogger.new(rc_file:RC_FILE).start ? 0 : 1
    end

    # Otherwise, if there's more than one argument, run a subcommand.
    subcommand = args.shift

    maybe_exec_builtin_command subcommand, args

    maybe_exec_external_command subcommand, args

    die "subcommand '#{subcommand}' not found."
    exit 1
  end
end

Main.new.main(ARGV)
