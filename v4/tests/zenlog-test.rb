/bin/true; exec ruby -wSx "$0"
#!ruby

require_relative "../zenlog"

require "test/unit"

class TestBuiltIns < Test::Unit::TestCase
  include BuiltIns

  def test_find_marker
    assert_equal(nil, find_marker("abcdef", "x"))
    assert_equal(["ab", "ef"], find_marker("abcdef", "cd"))
    assert_equal(["", "ef"], find_marker("abcdef", "abcd"))
    assert_equal(["ab", ""], find_marker("abcdef", "cdef"))
  end

  def test_match_command_start
    assert_equal(nil, match_command_start("abc def xyz"))
    assert_equal("def xyz", match_command_start("abc" + COMMAND_START_MARKER + "def xyz"))
  end

  def test_match_stop_log
    assert_equal(nil, match_stop_log("abc def xyz"))
    assert_equal(["abc", "def xyz"], match_stop_log("abc" + STOP_LOG_MARKER + "def xyz"))
  end
end
