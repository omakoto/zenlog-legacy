/bin/true; exec ruby -wSx "$0"
#!ruby

require_relative "../../zenlog"

require "test/unit"
require 'stringio'

class TestPipeHelper < Test::Unit::TestCase
  def check_encode_single(expected, input)
    assert_equal(expected, PipeHelper._encode_single(input))
  end

  def test_encode_single
    check_encode_single("", "")
    check_encode_single("abc", "abc")
    check_encode_single("abc\x1a0adef", "abc\ndef")
    check_encode_single("abc\x1a0adef\x1a1a", "abc\ndef\x1a")
    check_encode_single("abc\x1a0adef\x1a1f", "abc\ndef\x1f")
    check_encode_single("abc\x1a0ad e f\x1a1f", "abc\nd e f\x1f")
  end

  def check_encode_decode(prefix, args)
    encoded = prefix + PipeHelper.encode(args)
    decoded_prefix, decoded_args = PipeHelper.try_decode(encoded)

    assert_equal(prefix, decoded_prefix)
    assert_equal(args, decoded_args)
  end

  def test_encode_decode
    check_encode_decode "", []
    check_encode_decode "abc", []
    check_encode_decode "abc\x1a", []

    check_encode_decode "", %w(aa bbb cc d)
    check_encode_decode "", %w(a)
    check_encode_decode "abc", ["\nab\x1a,  ", "def"]
  end

  def test_try_decode_fail
    assert_equal(nil, PipeHelper.try_decode(""))
    assert_equal(nil, PipeHelper.try_decode("abc"))
  end
end

class TestBuiltIns < Test::Unit::TestCase
  include BuiltIns # To access the constants.

  def test_find_marker
    assert_equal(nil, BuiltIns.find_marker("abcdef", "x"))
    assert_equal(["ab", "ef"], BuiltIns.find_marker("abcdef", "cd"))
    assert_equal(["", "ef"], BuiltIns.find_marker("abcdef", "abcd"))
    assert_equal(["ab", ""], BuiltIns.find_marker("abcdef", "cdef"))
  end

  def test_match_command_start
    assert_equal(nil, BuiltIns.match_command_start("abc def xyz"))
    assert_equal("def xyz", BuiltIns.match_command_start("abc" + COMMAND_START_MARKER + "def xyz"))
  end

  def test_match_stop_log
    assert_equal(nil, BuiltIns.match_stop_log("abc def xyz"))
    assert_equal(["abc", "def xyz"], BuiltIns.match_stop_log("abc" + STOP_LOG_MARKER + "def xyz"))
  end
end
