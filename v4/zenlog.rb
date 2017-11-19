#!/usr/bin/env ruby
$VERBOSE = true

# Crash detection and fallback.
BEGIN {
  MY_REALPATH = File.realpath(__FILE__)
  STARTED_AS_SCRIPT = MY_REALPATH == File.realpath($0)

  # If invoked with no arguments, that's a new session start request.
  # In this case, detect an unexpected process termination, and
  # start /bin/sh instead.
  if STARTED_AS_SCRIPT && ARGV.length == 0
    # Do it only when requested to start a new session.
    at_exit do
      error = $!
      if error.nil? || error.is_a?(SystemExit) && error.success?
        # Success, just finish.
      else
        # Logger failed unexpectedly.
        $stderr.puts "zenlog: #{error}\r"
        error.backtrace_locations.each do |frame|
          $stderr.print "    ", frame, "\r\n"
        end
        $stderr.puts "zenlog: Unable to start a new session. " +
            "Starting bash instead.\r"
        exec "/bin/sh"
      end
    end
  end
}

require 'fileutils'
require 'io/wait'
require 'timeout'
require_relative 'shellhelper'

#-----------------------------------------------------------
# Constants.
#-----------------------------------------------------------

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
ZENLOG_AUTO_SYNC = ZENLOG_PREFIX + 'AUTO_SYNC'

ZENLOG_RC = ZENLOG_PREFIX + 'RC'

RC_FILE = ENV[ZENLOG_RC] || Dir.home() + '/.zenlogrc.rb'

DEBUG = (ENV[ZENLOG_DEBUG] == "1") || File.exist?(ZENLOG_FORCE_DEBUG_FILE)

AUTOSYNC_LOG = ENV[ZENLOG_AUTO_SYNC] != "0"

# Variables that are used for testing to inject
TIMEFILE = ENV['_ZENLOG_TIME_INJECTION_FILE']
ZENLOG_LOGGER_PID = '_ZENLOG_LOGGER_PID'

#-----------------------------------------------------------
# Core functions.
#-----------------------------------------------------------

$is_logger = false # Used to change the debug log color.

$cached_tty = nil

module ZenCore
  def say(*args, &block)
    message = args.join('') + (block ? block.call() : '')
    message.gsub!(/\r*\n/, "\r\n") if $is_logger
    $stderr.print message
  end

  def debug(*args, &block)
    return false unless DEBUG

    say $is_logger ? "\e[0m\e[32m" : "\e[0m\e[31m"
    say args, &block
    say "\e[0m" # Reset
    return true
  end

  def die(message, exit_status:1)
    say "zenlog: #{message}\n"
    exit exit_status
  end

  def get_tty_link(file)
    begin
      target = File.readlink(file)
      return target if target =~ /^\/dev\/(?:tty|pts)/
    rescue SystemCallError
    end
    return nil
  end

  def get_tty_from_ps()
    pstty = %x(ps -o tty= -p $$ 2>/dev/null).chomp
    tty = '/dev/' + pstty
    return File.writable?(tty) ? tty : nil
  end

  def get_tty_from_command()
    tty = %x(tty 2>/dev/null).chomp
    return File.writable?(tty) ? tty : nil
  end

  # Return the tty name for this process.
  def get_tty
    return $cached_tty if $cached_tty
    $cached_tty =  get_tty_link("/proc/self/fd/0") \
        or get_tty_link("/proc/self/fd/1") \
        or get_tty_link("/proc/self/fd/2") \
        or get_tty_from_command \
        or get_tty_from_ps()
    return $cached_tty
  end

  # Remove ANSI escape sequences from a string.
  def sanitize(str)
    str.encode!('UTF-8', 'UTF-8', :invalid => :replace)
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
        .gsub(%r![\s\/\'\"\|\[\]\\\!\@\$\&\*\(\)\?\<\>\{\}\;]+!, "_")
  end

  def start_emergency_shell()
    ENV.delete_if {|k, v| k.start_with? ZENLOG_PREFIX}
    say "Starting /bin/sh instead...\n"
    exec "/bin/sh"
  end
end

include ZenCore

#-----------------------------------------------------------
# Zenlog built-in commands.
#-----------------------------------------------------------

USE_READABLE_CONSTS = false

module PipeHelper
  if USE_READABLE_CONSTS
    COMMAND_MARKER = "!zenlog:"
    ESCAPE = "~"
    SEPARATOR = ","
  else
    COMMAND_MARKER = "\x01\x09\x07\x03\x02\x05zenlog:"
    ESCAPE = "\x1a"     #SUB
    SEPARATOR = "\x1f"  #US
  end

  def self._encode_single(s)
    return s.to_s.gsub(/[\n#{ESCAPE}#{SEPARATOR}]/o) do
      |c| "#{ESCAPE}#{sprintf '%02x', c.ord}"
    end
  end

  def self._decode_single(s)
    return s.gsub(/#{ESCAPE}../o) do
      |ehex| ehex[1..-1].to_i(16).chr
    end
  end

  def self.encode(*args)
    return COMMAND_MARKER + args.map {|s| _encode_single s}.join(SEPARATOR) + "\n"
  end

  def self.decode(args_line)
    return args_line.split(SEPARATOR).map {|s| _decode_single s}
  end

  def self.try_decode(line)
    pos = line.index(COMMAND_MARKER)
    return nil unless pos

    pre = (pos > 0) ? line[0, pos] : nil

    return pre, decode(line[pos + COMMAND_MARKER.length .. -1].chomp)
  end
end

#-----------------------------------------------------------
# Global constants
#-----------------------------------------------------------
START_COMMAND = "start"
STOP_COMMAND = "stop"
SYNC_REQ_COMMAND = "sync"
CHILD_FINISHED = "child_finished"

#-----------------------------------------------------------
# Zenlog built-in commands.
#-----------------------------------------------------------
module BuiltIns
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
    # debug{"tty=#{tty}\n"}
    return (tty != nil) && (ENV[ZENLOG_TTY] == get_tty)
  end

  # Subcommand: zenlog fail-if-in-zenlog
  public
  def self.fail_if_in_zenlog exit_status:0
    die 'already in zenlog.', exit_status:exit_status if in_zenlog
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
  def self.start_command(command_line_words, env:nil)
    debug {"[Command start: #{command_line_words.join(" ")}]\n"}
    if in_zenlog
      fingerprint = Time.now.to_f.to_s
      io_error_okay do
        # Send "command start" to the logger directly.
        zenlog_working = with_logger do |out|
          out.print(PipeHelper.encode(START_COMMAND, fingerprint,
              command_line_words.join(" "), env))
        end

        # Wait until the log files are actually created.
        # A better way may be to create all files in this side and
        # pass the filenames.... Which v2 did.
        if zenlog_working
          wait_reply do |args|
            return (args[0] == START_COMMAND) && (args[1] == fingerprint)
          end
        end
      end
    end
    return true
  end

  # Subcommand: zenlog stop-log
  # Tell zenlog to stop logging the current command.
  private
  def self.stop_log(args)
    debug "[Stop log]\n"
    if in_zenlog
      # If "-n" is passed, print the number of lines in the log.
      if args.length > 0 && args[0] == "-n"
        want_lines = true
        args.shift
      end
      exit_status = (args.length > 0) ? args.shift : ""

      io_error_okay do
        # Send "stop log" to the logger directly.
        fingerprint = Time.now.to_f.to_s
        zenlog_working = with_logger do |out|
          out.print(PipeHelper.encode(STOP_COMMAND, fingerprint, exit_status))
        end
        if zenlog_working
          wait_reply do |res_args|
            debug {"Reply args: #{args.inspect}"}
            if (res_args[0] == STOP_COMMAND) && (res_args[1] == fingerprint)
              # Print number of log lines.
              print res_args[2], "\n" if want_lines
              return true
            else
              return false
            end
          end
        end
      end
    end
  end

  private
  def self.wait_reply(&block)
    ifile = ENV[ZENLOG_COMMAND_IN]
    File.readable?(ifile) && open(ifile, "r") do |i|
      begin
        Timeout::timeout(5) do
          i.each_line do |line|
            #debug {"Reply: #{line}"}
            _ignore, args = PipeHelper.try_decode(line)
            if args && block.call(args)
              debug "[Reply received]\n"
              break
            end
          end
        end
      rescue Timeout::Error
        say "zenlog: Timed out waiting for reply from logger.\n"
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
  def self.history(type, pid, nth)
    dir = ENV[ZENLOG_DIR] + "/pids/" + pid.to_s
    debug {"Log dir: #{dir}\n"}
    exit false unless File.directory? dir

    die "Invalid type '#{type}'" unless type =~ /^[PRE]$/;

    name = type

    if nth >= 0
      files = [dir + "/" + name * (nth + 1)]
    else
      files = Pathname.glob(dir + "/" + name + "*") \
          .reject {|p| !p.symlink?} \
          .map {|x| x.to_s}
    end

    files.map {|f| File.readlink(f)}.map {|f| f.gsub(/\/+/, "/")}.sort.each {|f| puts f}

    return true
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
      return ->(*args){start_command(args)}

    when "start_command_with_env"
      return ->(*args){start_command(args[1..-1], env:args[0])}

    when "stop_log"
      return ->(*args){stop_log(args)}

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

    end

    return nil
  end
end

#-----------------------------------------------------------
# Sits in the background and writes log.
#-----------------------------------------------------------
class ZenLogger
  CRAW = 'RAW'
  CRAW_LINK = 'R'
  CSAN = 'SAN'
  CSAN_LINK = 'P'
  CENV = 'ENV'
  CENV_LINK = 'E'

  NOLOG_PREFIX = "184"
  YESLOG_PREFIX = "186"

  MAX_PREV_LINKS = 10

  public
  def initialize(log_dir, child_pid, logger_in, command_out)
    @log_dir = log_dir
    @pid = ENV[ZENLOG_LOGGER_PID] || $$
    @child_pid = child_pid
    @logger_in = logger_in
    @command_out = command_out
    @prefix_commands = ENV[ZENLOG_PREFIX_COMMANDS] || \
        DEFAULT_ZENLOG_PREFIX_COMMANDS
    @always_no_log_commands = ENV[ZENLOG_ALWAYS_NO_LOG_COMMANDS] || \
        DEFAULT_ZENLOG_ALWAYS_NO_LOG_COMMANDS

    @prefix_commands_re = Regexp.compile('^' + @prefix_commands + '$')
    @always_no_log_commands_re = Regexp.compile('^' + @always_no_log_commands + '$')

    debug {
      "Logger @pid=#{@pid}\n" +
      "Logger @prefix_commands=#{@prefix_commands}\n" +
      "Logger @always_no_log_commands=#{@always_no_log_commands}\n"
    }

    @san = nil
    @raw = nil
    @env = nil

    @command_start_time = nil
  end

  private
  def get_time
    if TIMEFILE
      now = open(TIMEFILE, "r").read().to_i
      open TIMEFILE, "w" do |out|
        out.print (now + 1).to_s
      end
      return Time.at(now)
    else
      return Time.now.getlocal
    end
  end

  private
  def create_prev_links(full_dir_name, link_name, log_file_name)
    return unless File.exist? log_file_name.to_s
    begin
      MAX_PREV_LINKS.downto(2) do |n|
        from = (full_dir_name + "/" + (link_name * (n - 1)))
        to   = full_dir_name + "/" + (link_name * n)
        FileUtils.rm(to, {force:true}) if File.exist? to
        FileUtils.mv(from, to) if File.exist? from
      end
      FileUtils.ln_sf(log_file_name, full_dir_name + "/" + link_name)
    rescue SystemCallError => e
      say "zenlog: failed to create a symlink: #{e}\n"
    end
  end

  private
  def create_links(parent_dir, dir, type, link_name, log_file_name, now)
    return if dir == "." || dir == ".." || dir == ""

    return unless File.exist? log_file_name.to_s

    full_dir_name = (@log_dir + "/" + parent_dir + "/" + dir + "/" + type +
        "/" + now.strftime('%Y/%m/%d')).gsub(%r!/+!, "/")

    begin
      FileUtils.mkdir_p(full_dir_name)

      FileUtils.ln_sf(log_file_name,
          full_dir_name + "/" + log_file_name.sub(/^.*\//, ""))

      create_prev_links(@log_dir + "/" + parent_dir + "/" + dir, link_name, log_file_name)
    rescue SystemCallError => e
      say "zenlog: failed to create a symlink: #{e}\n"
    end
  end

  # Start logging for a command.
  # Open the raw/san streams, create symlinks, etc.
  def start_logging(command_line, env)
    tokens = shsplit(command_line)

    # All the executable command names in the command pipeline.
    command_names = []

    # Comment, which is used for tagging.
    comment = nil

    nolog_detected = false
    yeslog_detected = false

    if tokens.length > 0
      # If the last token starts with "#", it's a comment.
      last = tokens[-1]
      if last =~ /^\#/
        # Compress consecutive spaces into one.
        comment = last.sub(/^#\s*/, '').sub(/\s\s+/, " ")
      end

      command_start = true
      tokens.each do |token|
        if is_shell_command_separator(token)
          command_start = true
          next
        end
        # Extract the first token as a command name.
        if command_start
          if token =~ @prefix_commands_re
            next
          end
          if token == NOLOG_PREFIX
            nolog_detected = true
            next
          end
          if token == YESLOG_PREFIX
            yeslog_detected = true
            next
          end
          command_names << token.sub(/^.*\//, '')
          command_start = false
          nolog_detected = true if token =~ @always_no_log_commands_re
        end

        command_start |= (token =~ /^(?: \| | \|\| | \&\& | \; )$/x)
      end
      debug {"Commands=#{command_names.inspect}#{nolog_detected ? " *nolog" : ""}" +
          ", comment=#{comment}\n"}
    end

    nolog_detected = false if yeslog_detected

    open_log(command_line, command_names, comment, nolog_detected, env)
  end

  private
  def create_log_filename(command_line, tag, now)
    tag_str = "_+" + tag if tag.to_s != ""
    command_str = filename_safe(command_line)[0,32]

    return sprintf("%s/#{CRAW}/%s-%05d%s_+%s.log",
        @log_dir,
        now.strftime('%Y/%m/%d/%H-%M-%S.%L'),
        @pid,
        tag_str,
        command_str).gsub(%r(/+), "/") # compress consecutive /s.
  end

  private
  def open_logfile(filename)
    FileUtils.mkdir_p(File.dirname(filename))
    out = open(filename, "w")
    out.sync = true if AUTOSYNC_LOG
    return out
  end

  private
  def open_log(command_line, command_names, comment, no_log, env)
    stop_logging()

    tag = filename_safe(comment)
    now = get_time
    @command_start_time = now

    raw_name = create_log_filename(command_line, tag, now)
    san_name = raw_name.gsub(/#{CRAW}/o, CSAN)

    @raw = open_logfile(raw_name)
    @san = open_logfile(san_name)
    if env
      env_name = raw_name.gsub(/#{CRAW}/o, CENV)
      @env = open_logfile env_name
      @env.print "Command: ", command_line, "\n"
      write_now_to_env "Start time", now
      @env.print env
      @env.flush
    end

    [[raw_name, CRAW, CRAW_LINK],
        [san_name, CSAN, CSAN_LINK],
        [env_name, CENV, CENV_LINK]
        ].each do |log_name, type, link_name|
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
    @num_lines_written = 0

    if no_log
      write_log "[omitted]\n"
      stop_logging
      return
    end
  end

  private
  def write_now_to_env(label, time)
    if @env
      @env.print label, ": ", time.strftime('%Y/%m/%d %H:%M:%S.%L'), "\n"
    end
  end

  private
  def write_log(line, flush:true, ready_check:nil)
    if AUTOSYNC_LOG
      flush = false
    else
      flush = !ready_check.ready? if ready_check
    end
    if @raw
      @raw.print(line)
      @raw.flush if flush
      @num_lines_written += 1
    end
    if @san
      @san.print(sanitize(line))
      @san.flush if flush
    end
  end

  private
  def stop_logging(status=nil)
    if @env && (status.to_s != "")
      @env.puts
      @env.print "Exit status: ", status, "\n"
      now = get_time
      write_now_to_env "Finish time", now
      @env.print "Duration: ", now - @command_start_time, "\n"
    end
    @raw.close if @raw
    @san.close if @san
    @env.close if @env
    @raw = nil
    @san = nil
    @env = nil
  end

  # This is called when
  private
  def on_child_finished()
    child_status = Process.waitpid2(@child_pid)[1].exitstatus

    clean_up()

    # http://www.tldp.org/LDP/abs/html/exitcodes.html for what 126 and 127 are.
    if child_status == 126 || child_status == 126
      say "\e[0m\e[31mZenlog: Failed to start child process.\e[0m\n"
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
      @num_lines_written = 0

      @logger_in.each_line do |line| # TODO Make sure CR will split liens too.
        #debug {"line: #{line}\n"}

        pre_line, args = PipeHelper.try_decode(line)

        to_write = args ? pre_line : line
        if to_write
          write_log to_write, ready_check:@logger_in
        end

        next unless args

        debug {"Args: #{args.inspect}\n"}
        # Handle start request.
        if args[0] == START_COMMAND
          fingerprint = args[1]
          command = args[2]
          env = args[3]

          if !in_command
            in_command = true
            debug {"Command started: \"#{command}\"\n"}
            start_logging(command, env)
          else
             say "zenlog: Command start requested but already in command: \"#{command}\"\n"
          end

          @command_out.print(PipeHelper.encode(START_COMMAND, fingerprint))
          next
        end

        # Handle stop request.
        if args[0] == STOP_COMMAND
          fingerprint = args[1]
          exit_status = args[2]

          if in_command
            in_command = false
            debug {"Command finished: #{fingerprint}, status=#{exit_status}\n"}

            write_log(pre_line, flush:false) if pre_line
            stop_logging exit_status
          end
          @command_out.print(PipeHelper.encode(STOP_COMMAND, fingerprint, @num_lines_written))
          next
        end

        if args[0] == CHILD_FINISHED
          on_child_finished
          next
        end

        say "zenlog: Unknown command '#{args[0]}' received.\n"
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

    if @rc_file.to_s != ""
      if File.exist?(@rc_file) && !File.zero?(@rc_file)
        debug {"Loading #{@rc_file}...\n"}

        # Somehow "load" doesn't load from /dev/null? So we skip a 0 byte file.
        load @rc_file
      else
        debug {"Missing #{@rc_file}, ignored.\n"}
      end
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
    # We don't want to start the emergency cell in this case,
    # So let's just return 0 for now.
    BuiltIns.fail_if_in_zenlog exit_status:0

    init()

    if !Dir.exist? @log_dir
      say "zenlog: #{@log_dir} doesn't exist.\n"
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
          "-efqc",
          "#{ZENLOG_SHELL_PID}=#{$$} " +
          "#{ZENLOG_LOGGER_OUT}=#{shescape logger_out_name} " +
          "#{ZENLOG_COMMAND_IN}=#{shescape command_in_name} " +
          "#{ZENLOG_TTY}=$(tty) " +
          "exec #{shescape_multi @start_command}",
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
        @logger_out.print(PipeHelper.encode(CHILD_FINISHED))
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

if STARTED_AS_SCRIPT
  Main.new.main(ARGV)
end
