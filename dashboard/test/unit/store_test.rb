# ABOUTME: Unit tests for Janus::Store — schema, upserts, idempotent reading
# ABOUTME: inserts, latest_observed, and the windowed/bucketed dashboard query.

require_relative "../test_helper"
require "janus/store"

class StoreTest < Minitest::Test
  include JanusTestHelpers

  Reading = Data.define(:observed, :temperature, :humidity)

  def readings(*rows)
    rows.map { |(t, temp, hum)| Reading.new(observed: t, temperature: temp, humidity: hum) }
  end

  def test_schema_is_idempotent_across_reopens
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
      store.close

      reopened = Janus::Store.new(path: path)
      rows = reopened.dashboard(hours: 24)
      assert_equal 1, rows.size
      assert_equal "Attic", rows.first[:name]
      reopened.close
    end
  end

  def test_creates_parent_directory
    with_tmp_db_path do |path|
      nested = File.join(File.dirname(path), "a", "b", "janus.duckdb")
      store = Janus::Store.new(path: nested)
      assert File.exist?(nested)
      store.close
    end
  end

  def test_upsert_sensor_updates_existing_row
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
      store.upsert_sensor(id: "s1", name: "Attic South", active: false, battery_percentage: 85.5)

      rows = store.dashboard(hours: 24)
      assert_equal 1, rows.size
      row = rows.first
      assert_equal "Attic South", row[:name]
      assert_equal false, row[:active]
      assert_in_delta 85.5, row[:battery_percentage]
      store.close
    end
  end

  def test_insert_readings_is_idempotent_and_returns_inserted_count
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
      batch = readings(
        [Time.utc(2026, 7, 7, 10, 0, 0), 20.0, 40.0],
        [Time.utc(2026, 7, 7, 10, 1, 0), 21.0, 41.0],
        [Time.utc(2026, 7, 7, 10, 2, 0), 22.0, 42.0]
      )
      assert_equal 3, store.insert_readings("s1", batch)
      assert_equal 0, store.insert_readings("s1", batch)

      row = store.dashboard(hours: 24, now: Time.utc(2026, 7, 7, 12, 0, 0)).first
      assert_in_delta 20.0, row[:range][:temp_min]
      assert_in_delta 22.0, row[:range][:temp_max]
      store.close
    end
  end

  def test_insert_readings_accepts_datetime_observed
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      dt = DateTime.parse("2026-07-07T10:00:00.000Z")
      sample = Reading.new(observed: dt, temperature: 20.0, humidity: 40.0)
      assert_equal 1, store.insert_readings("s1", [sample])
      assert_equal Time.utc(2026, 7, 7, 10, 0, 0), store.latest_observed("s1")
      store.close
    end
  end

  def test_latest_observed_returns_utc_time_or_nil
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      assert_nil store.latest_observed("s1")

      store.insert_readings("s1", readings(
        [Time.utc(2026, 7, 7, 10, 0, 0), 20.0, 40.0],
        [Time.utc(2026, 7, 7, 11, 30, 0), 21.0, 41.0]
      ))
      latest = store.latest_observed("s1")
      assert_equal Time.utc(2026, 7, 7, 11, 30, 0), latest
      assert_predicate latest, :utc?
      store.close
    end
  end

  def test_dashboard_orders_sensors_by_name
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "b", name: "Bedroom", active: true, battery_percentage: 50.0)
      store.upsert_sensor(id: "a", name: "Attic", active: true, battery_percentage: 50.0)
      store.upsert_sensor(id: "k", name: "Kitchen", active: true, battery_percentage: 50.0)

      names = store.dashboard(hours: 24).map { |row| row[:name] }
      assert_equal %w[Attic Bedroom Kitchen], names
      store.close
    end
  end

  def test_dashboard_window_filtering_latest_range_and_bucket_averaging
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
      now = Time.utc(2026, 7, 7, 12, 0, 0)
      store.insert_readings("s1", readings(
        [Time.utc(2026, 7, 6, 11, 0, 0), 99.0, 99.0],   # outside 24h window
        [Time.utc(2026, 7, 7, 10, 1, 0), 20.0, 40.0],   # bucket 10:00
        [Time.utc(2026, 7, 7, 10, 4, 0), 22.0, 50.0],   # bucket 10:00
        [Time.utc(2026, 7, 7, 10, 15, 0), 30.0, 60.0],  # bucket 10:10
        [Time.utc(2026, 7, 7, 11, 30, 0), 25.0, 55.0]   # bucket 11:30
      ))

      row = store.dashboard(hours: 24, now: now).first

      assert_equal Time.utc(2026, 7, 7, 11, 30, 0), row[:latest][:observed]
      assert_in_delta 25.0, row[:latest][:temperature]
      assert_in_delta 55.0, row[:latest][:humidity]

      assert_in_delta 20.0, row[:range][:temp_min]
      assert_in_delta 30.0, row[:range][:temp_max]
      assert_in_delta 40.0, row[:range][:hum_min]
      assert_in_delta 60.0, row[:range][:hum_max]

      series = row[:series]
      assert_equal [
        Time.utc(2026, 7, 7, 10, 0, 0),
        Time.utc(2026, 7, 7, 10, 10, 0),
        Time.utc(2026, 7, 7, 11, 30, 0)
      ], series.map { |pt| pt[:t] }, "empty buckets must be omitted and order ascending"
      assert series.all? { |pt| pt[:t].utc? }

      first = series.first
      assert_in_delta 21.0, first[:temp]
      assert_in_delta 45.0, first[:hum]
      assert_in_delta 30.0, series[1][:temp]
      store.close
    end
  end

  def test_dashboard_includes_sensor_with_no_readings_in_window
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
      store.insert_readings("s1", readings([Time.utc(2020, 1, 1), 20.0, 40.0]))

      row = store.dashboard(hours: 24, now: Time.utc(2026, 7, 7, 12, 0, 0)).first
      assert_equal "s1", row[:id]
      assert_nil row[:latest]
      assert_nil row[:range]
      assert_equal [], row[:series]
      store.close
    end
  end

  def test_dashboard_series_never_exceeds_144_points_for_each_allowed_window
    with_tmp_db_path do |path|
      store = Janus::Store.new(path: path)
      store.upsert_sensor(id: "s1", name: "Attic", active: true, battery_percentage: 90.0)
      origin = Time.utc(2000, 1, 1)

      [24, 72, 168, 720].each do |hours|
        bucket_seconds = (hours * 3600.0 / 144).ceil
        # Align "now" to a bucket boundary so a reading can land in every
        # candidate bucket including the one containing "now" itself.
        now = origin + (((Time.utc(2026, 7, 7, 12, 0, 0) - origin).to_i / bucket_seconds) * bucket_seconds)
        batch = (0..144).map do |k|
          Reading.new(observed: now - (k * bucket_seconds), temperature: 20.0, humidity: 40.0)
        end
        store.insert_readings("s1", batch)

        series = store.dashboard(hours: hours, now: now).first[:series]
        assert_operator series.size, :<=, 144, "hours=#{hours} produced #{series.size} points"
        assert_operator series.size, :>=, 140, "hours=#{hours} series suspiciously sparse"
      end
      store.close
    end
  end
end
