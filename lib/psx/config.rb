# frozen_string_literal: true

require "yaml"
require "fileutils"

module PSX
  # Persistent user configuration for the SDL front-end. Lives at
  # `~/.config/psx/config.yml` (or `$PSX_CONFIG` / `$XDG_CONFIG_HOME`).
  # Stored as YAML; the in-window overlay (Tab) writes back through
  # `save!` so a rebind survives a restart.
  #
  # Unknown YAML keys are dropped silently. Unknown button names in
  # `keys:` are dropped and replaced with their defaults — a stale
  # config never breaks startup. Scancodes are stored by name
  # (e.g. `"Z"`, `"Up"`, `"Return"`) so the file stays human-editable.
  class Config
    # All 14 digital-pad buttons that are remappable. The strings here
    # are what gets stored in the YAML under `keys:`.
    BUTTONS = %w[
      up down left right
      cross circle square triangle
      start select
      l1 r1 l2 r2
    ].freeze

    DEFAULTS = {
      "target_fps" => 60,
      "frameskip" => true,
      "quicksave_path" => "tmp/quicksave.psxstate",
      "debug_snapshot_prefix" => "tmp/debug-snapshot",
      "keys" => {
        "up" => "Up",
        "down" => "Down",
        "left" => "Left",
        "right" => "Right",
        "cross" => "Z",
        "circle" => "X",
        "square" => "A",
        "triangle" => "S",
        "start" => "Return",
        "select" => "Space",
        "l1" => "Q",
        "r1" => "W",
        "l2" => "E",
        "r2" => "R"
      }.freeze
    }.freeze

    attr_accessor :target_fps, :frameskip, :quicksave_path, :debug_snapshot_prefix, :keys
    attr_reader :path

    def self.default_path
      base = ENV["XDG_CONFIG_HOME"]
      base = File.join(Dir.home, ".config") if base.nil? || base.empty?
      File.join(base, "psx", "config.yml")
    end

    # Load from `path`, or the configured default. A missing file gives
    # an in-memory config with all DEFAULTS — `save!` will write it out.
    def self.load(path: nil)
      path ||= ENV["PSX_CONFIG"]
      path = default_path if path.nil? || path.empty?
      new(path)
    end

    def initialize(path, data: nil)
      @path = path
      data ||= File.exist?(path) ? (YAML.safe_load_file(path) || {}) : {}
      data = {} unless data.is_a?(Hash)
      @target_fps           = (data["target_fps"] || DEFAULTS["target_fps"]).to_i
      @frameskip            = data.fetch("frameskip", DEFAULTS["frameskip"]) ? true : false
      @quicksave_path       = data["quicksave_path"]       || DEFAULTS["quicksave_path"]
      @debug_snapshot_prefix = data["debug_snapshot_prefix"] || DEFAULTS["debug_snapshot_prefix"]

      raw_keys = data["keys"].is_a?(Hash) ? data["keys"] : {}
      @keys = {}
      BUTTONS.each do |button|
        value = raw_keys[button]
        value = value.to_s if value.is_a?(Symbol)
        @keys[button] = (value.is_a?(String) && !value.empty?) ? value : DEFAULTS["keys"][button]
      end
    end

    # Write the current state back to `path` (creating parent dirs).
    def save!
      FileUtils.mkdir_p(File.dirname(@path))
      File.write(@path, to_yaml)
    end

    def to_h
      {
        "target_fps" => @target_fps,
        "frameskip" => @frameskip,
        "quicksave_path" => @quicksave_path,
        "debug_snapshot_prefix" => @debug_snapshot_prefix,
        "keys" => BUTTONS.to_h { |b| [b, @keys[b]] }
      }
    end

    def to_yaml
      to_h.to_yaml
    end
  end
end
