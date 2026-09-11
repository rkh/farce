# frozen_string_literal: true

desc "Compile and test for CI"
task ci: %i[clean compile] do
  ENV["FARCE_SKIP_GEM_VERIFIER"] = "true" unless ENV["FARCE_VERIFY_GEMS"] == "true"
  Rake::Task[:test].invoke
end
