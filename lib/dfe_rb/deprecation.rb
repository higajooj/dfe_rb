module DfeRb
  # Notices of what the gem will stop offering because SEFAZ stops accepting it. Each one is
  # written once per process to $stderr, as "[dfe_rb] DEPRECATION: ...", and names the NT and
  # the date that retires the feature. The README's "Deprecations" lists them all.
  #
  #   DfeRb::Deprecation.silenced = true   # no notices (a test suite, say)
  module Deprecation
    @mutex = Mutex.new
    @seen = {}
    @silenced = false

    class << self
      attr_accessor :silenced

      # Writes `message` unless this `id` was written already or notices are silenced.
      def warn(id, message)
        return if silenced

        first = @mutex.synchronize { @seen[id] ? false : (@seen[id] = true) }
        Kernel.warn("[dfe_rb] DEPRECATION: #{message}") if first
      end

      # Forgets which notices were written, so each is written again.
      def reset!
        @mutex.synchronize { @seen.clear }
      end
    end
  end
end
