require 'dbus/systemd'

module Symbiosis
  module Monitor
    # for inspecting and altering the state of systemd services
    class SystemdService
      # default mode used when starting/stopping services
      # paraphrased from systemd dbus docs:
      #
      # replace: will start the unit and its dependencies, possibly replacing
      #         already queued jobs that conflict with this.
      # fail: will start the unit and its dependencies, but will fail if this
      #         would change an already queued job.
      # isolate: will start the unit in question and terminate all units that
      #         aren't dependencies of it.
      # ignore-dependencies:  will start a unit but ignore all its dependencies
      # ignore-requirements: will start a unit but only ignore the requirement
      #         dependencies.
      #
      # It is not recommended to make use of the latter two options.
      DEFAULT_MODE = 'replace'.freeze
      attr_reader :name

      # needs to be initialised with a :unit_name param, or will error
      def initialize(description)
        @name = description[:unit_name]
        @unit = DBus::Systemd::Unit.new(unit_file)
      end

      def running?
        active_state == 'active' || active_state == 'activating'
      end

      def start(mode = DEFAULT_MODE)
        @unit.Start mode
        running?
      end

      def stop(mode = DEFAULT_MODE)
        @unit.Stop mode
        !running?
      end

      def disable
        # 1st false means 'mask persistently', 2nd means 'don't replace
        # symlinks to other units'
        manager.MaskUnitFiles [unit_file], false
        daemon_reload
        !enabled?
      end

      def enable
        # 1st false means 'enable persistently', 2nd means 'don't force'
        manager.EnableUnitFiles [unit_file], false, false
        manager.UnmaskUnitFiles [unit_file], false
        daemon_reload
        enabled?
      end

      def enabled?
        %w[enabled linked static].include? unit_file_state
      end

      def self.systemd?
        manager.ListUnits
        return true
      rescue NoMethodError
        return false
      end

      private

      def manager
        self.class.manager
      end

      def self.manager
        @@manager ||= DBus::Systemd::Manager.new
      end

      def active_state
        states = @unit.Get(DBus::Systemd::Unit::INTERFACE, 'ActiveState')
        if states.count.zero?
          'unknown'
        else
          states.first
        end
      end

      def load_state
        states = @unit.Get(DBus::Systemd::Unit::INTERFACE, 'LoadState')
        if states.count.zero?
          'unknown'
        else
          states.first
        end
      end

      def unit_file_state
        states = @unit.Get(DBus::Systemd::Unit::INTERFACE, 'UnitFileState')
        if states.count.zero?
          'unknown'
        else
          states.first
        end
      end

      def unit_file
	"#{name}.service"
      end

      def daemon_reload
        manager.Reload
      end
    end
  end
end

# vim: set softtabstop=0 expandtab shiftwidth=2 smarttab:
