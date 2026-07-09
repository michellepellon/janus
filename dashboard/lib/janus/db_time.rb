# ABOUTME: Shared DuckDB time convention — writes convert to UTC first, reads
# ABOUTME: reinterpret the returned wall clock as UTC (the gem drops zones).

module Janus
  # ruby-duckdb binds Time parameters by wall clock (the zone is dropped) and
  # returns TIMESTAMP columns as local-zone Time with the stored wall clock.
  # Every table owner therefore converts to UTC before writing and repairs the
  # zone after reading, through these two helpers.
  module DbTime
    private

    def normalize_time(value)
      value.to_time.getutc
    end

    def as_utc(time)
      return nil if time.nil?

      Time.utc(time.year, time.mon, time.day, time.hour, time.min, time.sec, time.usec)
    end
  end
end
