#!/usr/bin/env ruby
$VERBOSE = true

require 'fileutils'
require_relative 'shellhelper'

#-----------------------------------------------------------
# Constants.
#-----------------------------------------------------------

MY_REALPATH = File.realpath(__FILE__)

# If this file exists all zenlog commands will be no-op, and
# zenlog sessions won't start and instead always just runs the shell.
ZENLOG_KILL_SWITCH_FILE = '/tmp/zenlog_stop'
ZENLOG_KILL_SWITCH_VAR = 'STOP_ZENLOG'
ZENLOG_FORCE_DEBUG_FILE = '/tmp/zenlog_debug'

ZENLOG_PREFIX = 'ZENLOG_'
ZENLOG_ALWAYS_NO_LOG_COMMANDS = ZENLOG_PREFIX + 'ALWAYS_NO_LOG_COMMANDS'
ZENLOG_COMMAND_IN = ZENLOG_PREFIX + 'COMMAND_IN'
ZENLOG_DEBUG = ZENLOG_PREFIX + 'DEBUG'
ZENLOG_DIR = ZENLOG_PREFIX + 'DIR'
ZENLOG_LOGGER_OUT = ZENLOG_PREFIX + 'LOGGER_OUT'
ZENLOG_OUTER_TTY = ZENLOG_PREFIX + 'OUTER_TTY'
ZENLOG_PID = ZENLOG_PREFIX + 'PID'
ZENLOG_PREFIX_COMMANDS = ZENLOG_PREFIX + 'PREFIX_COMMANDS'
ZENLOG_SHELL_PID = ZENLOG_PREFIX + 'SHELL_PID'
ZENLOG_START_COMMAND = ZENLOG_PREFIX + 'START_COMMAND'
ZENLOG_TTY = ZENLOG_PREFIX + 'TTY'

ZENLOG_RC = ZENLOG_PREFIX + 'RC'

RC_FILE = ENV[ZENLOG_RC] || Dir.home() + '/.zenlogrc.rb'

DEBUG = (ENV[ZENLOG_DEBUG] == "1") || File.exist?(ZENLOG_FORCE_DEBUG_FILE)

#-----------------------------------------------------------
# Core functions.
#-----------------------------------------------------------

$is_logger = false # Used to change the debug log color.

module ZenCore
  def say(*args, &block)
    message = args.join('') + (block ? block.call() : '')
    message.gsub!(/\r*\n/, "\r\n") if $is_logger
    $stdout.print message
  end

  def debug(*args, &block)
    return false unless DEBUG

    say $is_logger ? "\e[0m\e[32m" : "\e[0m\e[31m"
    say args, &block
    say "\e[0m" # Reset
    return true
  end

  def die(message)
    say "zenlog: #{message}\n"
    exit 1
  end

  # Return the tty name for this process.
  def get_tty
    begin
      require 'ttyname'

      # If any of stdin/stdout/stderr has a ttyname, just use it.
      begin
        tty = ($stdin.ttyname or $stdout.ttyname or $stderr.ttyname)
        return tty if tty
      rescue RuntimeError
        # Fall through.
      end
    rescue LoadError
      # Ignore and use ps.
    end

    # Otherwise, just ask the ps command...
    pstty = %x(ps -o tty -p $$ --no-header 2>/dev/null).chomp
    tty = '/dev/' + pstty
    return File.exist?(tty) ? tty : nil
  end

  # Remove ANSI escape sequences from a string.
  def sanitize(str)
    str.gsub! %r!(
          \a                         # Bell
          | \e \x5B .*? [\x40-\x7E]  # CSI
          | \e \x5D .*? \x07         # Set terminal title
          | \e \( .                  # 3 byte sequence
          | \e [\x40-\x5A\x5C\x5F]   # 2 byte sequence
          )!x, ""

    # Also clean up CR/LFs.
    str.gsub!(%r! \s* \x0d* \x0a !x, "\n") # Remove end-of-line CRs.
    str.gsub!(%r! \s* \x0d !x, "\n")       # Replace orphan CRs with LFs.

    # Also replace ^H's.
    str.gsub!(%r! \x08 !x, '^H');
    return str;
  end

  # Convert a string into what's safe to use in a filename.
  def filename_safe(str)
    return "" if str == nil
    return str.gsub(/\s+/, " ") \
        .gsub(%r![\s\/\'\"\|\[\]\\\!\@\$\&\*\(\)\?\<\>\{\}]+!, "_")
  end

  def start_emergency_shell()
    ENV.delete_if {|k, v| k.start_with? ZENLOG_PREFIX}
    say "Starting bash instead...\n"
    exec "/bin/bash"
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

  CHILD_FINISHED_MARKER = COMMAND_MARKER + 'CHILD_FINISHED:'

  private
  def self.io_error_okay(&block)
    begin
      block.call()
    rescue SystemCallError => e
      say "zenlog: Error #{e}\n" if debug
    end
  end

  # Subcommand: zenlog in-zenlog
  public
  def self.in_zenlog
    tty = get_tty
    return (tty != nil) && (ENV[ZENLOG_TTY] == get_tty)
  end

  # Subcommand: zenlog fail-if-in-zenlog
  public
  def self.fail_if_in_zenlog
    die 'already in zenlog.' if in_zenlog
    return true
  end

  # Subcommand: fail-unless-in-zenlog
  public
  def self.fail_unless_in_zenlog
    die 'not in zenlog.' unless in_zenlog
    return true
  end

  private
  def self.with_logger(&block)
    ofile = ENV[ZENLOG_LOGGER_OUT]
    if File.writable?(ofile)
      open(ofile, "w", &block)
      return true
    else
      return false
    end
  end

  # Subcommand: zenlog start-command
  # Tell zenlog to start logging for a command line.
  private
  def self.start_command(*command_line_words)
    debug {"[Command start: #{command_line_words.join(" ")}]\n"}
    if in_zenlog
      io_error_okay do
        # Send "command start" to the logger directly.
        with_logger do |out|
          out.print(
              COMMAND_START_MARKER,
              command_line_words.join(" ").gsub(/\r*\n/, " "),
              "\n")
        end
      end
    end
    return true
  end

  # Subcommand: zenlog stop-log
  # Tell zenlog to stop logging the current command.
  private
  def self.stop_log
    debug "[Stop log]\n"
    if in_zenlog
      io_error_okay do
        # Send "stop log" to the logger directly.
        fingerprint = Time.now.to_f.to_s
        zenlog_working = with_logger do |out|
          out.print(STOP_LOG_MARKER, fingerprint, "\n")
        end
        if !zenlog_working
          return
        end

        # Wait for ack to make sure the log file was actually written.
        ack = get_stop_log_ack(fingerprint)
        ifile = ENV[ZENLOG_COMMAND_IN]
        File.readable?(ENV[ZENLOG_COMMAND_IN]) && open(ifile, "r") do |i|
          i.each_line do |line|
            if line == ack
              debug "[Ack received]\n"
              break
            end
          end
        end
      end
    end
  end

  # Subcommand:
  # Print the outer TTY device file.
  private
  def self.outer_tty
    if in_zenlog
      puts ENV[ZENLOG_OUTER_TTY]
      return true
    else
      return false
    end
  end

  # Subcommand:
  # Print the pipe filename to the logger
  private
  def self.logger_pipe
    if in_zenlog
      puts ENV[ZENLOG_LOGGER_OUT]
      return true
    else
      return false
    end
  end

  # Subcommand:
  # Eat from stdin and write to ZENLOG_OUTER_TTY
  private
  def self.write_to_outer
    return forward_stdin_to_file ENV[ZENLOG_OUTER_TTY], need_cr:true
  end

  # Subcommand:
  # Eat from stdin and write to ZENLOG_LOGGER_OUT
  private
  def self.write_to_logger
    return forward_stdin_to_file ENV[ZENLOG_LOGGER_OUT], need_cr:false
  end

  private
  def self.forward_stdin_to_file(file, need_cr:false)
    out = in_zenlog ? (open file, "w") : $stdout
    $stdin.each_line do |line|
      line.sub!(/\r*\n$/, "\r\n") if need_cr
      out.print line
    end
    return true
  end

  # Find substring in str, and return pre and post strings. (or nil)
  private
  def self.find_marker(str, substring)
    pos = str.index(substring)
    return nil unless pos
    return str[0, pos], str[pos + substring.length .. -1]
  end

  # Called by the logger to see if an incoming line is of a command start
  # marker, and if so, returns the command line.
  public
  def self.match_command_start(in_line)
    matched = find_marker(in_line, COMMAND_START_MARKER)
    return matched ? matched[1] : nil
  end

  # Called by the logger to see if an incoming line is of a stop log
  # marker, and if so, returns the last log line (everything before the marker,
  # in case the command last output line doesn't end with a NL) and a
  # fingerprint, which needs to be sent back with an ACK.
  public
  def self.match_stop_log(in_line)
    return find_marker(in_line, STOP_LOG_MARKER)
  end

  # Create an ACK marker with a fingerprint.
  public
  def self.get_stop_log_ack(stop_log_fingerprint)
    return STOP_LOG_ACK_MARKER + stop_log_fingerprint + "\n"
  end

  public
  def self.get_child_finished_marker()
    return CHILD_FINISHED_MARKER + "\n"
  end

  public
  def self.match_child_finished_marker(str)
    return str.include? CHILD_FINISHED_MARKER
  end

  # Subcommand
  private
  def self.ensure_log_dir
    log_dir = ENV[ZENLOG_DIR]
    if !log_dir
      die "#{ZENLOG_DIR} not set."
    end
    if !File.directory? log_dir
      die "#{log_dir} doesn't exist."
    end

    exit 0
  end

  # Subcommand helper.
  public
  def self.history(raw, pid, nth)
    dir = ENV[ZENLOG_DIR] + "/pids/" + pid.to_s
    debug {"Log dir: #{dir}\n"}
    exit false unless File.directory? dir
    name = raw ? "R" : "P"

    if nth >= 0
      files = [dir + "/" + name * (nth + 1)]
    else
      files = Pathname.glob(dir + "/" + name + "*") \
          .reject {|p| !p.symlink?} \
          .map {|x| x.to_s}.reverse
    end

    files.map {|f| File.readlink(f)}.map {|f| f.gsub(/\/+/, "/")}.sort.each {|f| puts f}

    return true
  end

  # Just runs the passed command with exec(), but when exec fails
  # it'll start the emergency shell instead.
  # We need this because "sh -c 'exec no-such-command; exec /bin/sh'"
  # doesn't work.
  private
  def self.exec_or_emergency_shell(*args)
    begin
      exec *args
    rescue
      say "zenlog: failed to start #{args.join(" ")}.\n"
      start_emergency_shell
    end
  end

  # Return a lambda that calls built-in command, or nil of the given
  # command doesn't exist.
  # We don't just use "respond_to?" to avoid leaking ruby functions.
  public
  def self.get_builtin_command(command)
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

    when "outer_tty"
      return ->(*args) {outer_tty}

    when "logger_pipe"
      return ->(*args) {logger_pipe}

    when "ensure_log_dir"
      return ->(*args) {ensure_log_dir}

    when "write_to_outer"
      return ->(*args) {write_to_outer}

    when "write_to_logger"
      return ->(*args) {write_to_logger}

    when "exec_or_emergency_shell"
      return ->(*args) {exec_or_emergency_shell(*args)}

    end

    return nil
  end
end

#-----------------------------------------------------------
# Sits in the background and writes log.
#-----------------------------------------------------------
class ZenLogger
  RAW = 'RAW'
  RAW_LINK = 'R'
  SAN = 'SAN'
  SAN_LINK = 'P'

  MAX_PREV_LINKS = 10

  public
  def initialize(log_dir, child_pid, logger_in, command_out)
    @log_dir = log_dir
    @pid = $$
    @child_pid = child_pid
    @logger_in = logger_in
    @command_out = command_out
    @prefix_commands = ENV[ZENLOG_PREFIX_COMMANDS] || \
        DEFAULT_ZENLOG_PREFIX_COMMANDS
    @always_no_log_commands = ENV[ZENLOG_ALWAYS_NO_LOG_COMMANDS] || \
        DEFAULT_ZENLOG_ALWAYS_NO_LOG_COMMANDS

    @prefix_commands_re = Regexp.compile('^' + @prefix_commands + '$')
    @always_no_log_commands_re = Regexp.compile('^' + @always_no_log_commands + '$')

    @san = nil
    @raw = nil
  end

  private
  def create_prev_links(full_dir_name, link_name, log_file_name)
    MAX_PREV_LINKS.downto(2) do |n|
      from = (full_dir_name + "/" + (link_name * (n - 1)))
      to   = full_dir_name + "/" + (link_name * n)
      FileUtils.mv(from, to, {force:true}) if File.exist? from
    end
    FileUtils.ln_s(log_file_name, full_dir_name + "/" + link_name)
  end

  private
  def create_links(parent_dir, dir, type, link_name, log_file_name, now)
    return if dir == "." || dir == ".."

    full_dir_name = (@log_dir + "/" + parent_dir + "/" + dir + "/" + type +
        "/" + now.strftime('%Y/%m/%d')).gsub(%r!/+!, "/")

    FileUtils.mkdir_p(full_dir_name)

    FileUtils.ln_s(log_file_name,
        full_dir_name + "/" + log_file_name.sub(/^.*\//, ""))

    create_prev_links(@log_dir + "/" + parent_dir + "/" + dir, link_name, log_file_name)
  end

  # Start logging for a command.
  # Open the raw/san streams, create symlinks, etc.
  def start_logging(command_line)
    tokens = shsplit(command_line)

    # All the executable command names in the command pipeline.
    command_names = []

    # Comment, which is used for tagging.
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

    open_log(command_line, command_names, comment, nolog_detected)
  end

  private
  def create_log_filename(command_line, tag, now)
    tag_str = "_+" + tag if tag.to_s != ""
    command_str = filename_safe(command_line)[0,32]

    return sprintf("%s/#{RAW}/%s-%05d%s_+%s.log",
        @log_dir,
        now.strftime('%Y/%m/%d/%H-%M-%S.%L'),
        @pid,
        tag_str,
        command_str).sub(%r(/+), "/") # compress consecutive /s.
  end

  private
  def open_logfile(filename)
    FileUtils.mkdir_p(File.dirname(filename))
    out = open(filename, "w")
    out.sync = true
    return out
  end

  private
  def open_log(command_line, command_names, comment, no_log)
    stop_logging()

    tag = filename_safe(comment)
    now = Time.now.getlocal

    raw_name = create_log_filename(command_line, tag, now)
    san_name = raw_name.gsub(/#{RAW}/o, SAN)

    @raw = open_logfile(raw_name)
    @san = open_logfile(san_name)

    [[raw_name, RAW, RAW_LINK], [san_name, SAN, SAN_LINK]].each do |log_name, type, link_name|
      create_prev_links(@log_dir, link_name, log_name)

      pid_s = @pid.to_s
      create_links("pids", pid_s, type, link_name, log_name, now)

      command_names.each do |command|
        create_links("cmds", command, type, link_name, log_name, now)
      end

      if tag
        create_links("tags", tag, type, link_name, log_name, now)
      end
    end

    write_log "\$ \e[1;3;4;33m#{command_line}\e[0m\n"
    if no_log
      write_log "[omitted]\n"
      stop_logging
      return
    end
  end

  private
  def write_log(line)
    @raw.print(line) if @raw
    @san.print(sanitize(line)) if @san
  end

  private
  def stop_logging()
    @raw.close if @raw
    @san.close if @san
    @raw = nil
    @san = nil
  end

  # This is called when
  private
  def on_child_finished()
    child_status = Process.waitpid2(@child_pid)[1].exitstatus

    clean_up()

    if child_status != 0
      say "\e[0m\e[31mZenlog: Child stopped with error status #{child_status}.\e[0m\n"
      start_emergency_shell
    end
  end

  private
  def clean_up
    stop_logging()
    @logger_in.close()
    @command_out.close()
  end

  # Main logger loop.
  public
  def main_loop
    begin
      in_command = false
      @logger_in.each_line do |line|
        # Command started? Then start logging.
        if !in_command
          command = BuiltIns.match_command_start(line)
          if command != nil
            debug {"Command started: \"#{command}\"\n"}

            in_command = true

            start_logging(command)
            next
          end
        end

        # Command stopped?
        last_line, fingerprint = BuiltIns.match_stop_log(line)
        if fingerprint
          if in_command
            debug {"Command finished: #{fingerprint}\n"}

            in_command = false

            write_log(last_line)

            stop_logging
          end
          # Note we always need to return ACK, even if not running a command.
          @command_out.print(BuiltIns.get_stop_log_ack(fingerprint))
          next
        end

        # Child process finished?
        if BuiltIns.match_child_finished_marker(line)
          on_child_finished
        end

        write_log line
      end
    rescue IOError => e
      say "zenlog: Error #{e}\n" if debug
    end
    clean_up()
  end
end

#-----------------------------------------------------------
# Start a new zenlog session.
#-----------------------------------------------------------
class ZenStarter
  public
  def initialize(rc_file:nil)
    @rc_file = rc_file
  end

  private
  def init_config()
    require_relative 'zenlog-defaults'

    if File.exist?(@rc_file) && !File.zero?(@rc_file)
      debug {"Loading #{@rc_file}...\n"}

      # Somehow "load" doesn't load from /dev/null? So we skip a 0 byte file.
      load @rc_file
    end

    @log_dir = ENV[ZENLOG_DIR] || DEFAULT_ZENLOG_DIR
    @start_command = ENV[ZENLOG_START_COMMAND] || DEFAULT_ZENLOG_START_COMMAND
  end

  private
  def export_env()
    ENV[ZENLOG_PID] = $$.to_s
    ENV[ZENLOG_DIR] = @log_dir
    ENV[ZENLOG_OUTER_TTY] = get_tty
  end

  FD_LOGGER_OUT = 62
  FD_COMMAND_IN = 63

  private
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

  # Start a new zenlog session.
  public
  def start_zenlog_session()
    BuiltIns.fail_if_in_zenlog

    init()

    if !Dir.exist? @log_dir
      say "zenlog: #{@log_dir} doesn't exist.\n"
      @log_dir
      start_emergency_shell
    end

    $stdout.flush
    $stderr.flush
    child_pid = Process.fork

    if child_pid == nil
      # Child, which runs the shell.
      debug {"Child: PID=#{$$}\n"}

      # Not we don't actually copy the FDs to the child...
      # we can just let the subprocesses write to the parent's
      # /proc/xxx/fd/yyy. But we copy them anyway because that seems
      # clean...
      logger_out_name = "/proc/#{$$}/fd/#{FD_LOGGER_OUT}"
      command_in_name = "/proc/#{$$}/fd/#{FD_COMMAND_IN}"

      # Note we can't use exec directly for start_command because
      # then we wouldn't be able to catch a failure.
      # Instead we use exec_or_emergency_shell.
      command = [
          "script",
          "-fqc",
          "#{ZENLOG_SHELL_PID}=#{$$} " +
          "#{ZENLOG_LOGGER_OUT}=#{shescape logger_out_name} " +
          "#{ZENLOG_COMMAND_IN}=#{shescape command_in_name} " +
          "#{ZENLOG_TTY}=$(tty) " +
          "exec '#{MY_REALPATH}' exec_or_emergency_shell " +
          "#{shescape_multi @start_command}",
          logger_out_name,
          FD_LOGGER_OUT => @logger_out,
          FD_COMMAND_IN => @command_in]
      debug {"Starting: #{command}\n"}
      exec(*command)
      exit 127
    else
      # Parent, which is the logger.
      $is_logger = true
      debug {"Parent\n"}
      @command_in.close()

      Signal.trap("CHLD") do
        @logger_out.print(BuiltIns.get_child_finished_marker)
        @logger_out.close()
      end

      ZenLogger.new(@log_dir, child_pid, @logger_in, @command_out).main_loop

      debug {"Logger process finishing...\n"}
      exit 0
    end
    return true
  end
end

#-----------------------------------------------------------
# Entry point.
#-----------------------------------------------------------
class Main
  def no_zenlog?()
    return File.exist?(ZENLOG_KILL_SWITCH_FILE) \
        || (ENV[ZENLOG_KILL_SWITCH_VAR] == "1")
  end

  def maybe_exec_builtin_command(command, args)
    builtin = BuiltIns.get_builtin_command command.gsub('-', '_')
    if builtin
      debug {"Running builtin: #{command} with args: #{args.inspect}\n"}
      exit(builtin.call(*args) ? 0 : 1)
    end
  end

  def maybe_exec_external_command(command, args)
    # Look for a "zenlog-subcommand" executable file, in the the zenlog
    # install directory, or the PATH directories.
    debug {"MY_REALPATH=#{MY_REALPATH}\n"}
    my_path = File.dirname(MY_REALPATH)

    ext_name = "zenlog-" + command.gsub('_', '-')

    [my_path, *((ENV['PATH'] || "").split(":"))].each do |dir|
      file = dir + "/" + ext_name
      if File.executable? file
        debug {"Found #{file}\n"}
        exec(file, *args)
      end
    end
  end

  # External entry point.
  def main(args)
    # Start a new zenlog session?
    if args.length == 0
      if no_zenlog?
        say "no-zenlog mode\n"
        start_emergency_shell
      end
      exit(ZenStarter.new(rc_file:RC_FILE).start_zenlog_session ? 0 : 1)
    end

    if no_zenlog?
      exit 0
    end
    # Otherwise, if there's more than one argument, run a subcommand.
    subcommand = args.shift

    maybe_exec_builtin_command subcommand, args

    maybe_exec_external_command subcommand, args

    die "subcommand '#{subcommand}' not found."
    exit 1
  end
end

if MY_REALPATH == File.realpath($0)
  Main.new.main(ARGV)
end
