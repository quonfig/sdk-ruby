# frozen_string_literal: true

require 'test_helper'
class TestSemanticVersion < Minitest::Test
  def test_parse_valid_version
    version = SemanticVersion.parse('1.2.3')
    assert_equal 1, version.major
    assert_equal 2, version.minor
    assert_equal 3, version.patch
    assert_nil version.prerelease
    assert_nil version.build_metadata
  end

  def test_parse_version_with_prerelease
    version = SemanticVersion.parse('1.2.3-alpha.1')
    assert_equal 1, version.major
    assert_equal 2, version.minor
    assert_equal 3, version.patch
    assert_equal 'alpha.1', version.prerelease
    assert_nil version.build_metadata
  end

  def test_parse_version_with_build_metadata
    version = SemanticVersion.parse('1.2.3+build.123')
    assert_equal 1, version.major
    assert_equal 2, version.minor
    assert_equal 3, version.patch
    assert_nil version.prerelease
    assert_equal 'build.123', version.build_metadata
  end

  def test_parse_full_version
    version = SemanticVersion.parse('1.2.3-alpha.1+build.123')
    assert_equal 1, version.major
    assert_equal 2, version.minor
    assert_equal 3, version.patch
    assert_equal 'alpha.1', version.prerelease
    assert_equal 'build.123', version.build_metadata
  end

  def test_parse_invalid_version
    assert_raises(ArgumentError) { SemanticVersion.parse('invalid') }
    assert_raises(ArgumentError) { SemanticVersion.parse('1.2') }
    assert_raises(ArgumentError) { SemanticVersion.parse('1.2.3.4') }
    assert_raises(ArgumentError) { SemanticVersion.parse('') }
  end

  def test_parse_quietly
    assert_nil SemanticVersion.parse_quietly('invalid')
    refute_nil SemanticVersion.parse_quietly('1.2.3')
  end

  def test_to_string
    assert_equal '1.2.3', SemanticVersion.parse('1.2.3').to_s
    assert_equal '1.2.3-alpha.1', SemanticVersion.parse('1.2.3-alpha.1').to_s
    assert_equal '1.2.3+build.123', SemanticVersion.parse('1.2.3+build.123').to_s
    assert_equal '1.2.3-alpha.1+build.123', SemanticVersion.parse('1.2.3-alpha.1+build.123').to_s
  end

  def test_equality
    v1 = SemanticVersion.parse('1.2.3')
    v2 = SemanticVersion.parse('1.2.3')
    v3 = SemanticVersion.parse('1.2.4')
    v4 = SemanticVersion.parse('1.2.3-alpha')
    v5 = SemanticVersion.parse('1.2.3+build.123')

    assert_equal v1, v2
    refute_equal v1, v3
    refute_equal v1, v4
    assert_equal v1, v5 # build metadata is ignored in equality
  end

  def test_comparison
    versions = [
      '1.0.0-alpha',
      '1.0.0-alpha.1',
      '1.0.0-beta.2',
      '1.0.0-beta.11',
      '1.0.0-rc.1',
      '1.0.0',
      '2.0.0',
      '2.1.0',
      '2.1.1'
    ].map { |v| SemanticVersion.parse(v) }

    # Test that each version is less than the next version
    (versions.length - 1).times do |i|
      assert versions[i] < versions[i + 1], "Expected #{versions[i]} < #{versions[i + 1]}"
    end
  end

  def test_prerelease_comparison
    # Test specific prerelease comparison cases
    cases = [
      ['1.0.0-alpha', '1.0.0-alpha.1', -1],
      ['1.0.0-alpha.1', '1.0.0-alpha.beta', -1],
      ['1.0.0-alpha.beta', '1.0.0-beta', -1],
      ['1.0.0-beta', '1.0.0-beta.2', -1],
      ['1.0.0-beta.2', '1.0.0-beta.11', -1],
      ['1.0.0-beta.11', '1.0.0-rc.1', -1],
      ['1.0.0-rc.1', '1.0.0', -1]
    ]

    cases.each do |v1_str, v2_str, expected|
      v1 = SemanticVersion.parse(v1_str)
      v2 = SemanticVersion.parse(v2_str)
      assert_equal expected, (v1 <=> v2), "Expected #{v1} <=> #{v2} to be #{expected}"
    end
  end
end
