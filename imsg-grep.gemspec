# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name     = "imsg-grep"
  spec.version  = "0.1.0"
  spec.authors  = ["Author Name"]
  spec.email    = ["author@example.com"]
  spec.summary  = "iMessage database search and image processing"
  spec.homepage = "https://github.com/example/imsg-grep"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0.0"
  spec.platform = "darwin"

  spec.files = Dir[
    "lib/**/*.rb",
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

  spec.add_development_dependency "minitest", "~> 5.26"
  spec.add_development_dependency "rake", "~> 13.0"
end
