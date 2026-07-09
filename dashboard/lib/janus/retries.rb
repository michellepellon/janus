# ABOUTME: Janus::Retries is the shared transient-network retry ladder for the
# ABOUTME: collectors; includers set @sleeper and wrap API calls in with_retries.

require "net/http"
require "openssl"

module Janus
  module Retries
    # Connection-level failures that cloud APIs produce routinely; each
    # wrapped call is retried through these with increasing backoff.
    TRANSIENT_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, EOFError, IOError,
      Errno::ECONNRESET, Errno::ECONNREFUSED, Errno::EPIPE, Errno::ETIMEDOUT,
      SocketError, OpenSSL::SSL::SSLError
    ].freeze

    # Seconds slept before each retry; the list length sets the retry count.
    BACKOFF_SECONDS = [1, 4, 10].freeze

    private

    # Runs the block, sleeping through BACKOFF_SECONDS between attempts on
    # transient failures; the final failure — or any non-transient one, like a
    # 4xx client error — propagates to the caller.
    def with_retries
      attempt = 0
      begin
        yield
      rescue StandardError => e
        raise unless transient?(e)
        raise if attempt >= BACKOFF_SECONDS.size

        @sleeper.call(BACKOFF_SECONDS[attempt])
        attempt += 1
        retry
      end
    end

    # Connection-level failures are always transient. API errors that carry an
    # HTTP status (Sensorpush::APIError, Janus::Weather::Error) are transient
    # for rate limiting (429) and server errors (5xx) — a client error means
    # the request itself is wrong and retrying cannot help.
    def transient?(error)
      return true if TRANSIENT_ERRORS.any? { |klass| error.is_a?(klass) }
      return false unless error.respond_to?(:status) && error.status

      error.status == 429 || (500..599).cover?(error.status)
    end
  end
end
