# frozen_string_literal: true

require "rails_helper"

# The admin editor (Admin > Customize > Text) is how Fomio app sentences are changed without an app release.
describe "Fomio app keys in the admin site-text editor" do
  fab!(:admin)

  before do
    DiscourseFomioAppLocales::CatalogBuilder.reset!
    SiteSetting.fomio_app_locales_enabled = true
    SiteSetting.fomio_app_locales = "en|ar|ru"
    sign_in(admin)
  end

  def search(query, locale)
    get "/admin/customize/site_texts.json", params: { q: query, locale: locale }
    expect(response.status).to eq(200)
    response.parsed_body["site_texts"].index_by { |text| text["id"] }
  end

  def save(key, value, locale)
    put "/admin/customize/site_texts/#{key}.json", params: { site_text: { value:, locale: } }
  end

  def catalog(locale)
    get "/fomio/app-locales/2/#{locale}.json"
    expect(response.status).to eq(200)
    response.parsed_body
  end

  it "lists Fomio keys with their interpolation keys, in English and in a locale's own text" do
    english = search("fomio_app.auth__signed_in", "en")
    expect(english["fomio_app.auth__signed_in"]).to include(
      "value" => "Signed in as %{name}.",
      "interpolation_keys" => ["name"],
    )
    arabic = search("fomio_app.auth__signed_in", "ar")
    expect(arabic["fomio_app.auth__signed_in"]["value"]).not_to eq("Signed in as %{name}.")
  end

  it "lists a plural Fomio key per category of the locale" do
    russian = search("fomio_app.post__like_count", "ru")
    expect(russian.keys).to include(
      "fomio_app.post__like_count.one",
      "fomio_app.post__like_count.few",
      "fomio_app.post__like_count.many",
      "fomio_app.post__like_count.other",
    )
  end

  it "saves an override that the app catalog then serves" do
    save("fomio_app.auth__signed_in", "Hello again, %{name}.", "en")
    expect(response.status).to eq(200)
    expect(catalog("en")["messages"]["auth.signed_in"]).to eq("Hello again, {name}.")
  end

  it "refuses an override with an unknown interpolation key" do
    save("fomio_app.auth__signed_in", "Hello %{someone}.", "en")
    expect(response.status).to eq(422)
    expect(catalog("en")["messages"]["auth.signed_in"]).to eq("Signed in as {name}.")
  end

  it "saves per-category plural overrides for a locale without its own text" do
    save("fomio_app.post__like_count.one", "Лайк %{count}", "ru")
    expect(response.status).to eq(200)
    save("fomio_app.post__like_count.other", "Лайков %{count}", "ru")
    expect(response.status).to eq(200)
    served = catalog("ru")
    expect(served["messages"]["post.like_count"]).to eq(
      "one" => "Лайк {count}",
      "other" => "Лайков {count}",
    )
    expect(served["fallback"]).not_to include("post.like_count")
  end
end
