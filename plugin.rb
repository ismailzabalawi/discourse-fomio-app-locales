# frozen_string_literal: true

# name: discourse-fomio-app-locales
# about: Public, read-only interface catalogs for the Fomio native app (one locale per request)
# version: 0.1.0
# authors: Fomio
# url: https://meta.fomio.app

enabled_site_setting :fomio_app_locales_enabled

module ::DiscourseFomioAppLocales
  PLUGIN_NAME = "discourse-fomio-app-locales"
end

require_relative "lib/discourse_fomio_app_locales/engine"
require_relative "lib/discourse_fomio_app_locales/catalog_builder"

after_initialize do
  require_relative "app/controllers/discourse_fomio_app_locales/catalogs_controller"

  Discourse::Application.routes.append do
    mount ::DiscourseFomioAppLocales::Engine, at: "/fomio/app-locales"
  end
end
