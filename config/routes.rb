# frozen_string_literal: true

DiscourseFomioAppLocales::Engine.routes.draw do
  get "/:schema/index" => "catalogs#index", :constraints => { schema: /\d+/, format: :json }
  get "/:schema/:locale" => "catalogs#show",
      :constraints => {
        schema: /\d+/,
        locale: /[a-z]{2,3}(_[A-Za-z0-9]{2,8})?/,
        format: :json,
      }
end
