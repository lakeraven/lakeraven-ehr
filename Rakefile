require "bundler/setup"

APP_RAKEFILE = File.expand_path("test/dummy/Rakefile", __dir__)
load "rails/tasks/engine.rake"

require "bundler/gem_tasks"

# Alias `rake test` to `rake app:test` so the gem follows the
# same convention as rpms-rpc and the rest of the Lakeraven repos.
desc "Run engine tests"
task test: "app:test"

task default: :test
