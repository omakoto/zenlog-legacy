#!/bin/bash

medir="${0%/*}"

. "$medir/zenlog-test-common"

clear_log

cd "$medir"

run_zenlog <<EOF
echo ok; tick 3
cat data/fstab | grep -v -- '^#'
man man
q
zenlog history # history 1
echo ok | cat # tag test abc  def <>/
zenlog current-log # com current log
zenlog last-log # com last log
zenlog current-log -r # com r current log
zenlog last-log -r # com r last log
true && echo "and test" # and test
false || echo "or test" # or test
cat data/fstab | fgrep dev
in_zenlog && echo "in zenlog"
zenlog_current_log # fun current log
zenlog_last_log # fun last log
zenlog_current_log -r # fun r current log
zenlog_last_log -r # fun r last log
zenlog history # history 2
zenlog history -r # history raw
echo $'a\xffb' # broken utf8
exit
EOF

echo "Checking tree..."
diff --color=always -c $medir/results/tree1.txt <($TREE -aF "$ZENLOG_DIR")

echo "Checking log files..."
diff --exclude ENV --color=always  -X $medir/diff-ignore-files.txt \
    -ur $medir/results/files "$ZENLOG_DIR"

echo "Checking env files..."
# rm -fr /tmp/zendiff
# mkdir -p /tmp/zendiff
# cp -pr "$medir/results/files/ENV" /tmp/zendiff/expected
# cp -pr "$ZENLOG_DIR/ENV" /tmp/zendiff/actual

# find /tmp/zendiff -type f | xargs perl -pi "
# next if /^git HEAD:/
# s/$medir/<medir>/
# "
#diff --color=always -ur /tmp/zendiff/expected /tmp/zendiff/actual

# Let's just ignore most lines... For now we only check start/finish times.
diff --color=always -X $medir/diff-ignore-files.txt \
    -I '^PWD:' -I '^git HEAD:' -I '^[a-zA-Z0-9_]*=' -ur \
    $medir/results/files/ENV "$ZENLOG_DIR/ENV"
