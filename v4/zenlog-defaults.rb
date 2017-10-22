DEFAULT_ZENLOG_DIR = Dir.home() + "/zenlog"
DEFAULT_ZENLOG_START_COMMAND = "#{ENV['SHELL']} -l"
DEFAULT_ZENLOG_PREFIX_COMMANDS = "(?:command|builtin|time|sudo|[a-zA-Z0-9_]+\=.*)"
DEFAULT_ZENLOG_ALWAYS_NO_LOG_COMMANDS = "(?:vi|vim|man|nano|pico|less|watch|emacs|zenlog.*)"
