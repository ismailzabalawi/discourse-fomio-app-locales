# frozen_string_literal: true

require "rails_helper"

describe DiscourseFomioAppLocales::CatalogBuilder do
  let(:keys) { described_class.manifest["keys"] }
  let(:english) { described_class.english["messages"] }
  let(:mapped) { keys.select { |_, e| e["source"] == "discourse" } }
  let(:fomio_keys) { keys.select { |_, e| e["source"] == "fomio" }.keys }

  before do
    described_class.reset!
    SiteSetting.fomio_app_locales_enabled = true
    SiteSetting.fomio_app_locales = "en|ar|ru|pt_BR|he|ja"
  end

  after { described_class.reset! }

  def stub_translations(locale, changes)
    real = JsLocaleHelper.translations_for(locale, no_fallback: true).deep_dup
    changes.each do |path, value|
      *parents, last = path.split(".")
      node = parents.reduce(real[locale]) { |h, k| h[k] ||= {} }
      value.nil? ? node.delete(last) : node[last] = value
    end
    allow(JsLocaleHelper).to receive(:translations_for).and_call_original
    allow(JsLocaleHelper).to receive(:translations_for).with(locale, no_fallback: true).and_return(
      real,
    )
  end

  def convert(value)
    rename = ->(text) { text.gsub(/%\{([a-z][A-Za-z0-9_]*)\}/, '{\\1}') }
    value.is_a?(Hash) ? value.transform_values(&rename) : rename.(value)
  end

  def site_text(locale, key)
    convert(described_class.site_texts(locale)[key.gsub(".", "__")])
  end

  def discourse(locale, key)
    JsLocaleHelper.translations_for(locale, no_fallback: true).dig(locale, *key.split("."))
  end

  describe "configuration" do
    it "defaults the app allowlist to English only and never enables a language by itself" do
      SiteSetting.remove_override!(:fomio_app_locales)
      expect(described_class.allowed_locales).to eq(["en"])
      expect(described_class.offered?("ar")).to eq(false)
    end

    it "keeps the manifest, English and the plugin's site texts aligned" do
      expect(english.keys).to match_array(keys.keys)
      expect(described_class.manifest["schema"]).to eq(3)
      keys.each do |key, entry|
        if entry["source"] == "fomio"
          expect(entry["site_text_key"]).to eq("fomio_app.#{key.gsub(".", "__")}"), key
        else
          expect(entry).not_to have_key("site_text_key"), key
        end
      end
      # Fomio keys only; English site texts are the bundled English in Discourse's %{name} syntax.
      site_english = described_class.site_texts("en")
      expect(site_english.keys).to match_array(fomio_keys.map { |key| key.gsub(".", "__") })
      fomio_keys.each do |key|
        expect(convert(site_english[key.gsub(".", "__")])).to eq(english[key]), key
      end
      arabic = described_class.site_texts("ar")
      expect(arabic.keys).to match_array(site_english.keys),
      "the Arabic site texts cover every Fomio key"
      categories = described_class.plural_categories("ar")
      fomio_keys.each do |key|
        value = convert(arabic[key.gsub(".", "__")])
        expect(described_class::Validator.message_valid?(value, english[key], categories)).to eq(
          true,
        ),
        key
        expect(value.keys).to match_array(categories), key if value.is_a?(Hash)
      end
    end

    it "lists every sentence naming a topic/category noun for the terminology setting" do
      terminology = described_class.manifest["terminology"]["keys"]
      plain = ->(value) { value.is_a?(Hash) ? value.values.join(" ") : value }
      expect(terminology["discussion"]).to match_array(
        english.select { |_, v| plain.(v).match?(/discussion/i) }.keys,
      )
      expect(terminology["community"]).to match_array(
        english.select { |_, v| plain.(v).match?(/communit(?:y|ies)/i) }.keys,
      )
      expect(SiteSetting.fomio_app_terminology_overrides).to eq(false)
    end

    it "maps only keys whose Discourse English is equivalent at this Discourse revision" do
      norm = ->(text) { text.gsub(/%?\{[A-Za-z0-9_]+\}/, "{}").downcase }
      mapped.each do |key, entry|
        source = discourse("en", entry["discourse_key"])
        expect(source).to be_present, "#{entry["discourse_key"]} exists"
        expect(entry["verified"]).to be_present, "#{key} records its semantic review"
        if english[key].is_a?(Hash)
          expect(source.keys.map(&:to_s)).to include("other")
          expect(norm.(source["other"].to_s)).to eq(norm.(english[key]["other"])), key
        else
          expect(norm.(source)).to eq(norm.(english[key])), key
        end
      end
    end

    it "keeps topic/category nouns Fomio-owned" do
      expect(mapped.values.map { |e| e["discourse_key"] }).not_to include(
        start_with("js.topic.create"),
        start_with("js.category"),
      )
    end

    it "takes plural categories from Discourse's CLDR rules and refuses locales without them" do
      expect(described_class.plural_categories("ar")).to eq(%w[zero one two few many other])
      expect(described_class.plural_categories("ru")).to eq(%w[one few many other])
      expect(described_class.plural_categories("he")).to eq(%w[one two many other])
      expect(described_class.plural_categories("pt_BR")).to eq(%w[one many other])
      expect(described_class.plural_categories("ja")).to eq(%w[other])
      allow(described_class).to receive(:plural_categories).and_call_original
      allow(described_class).to receive(:plural_categories).with("ru").and_return(nil)
      expect(described_class.build("ru")).to be_nil
    end
  end

  describe "assembly" do
    it "serves bundled English, applying only valid English overrides on mapped keys" do
      TranslationOverride.upsert!("en", "js.cancel", "Never mind")
      TranslationOverride.upsert!("en", "js.done", "Done %{count}")
      catalog = described_class.build("en")
      expect(catalog[:messages]["common.cancel"]).to eq("Never mind")
      expect(catalog[:messages]["common.done"]).to eq(english["common.done"])
      expect(catalog[:fallback]).to eq([])
      expect(catalog[:messages].except("common.cancel")).to eq(english.except("common.cancel"))
    end

    it "assembles Arabic from Discourse's Arabic, the plugin's site texts, and English for what neither covers" do
      stub_translations("ar", "js.more" => nil)
      catalog = described_class.build("ar")
      messages = catalog[:messages]
      expect(messages.keys).to match_array(keys.keys)
      expect(messages["common.cancel"]).to eq(I18n.t("js.cancel", locale: :ar))
      expect(messages["tab.communities"]).to eq(site_text("ar", "tab.communities"))
      # A mapped key Discourse's Arabic lacks: English fallback, listed as such (site texts never fill it).
      expect(catalog[:fallback]).to eq(["common.more"])
      expect(messages["common.more"]).to eq(english["common.more"])
      coverage = catalog[:coverage]
      expect(coverage[:discourse] + coverage[:overlay] + coverage[:english_fallback]).to eq(
        keys.size,
      )
      expect(coverage[:english_fallback]).to eq(catalog[:fallback].size)
      expect(catalog[:plural_categories]).to eq(%w[zero one two few many other])
      expect(catalog[:direction]).to eq("rtl")
    end

    it "serves a locale without site texts: Discourse text where mapped, English everywhere else" do
      catalog = described_class.build("ru")
      expect(catalog[:coverage][:overlay]).to eq(0)
      expect(catalog[:fallback]).to include(*fomio_keys)
      expect(catalog[:messages]["tab.communities"]).to eq(english["tab.communities"])
      expect(catalog[:messages]["common.cancel"]).to eq(discourse("ru", "js.cancel"))
      replies = catalog[:messages]["discussion.replies"]
      expect(replies.keys).to all(be_in(%w[one few many other]))
      expect(replies["other"]).to include("{count}")
      expect(catalog[:messages]["composer.style.heading"]).to include("{level}")
      expect(catalog[:direction]).to eq("ltr")
    end

    it "uses English, with English plural forms, for a missing or invalid Discourse translation" do
      stub_translations(
        "ru",
        "js.review.replies" => {
          "one" => "%{count} ответ",
          "two" => "%{count} x",
          "other" => "%{count} ответов",
        },
        "js.post.likes_popup.title" => {
          "one" => "лайк",
          "other" => "лайков",
        },
        "js.cancel" => "<b>Отмена</b>",
        "js.done" => nil,
      )
      catalog = described_class.build("ru")
      %w[discussion.replies post.likes common.cancel common.done].each do |key|
        expect(catalog[:fallback]).to include(key)
        expect(catalog[:messages][key]).to eq(english[key])
      end
      expect(catalog[:messages]["discussion.replies"].keys).to match_array(%w[one other])
    end

    it "accepts a Discourse plural without every category; the app then shows 'other', as Discourse does" do
      catalog = described_class.build("he")
      expect(catalog[:plural_categories]).to eq(%w[one two many other])
      likes = catalog[:messages]["post.likes"]
      expect(likes.keys).to include("other")
      expect(likes.keys).to all(be_in(%w[one two many other]))
    end

    it "prefers a valid same-locale override, skips an invalid one, never uses another locale's" do
      TranslationOverride.upsert!("ar", "js.cancel", "تراجع")
      TranslationOverride.upsert!("ar", "js.done", "js.hubs.all")
      TranslationOverride.upsert!("en", "js.more", "Further")
      catalog = described_class.build("ar")
      expect(catalog[:fallback]).to eq([])
      messages = catalog[:messages]
      expect(messages["common.cancel"]).to eq("تراجع")
      expect(messages["common.done"]).to eq(discourse("ar", "js.done"))
      expect(messages["common.more"]).to eq(I18n.t("js.more", locale: :ar))
    end

    it "uses English as served (including an English override) for a fallback" do
      stub_translations("ar", "js.more" => nil)
      TranslationOverride.upsert!("en", "js.more", "Further")
      expect(described_class.build("ar")[:messages]["common.more"]).to eq("Further")
    end

    it "keeps a regional locale's own translations without borrowing its parent language's" do
      stub_translations("pt_BR", "js.cancel" => nil)
      catalog = described_class.build("pt_BR")
      expect(catalog[:fallback]).to include("common.cancel")
      expect(catalog[:messages]["common.cancel"]).to eq(english["common.cancel"])
      expect(catalog[:messages]["common.cancel"]).not_to eq(discourse("pt", "js.cancel"))
    end

    it "replaces an invalid site text with English" do
      texts = described_class.site_texts("ar").merge("tab__communities" => "%{name} المجتمعات")
      allow(described_class).to receive(:site_texts).and_call_original
      allow(described_class).to receive(:site_texts).with("ar").and_return(texts)
      catalog = described_class.build("ar")
      expect(catalog[:fallback]).to include("tab.communities")
      expect(catalog[:messages]["tab.communities"]).to eq(english["tab.communities"])
    end

    it "offers nothing when the English reference is invalid" do
      broken = described_class.english.deep_dup.tap { |c| c["messages"].delete("tab.home") }
      allow(described_class).to receive(:english).and_return(broken)
      expect(described_class.build("en")).to be_nil
      expect(described_class.build("ar")).to be_nil
    end

    it "does not serve a payload larger than the app accepts" do
      stub_const(described_class::Validator, :MAX_PAYLOAD_BYTES, 10_000) do
        expect(described_class.build("ar")).to be_nil
      end
      expect(described_class.build("ar")).to be_present
    end
  end

  describe "site-text overrides" do
    it "applies a valid override of a Fomio key in its own locale only, skipping an invalid one" do
      TranslationOverride.upsert!("en", "fomio_app.access__denied__title", "No entry")
      TranslationOverride.upsert!("en", "fomio_app.auth__signed_in", "Welcome back")
      TranslationOverride.upsert!("ar", "fomio_app.app__name", "فوميو")
      english_catalog = described_class.build("en")
      expect(english_catalog[:messages]["access.denied.title"]).to eq("No entry")
      # Discourse accepts an override that drops %{name}; the plugin's validator rejects it.
      expect(english_catalog[:messages]["auth.signed_in"]).to eq(english["auth.signed_in"])
      expect(english_catalog[:messages]["app.name"]).to eq(english["app.name"])
      expect(english_catalog[:coverage]).to include(overlay: 1, override: 1, english_fallback: 0)

      arabic = described_class.build("ar")
      expect(arabic[:messages]["app.name"]).to eq("فوميو")
      # Arabic has its own site text, so the English override does not leak into it.
      expect(arabic[:messages]["access.denied.title"]).to eq(site_text("ar", "access.denied.title"))
    end

    it "fills an untranslated locale from its own override, and uses English as served otherwise" do
      TranslationOverride.upsert!("ru", "fomio_app.auth__signed_in", "Вы вошли как %{name}.")
      TranslationOverride.upsert!("en", "fomio_app.access__denied__title", "No entry")
      catalog = described_class.build("ru")
      expect(catalog[:messages]["auth.signed_in"]).to eq("Вы вошли как {name}.")
      expect(catalog[:fallback]).not_to include("auth.signed_in")
      expect(catalog[:fallback]).to include("access.denied.title")
      expect(catalog[:messages]["access.denied.title"]).to eq("No entry")
      expect(catalog[:coverage]).to include(overlay: 1, override: 1)
    end

    it "merges per-category plural overrides over the locale's own forms" do
      TranslationOverride.upsert!("ar", "fomio_app.post__like_count.few", "%{count} إعجابات")
      catalog = described_class.build("ar")
      expected = site_text("ar", "post.like_count").merge("few" => "{count} إعجابات")
      expect(catalog[:messages]["post.like_count"]).to eq(expected)

      # A locale without its own forms needs an override with 'other'; one form alone is not enough.
      TranslationOverride.upsert!("ru", "fomio_app.post__like_count.one", "Лайк %{count}")
      expect(described_class.build("ru")[:fallback]).to include("post.like_count")
      TranslationOverride.upsert!("ru", "fomio_app.post__like_count.other", "Лайков %{count}")
      expect(described_class.build("ru")[:messages]["post.like_count"]).to eq(
        "one" => "Лайк {count}",
        "other" => "Лайков {count}",
      )
    end

    it "merges plural overrides of a mapped key too" do
      TranslationOverride.upsert!("ru", "js.review.replies.many", "%{count} откликов")
      replies = described_class.build("ru")[:messages]["discussion.replies"]
      expect(replies["many"]).to eq("{count} откликов")
      expect(replies["one"]).to eq(convert(discourse("ru", "js.review.replies")["one"]))
    end

    it "ignores overrides of terminology sentences until the setting declares the set complete" do
      TranslationOverride.upsert!("en", "fomio_app.tab__communities", "Hubs")
      catalog = described_class.build("en")
      expect(catalog[:messages]["tab.communities"]).to eq(english["tab.communities"])
      terminology = catalog[:coverage][:terminology]
      expect(terminology[:enabled]).to eq(false)
      expect(terminology["community"]).to eq(
        total: described_class.terminology_keys["community"].size,
        overridden: 1,
      )

      SiteSetting.fomio_app_terminology_overrides = true
      catalog = described_class.build("en")
      expect(catalog[:messages]["tab.communities"]).to eq("Hubs")
      expect(catalog[:coverage][:terminology][:enabled]).to eq(true)
    end

    it "serves and counts an outdated override, and ignores a deprecated one" do
      outdated = TranslationOverride.upsert!("en", "fomio_app.access__denied__title", "No entry")
      outdated.update_column(:status, TranslationOverride.statuses[:outdated])
      deprecated = TranslationOverride.upsert!("en", "fomio_app.app__name", "Old name")
      deprecated.update_column(:status, TranslationOverride.statuses[:deprecated])
      catalog = described_class.build("en")
      expect(catalog[:messages]["access.denied.title"]).to eq("No entry")
      expect(catalog[:messages]["app.name"]).to eq(english["app.name"])
      expect(catalog[:coverage]).to include(override: 1, outdated_override: 1)
    end

    it "changes the revision when an override changes" do
      before = described_class.build("ar")[:revision]
      TranslationOverride.upsert!("ar", "fomio_app.app__name", "فوميو")
      expect(described_class.build("ar")[:revision]).not_to eq(before)
    end
  end

  describe "message validation" do
    let(:validator) { described_class::Validator }
    let(:arabic) { %w[zero one two few many other] }

    {
      "markup" => "<b>نص</b>",
      "a control character" => "نص\u0000",
      "a tab" => "نص\tنص",
      "a printf format" => "نص %@",
      "a positional printf format" => "نص %1$d",
      "Discourse interpolation" => "نص %{name}",
      "a raw translation key" => "js.hubs.all",
      "nested braces" => "نص {{x}}",
      "an unbalanced brace" => "نص }",
      "an invalid placeholder name" => "نص {Bad-1}",
      "a blank value" => " \n ",
      "an overlong value" => "ن" * 1201,
      "a non-string value" => 7,
      "an extra placeholder" => "نص {other}",
    }.each do |name, value|
      it "rejects #{name}" do
        expect(validator.message_valid?(value, "Cancel", arabic)).to eq(false)
      end
    end

    it "checks plural forms against the locale's categories, 'other' and {count}" do
      reference = { "one" => "{count} reply", "other" => "{count} replies" }
      expect(validator.message_valid?({ "other" => "{count} ردود" }, reference, arabic)).to eq(true)
      expect(validator.message_valid?({ "one" => "رد" }, reference, arabic)).to eq(false)
      expect(validator.message_valid?({ "other" => "ردود" }, reference, arabic)).to eq(false)
      expect(
        validator.message_valid?({ "dual" => "x", "other" => "{count}" }, reference, arabic),
      ).to eq(false)
      expect(
        validator.message_valid?(
          { "two" => "{count}", "other" => "{count}" },
          reference,
          %w[one other],
        ),
      ).to eq(false)
      expect(validator.message_valid?("{count} ردود", reference, arabic)).to eq(false)
    end
  end
end
