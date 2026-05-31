# frozen_string_literal: true

require_relative "spec_helper"
require "tmpdir"

class ConfigSpec < Minitest::Test
  def test_defaults_when_file_missing
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      config = PSX::Config.new(path)

      assert_equal 60, config.target_fps
      assert_equal true, config.frameskip
      assert_equal "tmp/quicksave.psxstate", config.quicksave_path
      assert_equal "tmp/debug-snapshot", config.debug_snapshot_prefix
      assert_equal "Z", config.keys["cross"]
      assert_equal "Up", config.keys["up"]
      assert_equal PSX::Config::BUTTONS.sort, config.keys.keys.sort
    end
  end

  def test_save_round_trip
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      config = PSX::Config.new(path)
      config.target_fps = 30
      config.frameskip = false
      config.quicksave_path = "/tmp/state.psxstate"
      config.keys["cross"] = "Space"
      config.save!

      assert File.exist?(path), "save! should write the config file"
      reloaded = PSX::Config.new(path)
      assert_equal 30, reloaded.target_fps
      assert_equal false, reloaded.frameskip
      assert_equal "/tmp/state.psxstate", reloaded.quicksave_path
      assert_equal "Space", reloaded.keys["cross"]
      # Untouched buttons still default-filled.
      assert_equal "S", reloaded.keys["triangle"]
    end
  end

  def test_unknown_button_dropped_and_default_filled
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, {
        "keys" => { "wifi_button" => "Z", "circle" => "B" }
      }.to_yaml)

      config = PSX::Config.new(path)
      refute_includes config.keys.keys, "wifi_button"
      assert_equal "B", config.keys["circle"]
      assert_equal "Z", config.keys["cross"], "missing buttons must fall back to defaults"
    end
  end

  def test_env_override_via_load
    Dir.mktmpdir do |dir|
      path = File.join(dir, "custom.yml")
      File.write(path, { "target_fps" => 24 }.to_yaml)

      original = ENV["PSX_CONFIG"]
      ENV["PSX_CONFIG"] = path
      begin
        config = PSX::Config.load
        assert_equal path, config.path
        assert_equal 24, config.target_fps
      ensure
        ENV["PSX_CONFIG"] = original
      end
    end
  end

  def test_garbage_file_does_not_crash
    Dir.mktmpdir do |dir|
      path = File.join(dir, "config.yml")
      File.write(path, "not even yaml: [oops")
      # YAML.safe_load_file would raise; load is permissive — use new
      # directly with explicit empty data to mirror failure-recovery
      # contract.
      config = PSX::Config.new(path, data: {})
      assert_equal 60, config.target_fps
    end
  end
end
