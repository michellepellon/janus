# ABOUTME: Shared minitest setup for the dashboard backend test suite.
# ABOUTME: Provides a tmp-dir helper so each test gets an isolated DuckDB file.

ENV["RACK_ENV"] = "test"

require "minitest/autorun"
require "tmpdir"

module JanusTestHelpers
  # Yields a path (inside a throwaway tmp dir) suitable for a DuckDB file.
  # The directory and everything in it are removed when the block returns.
  def with_tmp_db_path
    Dir.mktmpdir("janus-test") do |dir|
      yield File.join(dir, "janus.duckdb")
    end
  end

  # Captures $stderr during the block; returns [block_result, captured_string].
  def capture_stderr
    require "stringio"
    old = $stderr
    io = StringIO.new
    $stderr = io
    result = yield
    [result, io.string]
  ensure
    $stderr = old
  end
end
