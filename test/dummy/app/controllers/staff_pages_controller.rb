# frozen_string_literal: true

# A representative BROWSER PAGE inheriting the engine's WebController and its
# base `require_authentication`, exactly the way DashboardsController does.
#
# It exists (with WorklistPagesController) so the "an anonymous probe of ANY
# browser page leaves a refusal row" contract is proven against SEVERAL
# inheriting controllers, not just the one page that happens to be in-tree
# today — the defect being guarded against was a fix applied to one override
# while every other inheriting page stayed silent.
class StaffPagesController < Lakeraven::EHR::WebController
  before_action :require_authentication

  def index
    render plain: "staff page"
  end
end
