/bin/true; exec ruby -wSx "$0"
#!ruby

require_relative "../../zenlog"

require "test/unit"

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
    encoded = prefix + PipeHelper.encode(*args)
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

