# frozen_string_literal: true

require "mkmf"

# Optimization flags
$CFLAGS << " -O3 -march=native"

# Create Makefile
create_makefile("psx_native")
