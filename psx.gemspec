# frozen_string_literal: true

require_relative "lib/psx/version"

Gem::Specification.new do |spec|
  spec.name          = "psx"
  spec.version       = PSX::VERSION
  spec.authors       = ["Chris Hasiński"]
  spec.email         = ["krzysztof.hasinski@gmail.com"]

  spec.summary       = "PlayStation 1 emulator written in pure Ruby"
  spec.description   = <<~DESC
    A work-in-progress PlayStation 1 emulator written entirely in Ruby.
    Implements the MIPS R3000A CPU, GTE, GPU (software rasteriser), DMA,
    interrupts, timers, CD-ROM stub, SIO0 controller, and a minimal SPU —
    enough to boot the SCPH1001 BIOS into the Memory Card / CD-ROM shell.
    Ships an SDL2-backed front-end via the `psx` command. A BIOS image is
    not included and must be supplied by the user.
  DESC
  spec.homepage      = "https://github.com/khasinski/psx"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata = {
    "source_code_uri"   => spec.homepage,
    "bug_tracker_uri"   => "#{spec.homepage}/issues",
    "changelog_uri"     => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }

  # Only ship what's actually needed at install time: lib, exe, README,
  # LICENSE, CHANGELOG. The dev-only bin/ scripts, spec/, smoke/, .tests/,
  # any BIOS dump, and editor scratch files are explicitly excluded.
  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "README.md",
    "LICENSE",
    "CHANGELOG.md"
  ]
  spec.bindir        = "exe"
  spec.executables   = ["psx"]
  spec.require_paths = ["lib"]

  spec.add_dependency "ruby-sdl2", "~> 0.3"
  spec.add_dependency "ffi", "~> 1.16"

  spec.add_development_dependency "minitest", "~> 5"
  spec.add_development_dependency "rake", "~> 13"
end
