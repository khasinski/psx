# frozen_string_literal: true

require_relative "spec_helper"

# Display.new opens an SDL2 window, which we don't want in unit tests.
# These cases exercise the pure class methods that translate between
# scancode names (as stored in the YAML config) and SDL2 scancodes.
class DisplayKeysSpec < Minitest::Test
  def test_scancode_for_letter
    assert_equal SDL2::Key::Scan::Z, PSX::Display.scancode_for("Z")
    assert_equal SDL2::Key::Scan::Z, PSX::Display.scancode_for("z")
  end

  def test_scancode_for_named_keys
    assert_equal SDL2::Key::Scan::UP,     PSX::Display.scancode_for("Up")
    assert_equal SDL2::Key::Scan::DOWN,   PSX::Display.scancode_for("Down")
    assert_equal SDL2::Key::Scan::RETURN, PSX::Display.scancode_for("Return")
    assert_equal SDL2::Key::Scan::RETURN, PSX::Display.scancode_for("Enter")
    assert_equal SDL2::Key::Scan::SPACE,  PSX::Display.scancode_for("Space")
  end

  def test_scancode_for_unknown_is_nil
    assert_nil PSX::Display.scancode_for("HyperdriveButton")
    assert_nil PSX::Display.scancode_for("")
    assert_nil PSX::Display.scancode_for(nil)
  end

  def test_name_for_round_trip
    [
      SDL2::Key::Scan::Z,
      SDL2::Key::Scan::A,
      SDL2::Key::Scan::UP,
      SDL2::Key::Scan::RETURN,
      SDL2::Key::Scan::SPACE
    ].each do |sc|
      name = PSX::Display.name_for(sc)
      refute_nil name, "name_for(#{sc}) should not be nil"
      assert_equal sc, PSX::Display.scancode_for(name),
                   "scancode_for(name_for(#{sc})) must round-trip"
    end
  end
end
