# frozen_string_literal: true

require "rails_helper"

describe DiscourseFomioAppLocales::CatalogsController do
  let(:manifest_keys) { DiscourseFomioAppLocales::CatalogBuilder.manifest["keys"].keys }

  before do
    DiscourseFomioAppLocales::CatalogBuilder.reset!
    SiteSetting.fomio_app_locales_enabled = true
    SiteSetting.fomio_app_locales = "en|ar"
  end

  describe "#index" do
    it "lists only allowed, Discourse-supported locales with complete catalogs, anonymously" do
      SiteSetting.fomio_app_locales = "ar|fr|xx|en"
      get "/fomio/app-locales/2/index.json"

      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body["schema"]).to eq(2)
      # fr has no Fomio site texts but is a Discourse locale: offered with Discourse text and English
      # fallback. xx is not a Discourse locale.
      expect(body["locales"].map { |l| l["locale"] }).to eq(%w[ar fr en])
      arabic = body["locales"].first
      expect(arabic).to include(
        "direction" => "rtl",
        "complete" => true,
        "native_name" => "اللغة العربية",
        "plural_categories" => %w[zero one two few many other],
      )
      expect(arabic["coverage"]).to include("total" => manifest_keys.size)
      french = body["locales"].second
      expect(french["coverage"]["overlay"]).to eq(0)
      expect(french["coverage"]["english_fallback"]).to be > 0
      expect(response.headers["ETag"]).to be_present
    end

    it "does not depend on the site default locale or a signed-in member's locale" do
      SiteSetting.default_locale = "ar"
      SiteSetting.allow_user_locale = true
      sign_in(Fabricate(:user, locale: "ar"))
      get "/fomio/app-locales/2/index.json"
      expect(response.parsed_body["default_locale"]).to eq("en")
      expect(response.parsed_body["locales"].map { |l| l["locale"] }).to eq(%w[en ar])
    end

    it "is served anonymously on login-required sites" do
      SiteSetting.login_required = true
      get "/fomio/app-locales/2/index.json"
      expect(response.status).to eq(200)
    end

    it "returns 404 for another schema or when the plugin is disabled" do
      get "/fomio/app-locales/1/index.json"
      expect(response.status).to eq(404)
      get "/fomio/app-locales/3/index.json"
      expect(response.status).to eq(404)
      SiteSetting.fomio_app_locales_enabled = false
      get "/fomio/app-locales/2/index.json"
      expect(response.status).to eq(404)
    end
  end

  describe "#show" do
    it "serves a complete Arabic catalog with plural metadata, ETag and 304 revalidation" do
      get "/fomio/app-locales/2/ar.json"

      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body).to include(
        "schema" => 2,
        "locale" => "ar",
        "direction" => "rtl",
        "complete" => true,
      )
      expect(body["plural_categories"]).to eq(%w[zero one two few many other])
      expect(body["messages"].keys).to match_array(manifest_keys)
      expect(body["messages"]["discussion.replies"].keys).to match_array(
        %w[zero one two few many other],
      )
      # A mapped key resolves to Discourse's own Arabic translation.
      expect(body["messages"]["common.cancel"]).to eq(I18n.t("js.cancel", locale: :ar))
      etag = response.headers["ETag"]
      expect(etag).to eq(%("#{body["revision"]}"))
      expect(response.headers["Cache-Control"]).to include("public")

      get "/fomio/app-locales/2/ar.json", headers: { "If-None-Match" => etag }
      expect(response.status).to eq(304)
    end

    it "revalidates with the weak ETag a compressing proxy hands to clients (production finding 2026-10-16)" do
      get "/fomio/app-locales/2/en.json"
      revision = response.parsed_body["revision"]
      {
        %(W/"#{revision}") => 304,
        %("other", W/"#{revision}") => 304,
        "*" => 304,
        %(W/"other") => 200,
        %("#{revision}x") => 200,
      }.each do |header, status|
        get "/fomio/app-locales/2/en.json", headers: { "If-None-Match" => header }
        expect(response.status).to eq(status), "If-None-Match #{header}"
      end
    end

    it "reflects a changed site-text override for that locale in a new revision" do
      get "/fomio/app-locales/2/en.json"
      before = response.parsed_body

      TranslationOverride.upsert!("en", "js.cancel", "Never mind")
      get "/fomio/app-locales/2/en.json", headers: { "If-None-Match" => %("#{before["revision"]}") }

      expect(response.status).to eq(200)
      expect(response.parsed_body["messages"]["common.cancel"]).to eq("Never mind")
      expect(response.parsed_body["revision"]).not_to eq(before["revision"])
    end

    it "never applies another locale's override and rejects unsafe override values" do
      TranslationOverride.upsert!("en", "js.cancel", "Never mind")
      TranslationOverride.upsert!("ar", "js.done", "js.hubs.all")
      get "/fomio/app-locales/2/ar.json"

      messages = response.parsed_body["messages"]
      expect(messages["common.cancel"]).to eq(I18n.t("js.cancel", locale: :ar))
      # The invalid same-locale override is skipped; Discourse's own Arabic is used.
      expect(messages["common.done"]).to eq(
        JsLocaleHelper.translations_for("ar", no_fallback: true).dig("ar", "js", "done"),
      )
    end

    it "keeps topic/category terminology Fomio-owned despite branding overrides" do
      TranslationOverride.upsert!("en", "js.topic.create", "New Byte")
      TranslationOverride.upsert!("en", "js.category_title", "Hub")
      get "/fomio/app-locales/2/en.json"
      messages = response.parsed_body["messages"]
      expect(messages["composer.new_discussion"]).to eq("New discussion")
      expect(messages.values.grep(/Byte|Hub/)).to be_empty
    end

    it "returns 404 for locales that are not allowed, unsupported or malformed" do
      SiteSetting.fomio_app_locales = "en|xx"
      get "/fomio/app-locales/2/ar.json"
      expect(response.status).to eq(404)
      get "/fomio/app-locales/2/fr.json"
      expect(response.status).to eq(404)
      get "/fomio/app-locales/2/xx.json"
      expect(response.status).to eq(404)
      get "/fomio/app-locales/2/AR.json"
      expect(response.status).to eq(404)
    end

    it "does not use the requester's credentials or locale" do
      SiteSetting.allow_user_locale = true
      sign_in(Fabricate(:user, locale: "ar"))
      get "/fomio/app-locales/2/en.json"
      expect(response.parsed_body["locale"]).to eq("en")
      expect(response.parsed_body["messages"]["common.cancel"]).to eq("Cancel")
    end
  end

  describe "member headers on public responses" do
    fab!(:user) { Fabricate(:user, username: "catalog_member") }

    # Discourse 7b4f0970, the deployed revision, sets this header for every signed-in request.
    before do
      allow_any_instance_of(described_class).to receive(
        :set_current_user_for_logs,
      ).and_wrap_original do |original, *args|
        original.call(*args)
        controller = original.receiver
        member = controller.send(:current_user)
        controller.response.headers["X-Discourse-Username"] = member.username if member
      end
      sign_in(user)
    end

    it "never names the member on the index or a catalog, including 304 revalidations" do
      %w[/fomio/app-locales/2/index.json /fomio/app-locales/2/ar.json].each do |path|
        get path
        expect(response.status).to eq(200)
        expect(response.headers["Cache-Control"]).to include("public")
        expect(response.headers).not_to have_key("X-Discourse-Username")
        expect(response.body).not_to include(user.username)

        get path, headers: { "If-None-Match" => response.headers["ETag"] }
        expect(response.status).to eq(304)
        expect(response.headers).not_to have_key("X-Discourse-Username")
      end
    end

    it "removes the header after the stubbed callback really set it" do
      seen = nil
      allow_any_instance_of(described_class).to receive(
        :remove_member_headers,
      ).and_wrap_original do |original|
        seen = original.receiver.response.headers["X-Discourse-Username"]
        original.call
      end
      get "/fomio/app-locales/2/en.json"
      expect(seen).to eq(user.username)
      expect(response.headers).not_to have_key("X-Discourse-Username")
    end
  end
end
