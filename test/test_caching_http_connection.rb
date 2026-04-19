# frozen_string_literal: true

require 'test_helper'

module Quonfig
  class CachingHttpConnectionTest < Minitest::Test
    def setup
      @uri = 'https://api.example.com'
      @sdk_key = 'test-key'
      @path = '/some/path'

      # Reset the cache before each test
      CachingHttpConnection.reset_cache!

      # Setup the mock HTTP connection
      @http_connection = Minitest::Mock.new
      @http_connection.expect(:uri, @uri)

      # Stub the HttpConnection constructor
      HttpConnection.stub :new, @http_connection do
        @subject = CachingHttpConnection.new(@uri, @sdk_key)
      end
    end

    def test_caches_responses_with_etag_and_max_age
      response_body = 'response data'
      response = Faraday::Response.new(
        status: 200,
        body: response_body,
        response_headers: {
          'ETag' => 'abc123',
          'Cache-Control' => 'max-age=60'
        }
      )

      # Expect two calls to uri (one for each request) and one call to get
      @http_connection.expect(:uri, @uri)
      @http_connection.expect(:get, response, [@path])

      HttpConnection.stub :new, @http_connection do
        # First request should miss cache
        first_response = @subject.get(@path)
        assert_equal response_body, first_response.body
        assert_equal 'MISS', first_response.headers['X-Cache']

        # Second request should hit cache
        second_response = @subject.get(@path)
        assert_equal response_body, second_response.body
        assert_equal 'HIT', second_response.headers['X-Cache']
      end

      @http_connection.verify
    end

    def test_respects_max_age_directive
      response = Faraday::Response.new(
        status: 200,
        body: 'fresh data',
        response_headers: {
          'ETag' => 'abc123',
          'Cache-Control' => 'max-age=60'
        }
      )

      mock = Minitest::Mock.new
      def mock.uri
        'https://api.example.com'
      end

      # First request
      mock.expect(:get, response, [@path])
      # After max-age expires, new request with etag
      mock.expect(:get, response, [@path, { 'If-None-Match' => 'abc123' }])

      Timecop.freeze do
        subject = CachingHttpConnection.new(@uri, @sdk_key)
        subject.instance_variable_set('@connection', mock)

        # Initial request
        subject.get(@path)

        # Within max-age window
        Timecop.travel(59)
        cached_response = subject.get(@path)
        assert_equal 'HIT', cached_response.headers['X-Cache']

        # After max-age window
        Timecop.travel(61)
        new_response = subject.get(@path)
        assert_equal 'MISS', new_response.headers['X-Cache']
      end

      mock.verify
    end
    def test_handles_304_not_modified
      initial_response = Faraday::Response.new(
        status: 200,
        body: 'cached data',
        response_headers: { 'ETag' => 'abc123' }
      )

      not_modified_response = Faraday::Response.new(
        status: 304,
        body: '',
        response_headers: { 'ETag' => 'abc123' }
      )

      mock = Minitest::Mock.new
      def mock.uri
        'https://api.example.com'
      end

      # First request with single arg
      mock.expect(:get, initial_response, [@path])

      # Second request with both path and headers
      mock.expect(:get, not_modified_response, [@path, { 'If-None-Match' => 'abc123' }])

      subject = CachingHttpConnection.new(@uri, @sdk_key)
      subject.instance_variable_set('@connection', mock)

      # Initial request to populate cache
      first_response = subject.get(@path)
      assert_equal 'cached data', first_response.body
      assert_equal 'MISS', first_response.headers['X-Cache']

      # Subsequent request gets 304
      cached_response = subject.get(@path)
      assert_equal 'cached data', cached_response.body
      assert_equal 200, cached_response.status
      assert_equal 'HIT', cached_response.headers['X-Cache']

      mock.verify
    end

    def test_does_not_cache_no_store_responses
      response = Faraday::Response.new(
        status: 200,
        body: 'uncacheable data',
        response_headers: { 'Cache-Control' => 'no-store' }
      )

      mock = Minitest::Mock.new
      def mock.uri
        'https://api.example.com'
      end
      # Both gets with single arg
      mock.expect(:get, response, [@path])
      mock.expect(:get, response, [@path])

      subject = CachingHttpConnection.new(@uri, @sdk_key)
      subject.instance_variable_set('@connection', mock)

      2.times do
        result = subject.get(@path)
        assert_equal 'MISS', result.headers['X-Cache']
      end

      mock.verify
    end
    def test_cache_is_shared_across_instances
      HttpConnection.stub :new, @http_connection do
        instance1 = CachingHttpConnection.new(@uri, @sdk_key)
        instance2 = CachingHttpConnection.new(@uri, @sdk_key)

        assert_same instance1.class.cache, instance2.class.cache
      end
    end

    def test_cache_can_be_reset
      old_cache = CachingHttpConnection.cache
      CachingHttpConnection.reset_cache!
      refute_same CachingHttpConnection.cache, old_cache
    end

    def test_adds_if_none_match_header_when_cached
      # First response to be cached
      initial_response = Faraday::Response.new(
        status: 200,
        body: 'cached data',
        response_headers: { 'ETag' => 'abc123' }
      )

      # Second request should have If-None-Match header
      not_modified_response = Faraday::Response.new(
        status: 304,
        body: '',
        response_headers: { 'ETag' => 'abc123' }
      )

      mock = Minitest::Mock.new
      def mock.uri
        'https://api.example.com'
      end

      # First request should not have If-None-Match
      mock.expect(:get, initial_response, [@path])

      # Second request should have If-None-Match header
      mock.expect(:get, not_modified_response, [@path, { 'If-None-Match' => 'abc123' }])

      subject = CachingHttpConnection.new(@uri, @sdk_key)
      subject.instance_variable_set('@connection', mock)

      # Initial request to populate cache
      first_response = subject.get(@path)
      assert_equal 'cached data', first_response.body
      assert_equal 'MISS', first_response.headers['X-Cache']

      # Second request should use If-None-Match
      cached_response = subject.get(@path)
      assert_equal 'cached data', cached_response.body
      assert_equal 'HIT', cached_response.headers['X-Cache']

      mock.verify
    end
  end
end