# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "spec"
  t.pattern = "spec/*_spec.rb"
  t.warning = false
end

namespace :test do
  Rake::TestTask.new(:gpu_regressions) do |t|
    t.libs << "lib" << "spec"
    t.pattern = "spec/gpu_regression_spec.rb"
    t.warning = false
  end
end

task default: :test
