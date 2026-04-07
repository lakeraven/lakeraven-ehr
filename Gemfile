source "https://rubygems.org"

# Specify your gem's dependencies in lakeraven-ehr.gemspec.
gemspec

# rpms-rpc is published as a tagged GitHub release but not yet pushed
# to rubygems.org. Point at the sibling checkout for local development.
# The gemspec still pins ~> 0.1 so consumers can use the published gem
# once it lands on rubygems.
gem "rpms-rpc", path: "../rpms-rpc"

gem "puma"
gem "pg"
gem "propshaft"

group :development, :test do
  gem "rubocop-rails-omakase", require: false
end
