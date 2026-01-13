# frozen_string_literal: true

require "minitest/test_task"

Minitest::TestTask.create

desc "Start development server"
task :dev do
  sh "rackup", "-o", "localhost"
end

task default: :test
