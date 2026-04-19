# frozen_string_literal: true

class SemanticVersion
  include Comparable

  SEMVER_PATTERN = /
    ^
    (?<major>0|[1-9]\d*)
    \.
    (?<minor>0|[1-9]\d*)
    \.
    (?<patch>0|[1-9]\d*)
    (?:-(?<prerelease>
      (?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)
      (?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*
    ))?
    (?:\+(?<buildmetadata>[0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?
    $
  /x

  attr_reader :major, :minor, :patch, :prerelease, :build_metadata

  def self.parse(version_string)
    raise ArgumentError, "version string cannot be nil" if version_string.nil?
    raise ArgumentError, "version string cannot be empty" if version_string.empty?

    match = SEMVER_PATTERN.match(version_string)
    raise ArgumentError, "invalid semantic version format: #{version_string}" unless match

    new(
      major: match[:major].to_i,
      minor: match[:minor].to_i,
      patch: match[:patch].to_i,
      prerelease: match[:prerelease],
      build_metadata: match[:buildmetadata]
    )
  end

  def self.parse_quietly(version_string)
    parse(version_string)
  rescue ArgumentError
    nil
  end

  def initialize(major:, minor:, patch:, prerelease: nil, build_metadata: nil)
    @major = major
    @minor = minor
    @patch = patch
    @prerelease = prerelease
    @build_metadata = build_metadata
  end

  def <=>(other)
    return nil unless other.is_a?(SemanticVersion)

    # Compare major.minor.patch
    return major <=> other.major if major != other.major
    return minor <=> other.minor if minor != other.minor
    return patch <=> other.patch if patch != other.patch

    # Compare pre-release versions
    compare_prerelease(prerelease, other.prerelease)
  end

  def ==(other)
    return false unless other.is_a?(SemanticVersion)

    major == other.major &&
      minor == other.minor &&
      patch == other.patch &&
      prerelease == other.prerelease
    # Build metadata is ignored in equality checks
  end

  def eql?(other)
    self == other
  end

  def hash
    [major, minor, patch, prerelease].hash
  end

  def to_s
    result = "#{major}.#{minor}.#{patch}"
    result += "-#{prerelease}" if prerelease
    result += "+#{build_metadata}" if build_metadata
    result
  end

  private

  def self.numeric?(str)
    str.to_i.to_s == str
  end

  def compare_prerelease(pre1, pre2)
    # If both are empty, they're equal
    return 0 if pre1.nil? && pre2.nil?

    # A version without prerelease has higher precedence
    return 1 if pre1.nil?
    return -1 if pre2.nil?

    # Split into identifiers
    ids1 = pre1.split('.')
    ids2 = pre2.split('.')

    # Compare each identifier until we find a difference
    [ids1.length, ids2.length].min.times do |i|
      cmp = compare_prerelease_identifiers(ids1[i], ids2[i])
      return cmp if cmp != 0
    end

    # If all identifiers match up to the length of the shorter one,
    # the longer one has higher precedence
    ids1.length <=> ids2.length
  end

  def compare_prerelease_identifiers(id1, id2)
    # If both are numeric, compare numerically
    if self.class.numeric?(id1) && self.class.numeric?(id2)
      return id1.to_i <=> id2.to_i
    end

    # If only one is numeric, numeric ones have lower precedence
    return -1 if self.class.numeric?(id1)
    return 1 if self.class.numeric?(id2)

    # Neither is numeric, compare as strings
    id1 <=> id2
  end
end