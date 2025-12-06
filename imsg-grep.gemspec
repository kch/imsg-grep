# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name     = "imsg-grep"
  spec.version  = IO.read("#{__dir__}/lib/imsg-grep/VERSION").chomp
  spec.authors  = ["Caio Chassot"]
  spec.email    = ["dev@caiochassot.com"]
  spec.summary  = "iMessage database search"
  spec.homepage = "https://github.com/kch/imsg-grep"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.4.0"
  spec.platform = "darwin"

  spec.files = Dir[
    "lib/**/VERSION",
    "lib/**/*.rb",
    "lib/**/*.dylib",
    "ext/**/*.swift",
    "bin/*",
    "doc/*",
    "README.md",
    "LICENSE*"
  ]

  spec.bindir        = "bin"
  spec.executables   = ["imsg-grep"]
  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/extconf.rb"]

  spec.add_dependency "ffi", "~> 1.17"
  spec.add_dependency "sqlite3", "~> 2.8"
  spec.add_dependency "rainbow", "~> 3.1"
  spec.add_dependency "strop", "~> 0.4"
  spec.add_dependency "concurrent-ruby", "~> 1.3"

  spec.add_development_dependency "minitest", "~> 5.26"
  spec.add_development_dependency "rake", "~> 13.0"
end
