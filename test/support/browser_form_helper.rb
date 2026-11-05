# frozen_string_literal: true

# Presses a button on the page last rendered, the way a browser without
# JavaScript does: the button's form is sent as it stands, with the button's
# own name and value, to the button's formaction and formmethod if it has
# them (HTML's form submission algorithm, for the controls these pages use).
# The test environment leaves forgery protection off, so a token a browser
# would be refused with is never checked; with_forgery_protection turns it on,
# as production has it (#896).
module BrowserFormHelper
  def with_forgery_protection
    was = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = was
  end

  # fill: { "field name" => "value" } types into fields, or picks a radio
  # button by its value, before pressing.
  def press(label, fill: {})
    page = Nokogiri::HTML5(response.body)
    button = page.css("button, input[type=submit]").find { |b| button_label(b) == label }
    raise ArgumentError, "no button labelled #{label.inspect} on the page" unless button

    form = button["form"] ? page.at_css("form##{button['form']}") : button.ancestors("form").first
    raise ArgumentError, "the #{label.inspect} button is in no form" unless form

    pairs = form_data(form, button).map { |name, value| [ name, fill.fetch(name, value) ] }
    pairs += fill.reject { |name, _| pairs.any? { |pair| pair.first == name } }.to_a
    method = (button["formmethod"] || form["method"] || "get").downcase
    action = button["formaction"] || form["action"]
    body = URI.encode_www_form(pairs)
    if method == "get"
      get "#{action}?#{body}"
    else
      post action, params: body, headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end
  end

  private

  def button_label(button) = button.name == "button" ? button.text.strip : button["value"].to_s

  def form_data(form, submitter)
    form.css("input, select, textarea, button").filter_map { |control|
      next if control["name"].blank? || control.has_attribute?("disabled")

      control_pairs(control, submitter)
    }.flatten(1)
  end

  def control_pairs(control, submitter)
    case control.name
    when "button" then control == submitter ? [ [ control["name"], control["value"].to_s ] ] : []
    when "select" then selected_options(control).map { |o| [ control["name"], o["value"] || o.text ] }
    when "textarea" then [ [ control["name"], control.text ] ]
    else input_pairs(control, submitter)
    end
  end

  def input_pairs(input, submitter)
    case (input["type"] || "text").downcase
    when "submit", "image" then input == submitter ? [ [ input["name"], input["value"].to_s ] ] : []
    when "checkbox", "radio" then input.has_attribute?("checked") ? [ [ input["name"], input["value"] || "on" ] ] : []
    when "button", "reset", "file" then []
    else [ [ input["name"], input["value"].to_s ] ]
    end
  end

  def selected_options(select)
    chosen = select.css("option[selected]")
    return chosen.to_a if chosen.any? || select.has_attribute?("multiple")

    [ select.at_css("option") ].compact
  end
end
