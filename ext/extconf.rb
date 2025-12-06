#!/usr/bin/env ruby

require "mkmf"

# Check if dylib already exists
dylib_path = File.join *%W[ #{File.dirname __FILE__} .. lib imsg-grep images img2png.dylib ]
if File.exist?(dylib_path)
  # Create no-op Makefile since dylib already exists
  File.open("Makefile", "w") do |f|
    f.puts <<~MAKEFILE
      SHELL = /bin/sh

      all:
      \t@echo "dylib already exists, skipping build"

      install:
      \t@echo "dylib already exists, skipping install"

      clean:

      distclean:
      \trm -f Makefile

      .PHONY: all install clean distclean
    MAKEFILE
  end
  exit 0
end

# Check for explicit disable via environment variable
images_disabled = %w[0 no false].include?(ENV['IMSGGREP_IMAGES']&.downcase)

# Check build requirements

is_darwin    = RUBY_PLATFORM.include?("darwin")
found_swiftc = find_executable("swiftc")

has_requirements = is_darwin && found_swiftc

if has_requirements
  # Create Swift compilation Makefile
  File.open("Makefile", "w") do |f|
    f.puts <<~MAKEFILE
      SHELL = /bin/sh

      DLLIB = img2png.dylib

      all: $(DLLIB)

      $(DLLIB): img2png.swift
      \tswiftc -O -whole-module-optimization -lto=llvm-full -emit-library -D LIBRARY -o $(DLLIB) img2png.swift

      install: $(DLLIB)
      \tmkdir -p $(sitearchdir)/imsg-grep/images
      \tcp $(DLLIB) $(sitearchdir)/imsg-grep/images/$(DLLIB)

      clean:
      \trm -f $(DLLIB)

      distclean: clean
      \trm -f Makefile

      .PHONY: all install clean distclean
    MAKEFILE
  end
elsif images_disabled
  # User explicitly disabled image support
  File.open("Makefile", "w") do |f|
    f.puts <<~MAKEFILE
      SHELL = /bin/sh

      all:
      \t@echo "Image processing disabled via IMSGGREP_IMAGES environment variable"

      install:
      \t@echo "Image processing disabled via IMSGGREP_IMAGES environment variable"

      clean:

      distclean:
      \trm -f Makefile

      .PHONY: all install clean distclean
    MAKEFILE
  end
else
  # Requirements not met - show helpful error and fail
  $stderr.puts "ERROR: img2png extension build requirements not met:"
  $stderr.puts "  - Requires macOS (current platform: #{RUBY_PLATFORM})" unless is_darwin
  $stderr.puts "  - Requires swiftc (install Xcode or Swift toolchain)" unless found_swiftc
  $stderr.puts ""
  $stderr.puts "To build without image support, set:"
  $stderr.puts "  export IMSGGREP_IMAGES=0"
  $stderr.puts ""

  abort "Build failed due to missing requirements"
end
