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
    # transient network errors; the final failure propagates to the caller.
    def with_retries
      attempt = 0
      begin
        yield
      rescue *TRANSIENT_ERRORS
        raise if attempt >= BACKOFF_SECONDS.size

        @sleeper.call(BACKOFF_SECONDS[attempt])
        attempt += 1
        retry
      end
    end
  end
end
