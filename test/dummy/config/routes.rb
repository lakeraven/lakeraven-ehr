Rails.application.routes.draw do
  mount Lakeraven::EHR::Engine => "/lakeraven-ehr"
end
