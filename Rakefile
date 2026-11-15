require "bundler/gem_tasks"
require "rspec/core/rake_task"
require "standard/rake"

RSpec::Core::RakeTask.new(:spec)

task default: %i[spec standard]

namespace :tables do
  desc "Print what the current IT 2025.002 tables (cClassTrib, cCredPres) would change, without writing"
  task :check do
    ruby "script/update_tables", "--only", "classifications,cred_pres", "--diff"
  end
end
