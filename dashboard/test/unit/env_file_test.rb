# ABOUTME: Unit tests for Janus::EnvFile — create-or-append semantics, trailing
# ABOUTME: newline handling, and duplicate-key reporting without clobbering.

require_relative "../test_helper"
require "janus/env_file"
require "tmpdir"

class EnvFileTest < Minitest::Test
  include JanusTestHelpers

  def with_env_path(&block)
    Dir.mktmpdir("janus-envfile") { |dir| block.call(File.join(dir, ".env")) }
  end

  def test_creates_the_file_when_absent
    with_env_path do |path|
      duplicates = Janus::EnvFile.append(path, "HUE_BRIDGE_IP" => "10.0.0.7", "HUE_APP_KEY" => "k")
      assert_equal [], duplicates
      assert_equal "HUE_BRIDGE_IP=10.0.0.7\nHUE_APP_KEY=k\n", File.read(path)
    end
  end

  def test_appends_without_touching_existing_content
    with_env_path do |path|
      File.write(path, "SENSORPUSH_USERNAME=u@example.com\n")
      Janus::EnvFile.append(path, "HUE_BRIDGE_IP" => "10.0.0.7")
      assert_equal "SENSORPUSH_USERNAME=u@example.com\nHUE_BRIDGE_IP=10.0.0.7\n", File.read(path)
    end
  end

  def test_inserts_a_newline_when_the_file_lacks_a_trailing_one
    with_env_path do |path|
      File.write(path, "SENSORPUSH_USERNAME=u@example.com")
      Janus::EnvFile.append(path, "HUE_APP_KEY" => "k")
      assert_equal "SENSORPUSH_USERNAME=u@example.com\nHUE_APP_KEY=k\n", File.read(path)
    end
  end

  def test_reports_keys_that_were_already_present
    with_env_path do |path|
      File.write(path, "HUE_BRIDGE_IP=10.0.0.1\n")
      duplicates = Janus::EnvFile.append(path, "HUE_BRIDGE_IP" => "10.0.0.7", "HUE_APP_KEY" => "k")
      assert_equal ["HUE_BRIDGE_IP"], duplicates
      # The original line survives; the appended value wins under dotenv.
      content = File.read(path)
      assert_includes content, "HUE_BRIDGE_IP=10.0.0.1\n"
      assert_includes content, "HUE_BRIDGE_IP=10.0.0.7\n"
    end
  end
end
