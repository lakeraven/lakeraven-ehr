# frozen_string_literal: true

When("I GET the SMART discovery document") do
  get "/lakeraven-ehr/.well-known/smart-configuration"
end

Then("the discovery document advertises an authorization_endpoint") do
  assert parsed_body["authorization_endpoint"].to_s.include?("/oauth/authorize")
end

Then("the discovery document advertises a token_endpoint") do
  assert parsed_body["token_endpoint"].to_s.include?("/oauth/token")
end

Then("the discovery document lists S256 as a code_challenge_method") do
  assert_includes parsed_body["code_challenge_methods_supported"], "S256"
end

Then("the discovery document lists {string} in scopes_supported") do |scope|
  assert_includes parsed_body["scopes_supported"], scope
end

Then("the discovery document lists {string} in capabilities") do |capability|
  assert_includes parsed_body["capabilities"], capability
end

When("I POST to the OAuth token endpoint with no parameters") do
  post "/lakeraven-ehr/oauth/token"
end

Then("the response status is 400 or 401") do
  assert [ 400, 401 ].include?(last_response.status), "got #{last_response.status}"
end

Then("the response body mentions an OAuth error") do
  body = parsed_body
  assert body.key?("error") || body.key?("error_description"),
    "expected an OAuth error response, got #{body.inspect}"
end

When("I GET the OAuth authorize endpoint with no parameters") do
  get "/lakeraven-ehr/oauth/authorize"
end

Then("the response is not a 404") do
  refute_equal 404, last_response.status
end

Given('a confidential OAuth client is registered with scopes {string}') do |scopes|
  @oauth_app = Doorkeeper::Application.create!(
    name: "cucumber test client",
    redirect_uri: "https://example.test/callback",
    scopes: scopes,
    confidential: true
  )
  @client_secret = @oauth_app.plaintext_secret || @oauth_app.secret
end

When('I POST to the OAuth token endpoint with grant_type {string} and the client credentials') do |grant_type|
  post "/lakeraven-ehr/oauth/token", {
    grant_type: grant_type,
    client_id: @oauth_app.uid,
    client_secret: @client_secret,
    scope: @oauth_app.scopes.to_s
  }
end

Then("the response body includes an access_token") do
  refute_nil parsed_body["access_token"]
end

Then('the response body includes a token_type of {string}') do |token_type|
  assert_equal token_type, parsed_body["token_type"]
end
