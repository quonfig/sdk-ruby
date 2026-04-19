# frozen_string_literal: true

module Quonfig
  class CachingHttpConnection
    CACHE_SIZE = 2.freeze
    CacheEntry = Struct.new(:data, :etag, :expires_at)

    class << self
      def cache
        @cache ||= FixedSizeHash.new(CACHE_SIZE)
      end

      def reset_cache!
        @cache = FixedSizeHash.new(CACHE_SIZE)
      end
    end

    def initialize(uri, api_key)
      @connection = HttpConnection.new(uri, api_key)
    end

    def get(path)
      now = Time.now.to_i
      cache_key = "#{@connection.uri}#{path}"
      cached = self.class.cache[cache_key]

      # Check if we have a valid cached response
      if cached&.data && cached.expires_at && now < cached.expires_at
        return Faraday::Response.new(
          status: 200,
          body: cached.data,
          response_headers: {
            'ETag' => cached.etag,
            'X-Cache' => 'HIT',
            'X-Cache-Expires-At' => cached.expires_at.to_s
          }
        )
      end

      # Make request with conditional GET if we have an ETag
      response = if cached&.etag
                   @connection.get(path, { 'If-None-Match' => cached.etag })
                 else
                   @connection.get(path)
                 end

      # Handle 304 Not Modified
      if response.status == 304 && cached&.data
        return Faraday::Response.new(
          status: 200,
          body: cached.data,
          response_headers: {
            'ETag' => cached.etag,
            'X-Cache' => 'HIT',
            'X-Cache-Expires-At' => cached.expires_at.to_s
          }
        )
      end

      # Parse caching headers
      cache_control = response.headers['Cache-Control'].to_s
      etag = response.headers['ETag']

      # Always add X-Cache header
      response.headers['X-Cache'] = 'MISS'

      # Don't cache if no-store is present
      return response if cache_control.include?('no-store')

      # Calculate expiration
      max_age = cache_control.match(/max-age=(\d+)/)&.captures&.first&.to_i
      expires_at = max_age ? now + max_age : nil

      # Cache the response if we have caching headers
      if etag || expires_at
        self.class.cache[cache_key] = CacheEntry.new(
          response.body,
          etag,
          expires_at
        )
      end

      response
    end

    # Delegate other methods to the underlying connection
    def post(path, body)
      @connection.post(path, body)
    end

    def uri
      @connection.uri
    end
  end
end