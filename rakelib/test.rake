# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.test_files = FileList["test/**/test_*.rb"]
end

desc "Generate coverage report"
task "coverage:report" do
  ENV["COVERAGE_DIR"] = "coverage"
  require "simplecov"
  SimpleCov.collate Dir["coverage/*/.resultset.json"]
  puts "Full coverage reports:", "* #{SimpleCov.coverage_dir}/index.html", "* #{SimpleCov.coverage_dir}/coverage.json"
end

begin
  require "rubocop/rake_task"
  RuboCop::RakeTask.new
rescue LoadError => e
  raise e unless e.path == "rubocop/rake_task"
end
