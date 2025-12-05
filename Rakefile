# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Build Swift library (.dylib)"
task "build:lib" do
  sh "swiftc -O -whole-module-optimization -lto=llvm-full -emit-library -D LIBRARY -o lib/img2png.dylib ext/img2png.swift"
end

desc "Build CLI binary"
task "build:cli" do
  mkdir_p "bin"
  sh "swiftc -O -whole-module-optimization -lto=llvm-full -parse-as-library -o bin/img2png ext/img2png.swift"
end

desc "Build both library and CLI"
task :build => ["build:lib", "build:cli"]

desc "Clean build artifacts"
task :clean do
  rm_f "lib/img2png.dylib"
  rm_f "bin/img2png"
end

task default: :build
