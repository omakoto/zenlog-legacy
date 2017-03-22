# Zenlog initialization file.

# Start this command instead of the default shell.
$ENV{ZENLOG_START_COMMAND} = "$ENV{HOME}/cbin/bin-linux64/lbash -l";

# Log directory.
$ENV{ZENLOG_DIR} = "/tmp/zenlog/";

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
$ENV{ZENLOG_PREFIX_COMMANDS} = "(?:builtin|time|ee|eet|wb|Test\:|Running\:?|forever|FI|sudo)";

# Always do not log output from these commands.
$ENV{ZENLOG_ALWAYS_184_COMMANDS} = "(?:1|cd|vi|vim|man|nano|pico|less|watch|emacs|mhist|root|ssh|ssh-ce|ssh-com|htop|nload)";
