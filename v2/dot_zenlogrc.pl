# Zenlog initialization file.

# Start this command instead of the default shell.
$ZENLOG_START_COMMAND = "$ENV{HOME}/cbin/bin-linux64/lbash -l";

# Log directory.
$ZENLOG_DIR = "/zenlog/";

# Prefix commands are ignored when command lines are parsed;
# for example "sudo cat" will considered to be a "cat" command.
$ZENLOG_PREFIX_COMMANDS = "(builtin|time|ee|eet|wb|Test\:|Running\:?|forever|FI|sudo)";

# Always do not log output from these commands.
$ZENLOG_ALWAYS_184_COMMANDS = "(1|cd|vi|vim|man|nano|pico|less|watch|emacs|mhist|root|ssh|ssh-ce|ssh-com|htop|nload)";