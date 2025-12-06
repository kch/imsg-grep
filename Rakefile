# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "test"
  t.libs << "lib"
  t.test_files = FileList["test/**/*_test.rb"]
end

desc "Build Swift library (.dylib)"
task "build:lib" do
  sh "swiftc -O -whole-module-optimization -lto=llvm-full -emit-library -D LIBRARY -target x86_64-apple-macosx11.0 -o lib/img2png_x86_64.dylib ext/img2png.swift"
  sh "swiftc -O -whole-module-optimization -lto=llvm-full -emit-library -D LIBRARY -target arm64-apple-macosx11.0 -o lib/img2png_arm64.dylib ext/img2png.swift"
  sh "lipo -create lib/img2png_x86_64.dylib lib/img2png_arm64.dylib -output lib/img2png.dylib"
  rm_f "lib/img2png_x86_64.dylib"
  rm_f "lib/img2png_arm64.dylib"
end

desc "Build CLI binary"
task "build:cli" do
  mkdir_p "bin"
  sh "swiftc -O -whole-module-optimization -lto=llvm-full -parse-as-library -target x86_64-apple-macosx11.0 -o bin/img2png_x86_64 ext/img2png.swift"
  sh "swiftc -O -whole-module-optimization -lto=llvm-full -parse-as-library -target arm64-apple-macosx11.0 -o bin/img2png_arm64 ext/img2png.swift"
  sh "lipo -create bin/img2png_x86_64 bin/img2png_arm64 -output bin/img2png"
  rm_f "bin/img2png_x86_64"
  rm_f "bin/img2png_arm64"
end

desc "Build both library and CLI"
task :build => ["build:lib", "build:cli"]

desc "Clean build artifacts"
task :clean do
  rm_f "lib/img2png.dylib"
  rm_f "bin/img2png"
end

task default: :build
