# ABOUTME: Janus::DewPoint computes dew point in °F from air temperature (°F)
# ABOUTME: and relative humidity (%) via the Magnus approximation.

module Janus
  module DewPoint
    # Magnus coefficients (Sonntag 1990), valid for ordinary outdoor
    # temperatures; the formula works in °C so we convert at the edges.
    MAGNUS_B = 17.62
    MAGNUS_C = 243.12

    # Dew point in °F, or nil when humidity is missing or non-positive
    # (log of zero) or temperature is missing.
    def self.fahrenheit(temperature:, humidity:)
      return nil if temperature.nil? || humidity.nil? || humidity <= 0

      t_c = (temperature - 32.0) * 5.0 / 9.0
      gamma = Math.log(humidity / 100.0) + (MAGNUS_B * t_c) / (MAGNUS_C + t_c)
      td_c = (MAGNUS_C * gamma) / (MAGNUS_B - gamma)
      (td_c * 9.0 / 5.0) + 32.0
    end
  end
end
