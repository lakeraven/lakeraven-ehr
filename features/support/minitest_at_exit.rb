# frozen_string_literal: true

# env.rb loads test_helper, which installs Minitest's at_exit run. After a green
# Cucumber run that hook parses Cucumber's own arguments, rejects --tags, and
# exits 1. Clearing ARGV first keeps the exit code Cucumber chose: at_exit hooks
# run last-registered first, and Minitest skips its run after a failure.
at_exit { ARGV.clear }
