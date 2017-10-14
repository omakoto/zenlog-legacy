# Zenlog

Zenlog is a wrapper around a login shell to save all command output to a separate log file for each command automatically, so you no longer need to use tee(1) to keep log files.

The the current version is v4.

Old versions (v0 and v1) worked with bash <= 4.3. Newer versions (v2, written in Perl, and v4, rewritten in Ruby) require PS0 support, which is new in bash 4.4 (aka pre-exec hook).
 
## How it works

[The version 0 script](v0/zenlog) shows the basic idea, which is "start a login shell within script(1) and let it log all terminal I/O to a file, but instead of logging to an actual file, pass it to a logger script via a pipe, and let the script detect each command start/end and save the output to separate log files."

Originally the logger script detected command start and finish by detecting special markers embedded in the command prompt. The command start and stop markers were ANSI escape sequences that wouldn't show up on terminal and were made redundant so a sane program would never output. "Redundant" means that, for example, `\e[0m` is a sequence to reset character attributes which is frequently used, and `\e[000000m` technically has the same meaning but no one would write it this way. Zenlog used sequences like this to pass information from within script(1) to the logger script, without showing it on the terminal.

Since v2, Zenlog requires "pre-exec hook", which is `P0` that was added in Bash 4.4. `P0` and `PROMPT_COMMAND` are used to tell the logger process that 1) when to start logging 2) what the command line is, which is used to create per-command synlinks and "tagging" and 3) when to stop logging.

[The sample bash configuration script](shell/zenlog.bash) shows what command needs to be executed from `P0` and `PROMPT_COMMAND`.

Zenlog still uses special markers to pass the information to the logger process, but they're now directly written to the pipe via `/proc/PID/fd/n`, so they're no longer escape sequences.

Zenlog now also uses another pipe to pass the information from the logger to the shell, which is use to wait until the last log file is closed by `zenlog stop_log`.

## Install and setup

To install, just clone this project:

```
git clone https://github.com/omakoto/zenlog.git
```

Then add the following to your `.bashrc`.
```
source PATH-TO-THIS-FILE/zenlog.bash
```

(Note this will overwrite `P0` and `PROMPT_COMMAND`, so if you don't like it, look at the script and do whatever you want.)

Then, run the `zelog` command to start a new Zenlog session. By default, log files are stored in `$HOME/zenlog/`.

### Using other shells

Any shell should work, as long as it supports some sort of "pre-exec" and "post-exec" hooks.

### Optional GEM installation

Zenlog needs to know the ttyname of the current terminal, and it uses ps(1) to get it by default. However if the [ttyname](https://github.com/samuelkadolph/ruby-ttyname) gem is installed, Zenlog uses it, which is a bit faster.

## Log directory structure

For each command, Zenlog creates two log files. One is called "RAW", which is the original output. However because command output often contains colors, RAW log files are hard to read on an editor and also search. So Zenlog also creates anther log file "SAN" (SANitized), which has most standard ANSI sequences removed.

SAN log files have names like this. Basically log filenames contain the timestam, the shortened command line, as well as the comment part in the command line if exists.
```
/home/USER/zenlog/SAN/2017/10/14/13-34-03.589-06327_+_+ls-l.log
```

RAW log files have the exact same filename, except they're stored in the `RAW` directory.
```
/home/USER/zenlog/RAW/2017/10/14/13-34-03.589-06327_+_+ls-l.log
```

To allow easier access to log files, Zenlog creates a lot of symlinks. (The idea came from [Tanlog](https://github.com/shinh/test/blob/master/tanlog.rb))

```
/home/USER/zenlog/P # The last command SAN output.
/home/USER/zenlog/R # The last command RAW output.
/home/USER/zenlog/PP # Second last SAN log
/home/USER/zenlog/PPP # Third last SAN log
  :
/home/USER/zenlog/RR # Second last RAW log
/home/USER/zenlog/RRR # Third last RAW log
  :
/home/USER/zenlog/cmds/ls/P # The last SAN output from ls
/home/USER/zenlog/cmds/ls/R # The last RAW output from ls
  :
/home/USER/zenlog/tags/TAGNAME/P # The last SAN output with TAGNAME
/home/USER/zenlog/tags/TAGNAME/R # The last RAW output with TAGNAME
  :
```

`TAGNAME` is a comment in command line.

So, for example, if you run the following command:
```
$ cat /etc/fstab | sed '/^#/d' # fstab comments removed
```

You'll get the regular SAN/RAW log files, as well as the following symlinks:
```
/home/USER/zenlog/cmds/cat/P
/home/USER/zenlog/cmds/cat/R

/home/USER/zenlog/cmds/sed/P
/home/USER/zenlog/cmds/sed/R

/home/USER/zenlog/tags/fstab_comments_removed/P
/home/USER/zenlog/tags/fstab_comments_removed/R
```

`zenlog history` shows the most recent SAN log filenames on the current shell:

```
$ zenlog history # Add "-r" to get RAW filenames.
/home/USER/zenlog/SAN/2017/10/14/13-44-18.749-07884_+fstab_comments_removed_+cat_etc_fstab_sed_^#_d_#_fstab_c.log
/home/USER/zenlog/SAN/2017/10/14/13-46-16.322-07884_+_+zenlog_history.log
```

## Subcommands

To be written...

* `zenlog history`

* `zenlog start-command COMMANDLINE`

* `zenlog stop-log`

* `zenlog purge-log`



## Configuration

### Environmental variables

* `ZENLOG_DIR`

Log directory. Default is `$HOME/zenlog`.

* `ZENLOG_PREFIX_COMMANDS`

A regex that matches command names that are considered "prefix", which will be ignored when Zenlog detects command names. For example, if `time` is a prefix command, when you run `time cc ....`, the log filename will be `"cc"`, not `"time"`.

The default is `"(?:command|builtin|time|sudo)"`

* `ZENLOG_ALWAYS_NO_LOG_COMMANDS`

A regex that matches command names that shouldn't be logged. When Zenlog detect these commands, it'll create log files, but the content will be omitted.

The default is `"(?:vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)"`

### RC file

* `$HOME/.zenlogrc.rb`

If this file exists, Zenlog loads it before starting a session. 

If you star Zenlog directory form a terminal application, Zenlog starts before the actual login shell starts, so you can't configure it with the shell's RC file. Instead you can configure environmental variables in this file.

## History

* v0 -- the original version. It evolved from a proof-of-concept script, which is bash-perl hybrid, because I wanted to keep everything in a single file, and I kinda liked the ugliness of the hybrid script. The below script shows the basic structure. ZENLOG_TTY was (and still is) used to check if the current terminal is within Zenlog or not.

```bash
#!/bin/bash

# initialization, etc in bash

script -qcf 'ZENLOG_TTY=$(tty) exec bash -l' >(perl <(cat <<'EOF'
# Logger script in perl
EOF
) )
```

* v1 -- The hybrid script was getting harder and harder to maintain and was also ugly, so I split it into multiple files. Also subcommands were now extracted to separate files too. v1 still has both the Bash part and the Perl part.

 * v2 -- Re-wrote in Perl. No more Bash, except in external subcommands.

 * v3 -- Original attempt to rewrite in Ruby, but got bored and this didn't happen.

 * v4 -- v2 was still ugly and hard to improve, so finally re-wrote in Ruby. This has a lot better command line parser, for example, which is used to detect command names in a command line. v2's parser was very hacky so it could mis-parse.
