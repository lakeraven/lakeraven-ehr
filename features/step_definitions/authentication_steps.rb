# frozen_string_literal: true

Given("the authentication service is available") do
  @auth_service = Lakeraven::EHR::AuthenticationService.new
end

When("I login as {string} with password {string}") do |username, password|
  @auth_result = @auth_service.authenticate(access_code: username, verify_code: password)

  if @auth_result.success?
    @current_user = Lakeraven::EHR::CurrentUser.new(@auth_result.value)
    @logged_in = true
  else
    @error_message = @auth_result.error
    @logged_in = false
  end
end

Then("I should be logged in successfully") do
  assert @logged_in, "Expected to be logged in but was not. Error: #{@error_message}"
end

Then("I should not be logged in") do
  refute @logged_in, "Expected to not be logged in but was"
end

Then("my user type should be {string}") do |user_type|
  assert_equal user_type, @current_user.user_type
end

Then("I should see an authentication error {string}") do |message|
  assert @error_message.to_s.include?(message),
    "Expected error message to include '#{message}' but got '#{@error_message}'"
end

# Role login shortcuts
Given("I am logged in as a provider") do
  setup_user_with_role("provider")
end

Given("I am logged in as a nurse") do
  setup_user_with_role("nurse")
end

Given("I am logged in as a clerk") do
  setup_user_with_role("clerk")
end

Given("I am logged in as a case_manager") do
  setup_user_with_role("case_manager")
end

Given("I am logged in as a {word} with security key {string}") do |role, key_name|
  setup_user_with_role(role, [ key_name ])
end

Given("I am logged in as a {word} without security keys") do |role|
  setup_user_with_role(role, [])
end

Given("I am not logged in") do
  @logged_in = false
  @current_user = nil
end

When("I log out") do
  @current_user = nil
  @logged_in = false
end

Then("I should be logged out") do
  refute @logged_in, "Expected to be logged out"
  assert_nil @current_user, "Expected current_user to be nil"
end

# Permission checks
Then("I should have permission to {string}") do |permission|
  assert @current_user.can?(permission.to_sym),
    "Expected user (#{@current_user.user_type}) to have permission '#{permission}' but did not"
end

Then("I should not have permission to {string}") do |permission|
  refute @current_user.can?(permission.to_sym),
    "Expected user (#{@current_user.user_type}) to NOT have permission '#{permission}' but did"
end

# Security key checks
Then("I should be able to approve CHS referrals") do
  assert @current_user.can_approve_chs?, "Expected user to be able to approve CHS referrals"
end

Then("I should not be able to approve CHS referrals") do
  refute @current_user.can_approve_chs?, "Expected user to NOT be able to approve CHS referrals"
end

Then("I should be able to process CHS claims") do
  assert @current_user.can_process_chs?, "Expected user to be able to process CHS claims"
end

Then("I should be able to manage consults") do
  assert @current_user.can_manage_consults?, "Expected user to be able to manage consults"
end

Then("I should not have a current user") do
  assert_nil @current_user, "Expected no current user"
end

# Helper
def setup_user_with_role(role, security_keys = nil)
  duz = case role
  when "provider" then "99999"
  when "nurse" then "99998"
  when "clerk" then "99997"
  when "case_manager" then "99996"
  else "99995"
  end

  attrs = { duz: duz, name: "TEST,#{role.upcase}", user_type: role }
  attrs[:security_keys] = RpmsRpc::SecurityKeys.symbolize(security_keys) if security_keys

  @current_user = Lakeraven::EHR::CurrentUser.new(attrs)
  @logged_in = true
end
