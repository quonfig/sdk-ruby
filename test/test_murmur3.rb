# frozen_string_literal: true

require 'minitest/autorun'
require 'quonfig/murmer3'

# MurmurHash3 x86 32-bit, seed 0 (the seed WeightedValueResolver uses), over the
# string's UTF-8 BYTES. Expected values come from the reference implementation:
# Python `mmh3.hash(s, 0, signed=False)` (mmh3 5.x), which is what sdk-python
# uses and what sdk-java / sdk-go / sdk-node match (qfg-1mvb).
class TestMurmur3 < Minitest::Test
  ASCII_VECTORS = {
    '' => 0,
    'a' => 1_009_084_850,
    'abc' => 3_017_643_002,
    'abcd' => 1_139_631_978,
    'hello world' => 1_586_663_183,
    'my.flag.keyuser-123' => 827_905_149
  }.freeze

  NON_ASCII_VECTORS = {
    'é' => 269_551_495, # 1 char, 2 bytes
    '日本語' => 2_779_017_879, # 3 chars, 9 bytes
    '🚀' => 2_137_479_269, # 1 char, 4 bytes
    'café' => 605_818_632, # 4 chars, 5 bytes
    'naïve-user-ü' => 133_692_014, # 12 chars, 14 bytes
    'flag.keyユーザー🚀x' => 1_013_723_230 # 15 chars, 25 bytes
  }.freeze

  def test_ascii_vectors_match_reference
    ASCII_VECTORS.each do |input, expected|
      assert_equal expected, Murmur3.murmur3_32(input), "murmur3_32(#{input.inspect})"
    end
  end

  def test_non_ascii_vectors_hash_utf8_bytes
    NON_ASCII_VECTORS.each do |input, expected|
      assert_equal expected, Murmur3.murmur3_32(input), "murmur3_32(#{input.inspect})"
    end
  end

  def test_same_bytes_in_binary_encoding_hash_identically
    NON_ASCII_VECTORS.each do |input, expected|
      assert_equal expected, Murmur3.murmur3_32(input.b), "murmur3_32(#{input.inspect}.b)"
    end
  end

  def test_does_not_mutate_or_reencode_input
    input = +'日本語'
    Murmur3.murmur3_32(input)
    assert_equal Encoding::UTF_8, input.encoding
    assert_equal '日本語', input
  end
end
