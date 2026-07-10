# ABOUTME: Janus::EnvFile appends KEY=value lines to a dotenv file without
# ABOUTME: clobbering anything already there, creating the file when absent.

module Janus
  module EnvFile
    module_function

    # Appends each KEY=value pair to +path+, creating the file if needed and
    # never rewriting existing content. Returns the keys that were already
    # present (dotenv gives later assignments precedence, so the appended
    # values win — but the caller may want to warn about the duplicates).
    def append(path, values)
      existing = File.exist?(path) ? File.read(path) : ""
      duplicates = values.keys.select do |key|
        existing.match?(/^#{Regexp.escape(key)}=/)
      end

      File.open(path, "a") do |file|
        file.write("\n") unless existing.empty? || existing.end_with?("\n")
        values.each { |key, value| file.write("#{key}=#{value}\n") }
      end
      duplicates
    end
  end
end
