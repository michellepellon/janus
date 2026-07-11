# ABOUTME: Janus::ScheduleRunner enforces schedules at their edges (manual
# ABOUTME: overrides win between edges) and records adherence deviation events.

require "time"
require_relative "schedules"

module Janus
  class ScheduleRunner
    # Seconds a mismatch must persist before it becomes a deviation event —
    # commands take time to confirm and humans linger at edges.
    DEFAULT_GRACE_SECONDS = 300

    # How far back the first cycle after a restart looks for the most recent
    # edge to re-assert. Beyond this an edge is stale history: adherence, not
    # enforcement, is the record of any drift.
    RESTART_LOOKBACK_SECONDS = 48 * 3600

    SOURCE = "janus"

    def initialize(schedules:, event_log:, commander:, logger_io: $stderr,
                   grace_seconds: DEFAULT_GRACE_SECONDS)
      @schedules = schedules
      @event_log = event_log
      @commander = commander
      @logger_io = logger_io
      @grace_seconds = grace_seconds
      # The last-evaluated instant, in memory only: a restart forgets it and
      # may re-fire the most recent edge (harmless — see enforce).
      @last_check = nil
      # Per-entity open mismatch episodes: entity => { since:, recorded: }.
      @mismatches = {}
    end

    # One poller cycle at local time +now+: (a) enforcement — command any
    # schedule edge crossed since the last cycle; (b) adherence — compare
    # expected against recorded state, opening/closing mismatch episodes.
    # Never raises; per-device errors are logged one line each.
    def run_cycle(now: Time.now)
      @schedules.all.each do |schedule|
        next unless schedule[:enabled]

        observed = @event_log.latest_state(entity: schedule[:entity])
        enforce(schedule, observed, now)
        track_adherence(schedule, observed, now)
      end
      @last_check = now
      nil
    end

    private

    # Edge-triggered enforcement: only an edge crossed since the last check
    # commands the device, so a manual override between edges is respected
    # until the next edge reasserts. Folding edges in order from the observed
    # state skips commands the device already satisfies and converges on the
    # final edge when several were missed.
    def enforce(schedule, observed, now)
      refire = @last_check.nil?
      current = observed && observed[:on]
      edges_due(schedule, now).each do |edge|
        next if current == edge[:on]
        # A re-fired historical edge is a repair; without a recorded state
        # there is no evidence anything needs repairing. A fresh edge always
        # commands: unknown is not "already there".
        next if refire && current.nil?

        begin
          @commander.toggle(entity: schedule[:entity], on: edge[:on])
          current = edge[:on]
        rescue StandardError => e
          @logger_io.puts "[#{Time.now.getutc.iso8601}] poller: schedule #{schedule[:entity]}: " \
                          "#{e.class}: #{e.message}"
        end
      end
    end

    # Edges to evaluate this cycle: those crossed since the last check, or —
    # on the first cycle after a restart — the single most recent edge, so a
    # restart mid-window re-asserts the schedule idempotently.
    def edges_due(schedule, now)
      return Schedules.edges_between(schedule, @last_check, now) if @last_check

      [Schedules.edges_between(schedule, now - RESTART_LOOKBACK_SECONDS, now).last].compact
    end

    # Continuous, observational adherence: a mismatch episode opens when
    # expected and recorded state disagree, records ONE deviation event once
    # the grace elapses, and closes silently on realignment. Unknown recorded
    # state is never a deviation — absence of events is unknown, not "off".
    def track_adherence(schedule, observed, now)
      entity = schedule[:entity]
      expected = Schedules.expected_on?(schedule, now)
      if observed.nil? || observed[:on] == expected
        @mismatches.delete(entity)
        return
      end

      episode = (@mismatches[entity] ||= { since: now, recorded: false })
      return if episode[:recorded] || (now - episode[:since]) < @grace_seconds

      @event_log.record(
        observed: now, source: SOURCE, entity: entity, kind: "deviation",
        payload: { expected: expected, observed: observed[:on],
                   since: episode[:since].getutc.iso8601 }
      )
      episode[:recorded] = true
    end
  end
end
