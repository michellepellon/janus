# ABOUTME: Janus::Store wraps a single DuckDB database file holding sensors and
# ABOUTME: readings, and serves the windowed, time-bucketed dashboard query.

require "duckdb"
require "fileutils"

module Janus
  class Store
    # time_bucket alignment origin; passed explicitly to DuckDB so Ruby-side
    # window alignment and SQL bucketing always agree.
    BUCKET_ORIGIN = Time.utc(2000, 1, 1)

    # Hard ceiling on series points per sensor for any window.
    MAX_SERIES_POINTS = 144

    # ruby-duckdb binds Time parameters by wall clock (the zone is dropped) and
    # returns TIMESTAMP columns as local-zone Time with the stored wall clock.
    # All writes therefore convert to UTC first, and all reads reinterpret the
    # returned wall clock as UTC via +as_utc+.
    def initialize(path:)
      FileUtils.mkdir_p(File.dirname(path))
      @db = DuckDB::Database.open(path)
      @conn = @db.connect
      @mutex = Mutex.new
      ensure_schema
    end

    def upsert_sensor(id:, name:, active:, battery_percentage:)
      @mutex.synchronize do
        @conn.query(<<~SQL, id, name, active, battery_percentage, Time.now.getutc)
          INSERT INTO sensors (id, name, active, battery_percentage, updated_at)
          VALUES (?, ?, ?, ?, ?)
          ON CONFLICT (id) DO UPDATE SET
            name = excluded.name,
            active = excluded.active,
            battery_percentage = excluded.battery_percentage,
            updated_at = excluded.updated_at
        SQL
      end
      nil
    end

    # Inserts samples (objects responding to observed/temperature/humidity),
    # skipping rows already present. Returns the number of rows actually
    # inserted (duplicates are not counted).
    def insert_readings(sensor_id, samples)
      @mutex.synchronize do
        samples.sum do |sample|
          observed = normalize_time(sample.observed)
          result = @conn.query(<<~SQL, sensor_id, observed, sample.temperature, sample.humidity)
            INSERT OR IGNORE INTO readings (sensor_id, observed, temperature, humidity)
            VALUES (?, ?, ?, ?)
          SQL
          result.rows_changed
        end
      end
    end

    def latest_observed(sensor_id)
      @mutex.synchronize do
        row = @conn.query(<<~SQL, sensor_id).first
          SELECT max(observed) FROM readings WHERE sensor_id = ?
        SQL
        as_utc(row&.first)
      end
    end

    # Returns one hash per sensor (ordered by name) describing the last
    # +hours+ hours ending at +now+: the most recent reading, min/max ranges,
    # and a bucket-averaged series. The window start is advanced to the next
    # bucket boundary so the series never exceeds MAX_SERIES_POINTS; buckets
    # containing no readings are omitted.
    def dashboard(hours:, now: Time.now.getutc)
      bucket_minutes, window_start = bucket_window(hours, now.getutc)

      @mutex.synchronize do
        sensor_rows = @conn.query(<<~SQL).to_a
          SELECT id, name, active, battery_percentage FROM sensors ORDER BY name
        SQL
        sensor_rows.map do |(id, name, active, battery_percentage)|
          {
            id: id,
            name: name,
            active: active,
            battery_percentage: battery_percentage,
            latest: latest_in_window(id, window_start),
            range: range_in_window(id, window_start),
            series: series_in_window(id, window_start, bucket_minutes)
          }
        end
      end
    end

    # Outside-minus-indoor temperature series over the same window and buckets
    # as +dashboard+: ascending [{t:, delta:}] where delta is the bucketed
    # average outside temperature minus the bucketed average indoor
    # temperature. Outside readings come from NWS pseudo-sensors
    # (sensor_id LIKE 'nws.%'); everything else is indoor. Buckets missing
    # either side are omitted.
    def differential(hours:, now: Time.now.getutc)
      bucket_minutes, window_start = bucket_window(hours, now.getutc)

      @mutex.synchronize do
        rows = @conn.query(<<~SQL, bucket_minutes, window_start, bucket_minutes, window_start).to_a
          WITH outside AS (
            SELECT #{BUCKET_SQL} AS bucket, avg(temperature) AS temp
            FROM readings
            WHERE sensor_id LIKE 'nws.%' AND observed >= ?
            GROUP BY bucket
          ),
          -- The indoor bucket value is a plain AVG over every indoor reading
          -- in the bucket, so rooms reporting more often weigh more; that is
          -- accurate enough for a whole-house differential.
          indoor AS (
            SELECT #{BUCKET_SQL} AS bucket, avg(temperature) AS temp
            FROM readings
            WHERE sensor_id NOT LIKE 'nws.%' AND observed >= ?
            GROUP BY bucket
          )
          SELECT outside.bucket, outside.temp - indoor.temp
          FROM outside JOIN indoor ON outside.bucket = indoor.bucket
          WHERE outside.temp IS NOT NULL AND indoor.temp IS NOT NULL
          ORDER BY outside.bucket
        SQL
        rows.map { |(bucket, delta)| { t: as_utc(bucket), delta: delta } }
      end
    end

    # Most recent outside (NWS pseudo-sensor) reading within the same window
    # as +dashboard+, or nil when there is none.
    def latest_outside(hours:, now: Time.now.getutc)
      _, window_start = bucket_window(hours, now.getutc)

      @mutex.synchronize do
        row = @conn.query(<<~SQL, window_start).first
          SELECT observed, temperature, humidity
          FROM readings
          WHERE sensor_id LIKE 'nws.%' AND observed >= ?
          ORDER BY observed DESC
          LIMIT 1
        SQL
        return nil if row.nil?

        { observed: as_utc(row[0]), temperature: row[1], humidity: row[2] }
      end
    end

    def close
      @conn.disconnect
      @db.close
      nil
    end

    # The time_bucket expression shared by every bucketed query; the origin
    # literal must match BUCKET_ORIGIN.
    BUCKET_SQL = "time_bucket(to_minutes(CAST(? AS INTEGER)), observed, TIMESTAMP '2000-01-01 00:00:00')"

    private

    # Bucket width (minutes) and aligned window start for an hours-long window
    # ending at now — the one bucketing scheme every windowed query shares.
    def bucket_window(hours, now)
      bucket_minutes = (hours * 60.0 / MAX_SERIES_POINTS).ceil
      [bucket_minutes, aligned_window_start(now - (hours * 3600), bucket_minutes * 60)]
    end

    def ensure_schema
      @mutex.synchronize do
        @conn.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS sensors (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            active BOOLEAN,
            battery_percentage DOUBLE,
            updated_at TIMESTAMP
          )
        SQL
        @conn.query(<<~SQL)
          CREATE TABLE IF NOT EXISTS readings (
            sensor_id TEXT NOT NULL,
            observed TIMESTAMP NOT NULL,
            temperature DOUBLE,
            humidity DOUBLE,
            PRIMARY KEY (sensor_id, observed)
          )
        SQL
      end
    end

    # Callers hold @mutex.
    def latest_in_window(sensor_id, window_start)
      row = @conn.query(<<~SQL, sensor_id, window_start).first
        SELECT observed, temperature, humidity
        FROM readings
        WHERE sensor_id = ? AND observed >= ?
        ORDER BY observed DESC
        LIMIT 1
      SQL
      return nil if row.nil?

      { observed: as_utc(row[0]), temperature: row[1], humidity: row[2] }
    end

    # Callers hold @mutex.
    def range_in_window(sensor_id, window_start)
      row = @conn.query(<<~SQL, sensor_id, window_start).first
        SELECT min(temperature), max(temperature), min(humidity), max(humidity)
        FROM readings
        WHERE sensor_id = ? AND observed >= ?
      SQL
      return nil if row.nil? || row.all?(&:nil?)

      { temp_min: row[0], temp_max: row[1], hum_min: row[2], hum_max: row[3] }
    end

    # Callers hold @mutex.
    def series_in_window(sensor_id, window_start, bucket_minutes)
      rows = @conn.query(<<~SQL, bucket_minutes, sensor_id, window_start).to_a
        SELECT #{BUCKET_SQL} AS bucket,
               avg(temperature), avg(humidity)
        FROM readings
        WHERE sensor_id = ? AND observed >= ?
        GROUP BY bucket
        ORDER BY bucket
      SQL
      rows.map { |(bucket, temp, hum)| { t: as_utc(bucket), temp: temp, hum: hum } }
    end

    # Advances a window start to the next bucket boundary (strictly later),
    # keyed to BUCKET_ORIGIN, so [start, now] spans at most MAX_SERIES_POINTS
    # buckets.
    def aligned_window_start(raw_start, bucket_seconds)
      offset = (raw_start - BUCKET_ORIGIN).to_i
      BUCKET_ORIGIN + (((offset / bucket_seconds) + 1) * bucket_seconds)
    end

    def normalize_time(value)
      value.to_time.getutc
    end

    def as_utc(time)
      return nil if time.nil?

      Time.utc(time.year, time.mon, time.day, time.hour, time.min, time.sec, time.usec)
    end
  end
end
