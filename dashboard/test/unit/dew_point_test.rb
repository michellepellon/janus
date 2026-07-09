# ABOUTME: Unit tests for Janus::DewPoint — Magnus-formula dew point in °F
# ABOUTME: against published vectors, plus nil/invalid humidity guards.

require_relative "../test_helper"
require "janus/dew_point"

class DewPointTest < Minitest::Test
  def test_magnus_vectors_within_three_tenths_fahrenheit
    assert_in_delta 67.9, Janus::DewPoint.fahrenheit(temperature: 80.6, humidity: 65.0), 0.3
    assert_in_delta 72.9, Janus::DewPoint.fahrenheit(temperature: 76.0, humidity: 90.0), 0.3
    assert_in_delta 75.2, Janus::DewPoint.fahrenheit(temperature: 95.0, humidity: 53.0), 0.3
  end

  def test_saturated_air_dew_point_equals_temperature
    assert_in_delta 76.0, Janus::DewPoint.fahrenheit(temperature: 76.0, humidity: 100.0), 0.01
  end

  def test_nil_and_non_positive_humidity_return_nil
    assert_nil Janus::DewPoint.fahrenheit(temperature: 80.0, humidity: nil)
    assert_nil Janus::DewPoint.fahrenheit(temperature: 80.0, humidity: 0.0)
    assert_nil Janus::DewPoint.fahrenheit(temperature: 80.0, humidity: -5.0)
  end

  def test_nil_temperature_returns_nil
    assert_nil Janus::DewPoint.fahrenheit(temperature: nil, humidity: 50.0)
  end
end
