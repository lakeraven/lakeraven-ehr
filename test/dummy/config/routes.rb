Rails.application.routes.draw do
  mount Lakeraven::Ehr::Engine => "/lakeraven-ehr"
end
