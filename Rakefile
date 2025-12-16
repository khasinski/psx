# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "spec"
  t.pattern = "spec/*_spec.rb"
  t.warning = false
end

# Native extension compilation
namespace :native do
  desc "Compile native CPU extension"
  task :compile do
    Dir.chdir("ext/psx_native") do
      ruby "extconf.rb"
      sh "make clean" rescue nil
      sh "make"
    end
    # Copy to lib directory
    ext_file = "ext/psx_native/psx_native.bundle"
    ext_file = "ext/psx_native/psx_native.so" unless File.exist?(ext_file)
    if File.exist?(ext_file)
      cp ext_file, "lib/"
      puts "Native extension compiled successfully!"
    else
      puts "Warning: Extension file not found"
    end
  end

  desc "Clean native extension"
  task :clean do
    Dir.chdir("ext/psx_native") do
      sh "make clean" rescue nil
      rm_f ["Makefile", "mkmf.log"]
    end
    rm_f ["lib/psx_native.bundle", "lib/psx_native.so"]
  end
end

desc "Compile native extension"
task compile: "native:compile"

desc "Clean all build artifacts"
task clean: "native:clean"

task default: :test
