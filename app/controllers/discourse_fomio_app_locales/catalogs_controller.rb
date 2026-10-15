# frozen_string_literal: true

module ::DiscourseFomioAppLocales
  # Public, read-only interface text. Like ExtraLocalesController it is served without a login or CSRF
  # token, also on login-required sites: it contains no user data, community content or permissions.
  class CatalogsController < ::ApplicationController
    requires_plugin PLUGIN_NAME

    skip_before_action :check_xhr,
                       :preload_json,
                       :redirect_to_login_if_required,
                       :redirect_to_profile_if_required,
                       :verify_authenticity_token

    # These responses are public and may be stored by shared caches. Discourse 7b4f0970 (deployed) adds
    # X-Discourse-Username to every signed-in response in set_current_user_for_logs; later revisions only
    # add it to private responses. Remove it here so a cached catalog never names a member.
    # Prepended so it runs after every inherited after_action.
    prepend_after_action :remove_member_headers

    def index
      ensure_schema!
      locales =
        CatalogBuilder.allowed_locales.filter_map do |locale|
          catalog = CatalogBuilder.build(locale)
          next unless catalog
          names =
            LocaleSiteSetting.language_names[locale] ||
              LocaleSiteSetting.language_names[CatalogBuilder.language(locale)] || {}
          {
            locale: locale,
            name: names["name"] || locale,
            native_name: names["nativeName"] || locale,
            direction: catalog[:direction],
            complete: true,
            revision: catalog[:revision],
          }
        end
      body = { schema: CatalogBuilder::SCHEMA, default_locale: "en", locales: locales }
      respond(body, Digest::SHA1.hexdigest(body.to_json)[0, 16])
    end

    def show
      ensure_schema!
      catalog = CatalogBuilder.build(params[:locale].to_s)
      raise Discourse::NotFound unless catalog
      respond(catalog, catalog[:revision])
    end

    private

    def remove_member_headers
      response.headers.delete("X-Discourse-Username")
    end

    def ensure_schema!
      raise Discourse::NotFound unless params[:schema].to_s == CatalogBuilder::SCHEMA.to_s
    end

    def respond(body, revision)
      etag = %("#{revision}")
      response.headers["ETag"] = etag
      response.headers["Cache-Control"] = "public, max-age=300"
      return head :not_modified if request.headers["If-None-Match"] == etag
      render json: body
    end
  end
end
