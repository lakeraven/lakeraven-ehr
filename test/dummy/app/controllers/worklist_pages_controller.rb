# frozen_string_literal: true

# See StaffPagesController — the second of the representative WebController
# pages the refusal-coverage contract walks.
class WorklistPagesController < Lakeraven::EHR::WebController
  before_action :require_authentication

  def index
    render plain: "worklist page"
  end
end
