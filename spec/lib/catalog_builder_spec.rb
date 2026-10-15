# frozen_string_literal: true

require "rails_helper"

describe DiscourseFomioAppLocales::CatalogBuilder do
  before do
    described_class.reset!
    SiteSetting.fomio_app_locales_enabled = true
    SiteSetting.fomio_app_locales = "en|ar"
  end

  after { described_class.reset! }

  def stub_maintained(locale, catalog)
    allow(described_class).to receive(:maintained).and_call_original
    allow(described_class).to receive(:maintained).with(locale).and_return(catalog)
  end

  def mutated(locale)
    described_class.maintained(locale).deep_dup.tap { |catalog| yield catalog["messages"], catalog }
  end

  def plural_key
    described_class.maintained("en")["messages"].find { |_, value| value.is_a?(Hash) }.first
  end

  def text_key(with_placeholder: false)
    described_class.maintained("en")["messages"]
      .find do |key, value|
        value.is_a?(String) && value.include?("{") == with_placeholder &&
          described_class.manifest.dig("keys", key, "source") == "fomio"
      end
      .first
  end

  it "defaults the app allowlist to English only" do
    SiteSetting.remove_override!(:fomio_app_locales)
    expect(described_class.allowed_locales).to eq(["en"])
    expect(described_class.offered?("ar")).to eq(false)
  end

  it "keeps the manifest and the maintained catalogs aligned and valid" do
    keys = described_class.manifest["keys"].keys
    expect(described_class.maintained("en")["messages"].keys).to match_array(keys)
    expect(described_class.maintained("ar")["messages"].keys).to match_array(keys)
    mapped = described_class.manifest["keys"].values.select { |e| e["source"] == "discourse" }
    expect(mapped).to all(include("discourse_key" => start_with("js.")))
    expect(described_class.maintained_valid?("en")).to eq(true)
    expect(described_class.maintained_valid?("ar")).to eq(true)
  end

  it "uses the maintained translation when the locale has no Discourse translation of its own" do
    entry = described_class.manifest["keys"].find { |_, e| e["source"] == "discourse" }
    key = entry.first
    allow(JsLocaleHelper).to receive(:translations_for).and_call_original
    allow(JsLocaleHelper).to receive(:translations_for).with("ar", no_fallback: true).and_return(
      "ar" => {
        "js" => {
        },
      },
    )
    catalog = described_class.build("ar")
    expect(catalog[:messages][key]).to eq(described_class.maintained("ar")["messages"][key])
  end

  it "replaces override values with markup, wrong placeholders, printf formats or raw keys" do
    mapped = described_class.manifest["keys"].select { |_, e| e["source"] == "discourse" }.first(4)
    english = described_class.maintained("en")["messages"]
    bad = ["<b>Back</b>", "Cancel %{count}", "Clear %@", "js.done"]
    mapped
      .zip(bad)
      .each { |(_, entry), value| TranslationOverride.upsert!("en", entry["discourse_key"], value) }
    messages = described_class.build("en")[:messages]
    mapped.each { |key, _| expect(messages[key]).to eq(english[key]) }
  end

  describe "maintained catalog validation" do
    mutations = {
      "a missing key" => ->(messages, spec) { messages.delete(spec.text_key) },
      "a missing plural form" => ->(messages, spec) { messages[spec.plural_key].delete("few") },
      "an extra plural form" => ->(messages, spec) do
        messages[spec.plural_key]["three"] = "{count}"
      end,
      "a plural without the count in other" => ->(messages, spec) do
        messages[spec.plural_key]["other"] = "كثير"
      end,
      "text where English has a plural" => ->(messages, spec) { messages[spec.plural_key] = "نص" },
      "a plural where English has text" => ->(messages, spec) do
        messages[spec.text_key] = { "other" => "نص" }
      end,
      "a changed placeholder" => ->(messages, spec) do
        key = spec.text_key(with_placeholder: true)
        messages[key] = messages[key].gsub(/\{[a-z][A-Za-z0-9_]*\}/, "{other_name}")
      end,
      "a dropped placeholder" => ->(messages, spec) do
        key = spec.text_key(with_placeholder: true)
        messages[key] = messages[key].gsub(/\{[a-z][A-Za-z0-9_]*\}/, "")
      end,
      "a control character" => ->(messages, spec) { messages[spec.text_key] = "نص\u0000" },
      "a tab character" => ->(messages, spec) { messages[spec.text_key] = "نص\tنص" },
      "a printf format" => ->(messages, spec) { messages[spec.text_key] = "نص %@" },
      "a positional printf format" => ->(messages, spec) { messages[spec.text_key] = "نص %1$d" },
      "Discourse interpolation" => ->(messages, spec) { messages[spec.text_key] = "نص %{name}" },
      "markup" => ->(messages, spec) { messages[spec.text_key] = "<b>نص</b>" },
      "a raw translation key" => ->(messages, spec) { messages[spec.text_key] = "js.hubs.all" },
      "nested braces" => ->(messages, spec) { messages[spec.text_key] = "نص {{x}}" },
      "an unbalanced brace" => ->(messages, spec) { messages[spec.text_key] = "نص }" },
      "an invalid placeholder name" => ->(messages, spec) do
        messages[spec.text_key] = "نص {Bad-1}"
      end,
      "a blank value" => ->(messages, spec) { messages[spec.text_key] = " \n " },
      "an overlong value" => ->(messages, spec) { messages[spec.text_key] = "ن" * 1201 },
      "a non-string value" => ->(messages, spec) { messages[spec.text_key] = 7 },
    }

    mutations.each do |name, mutate|
      it "does not offer or serve Arabic with #{name}" do
        stub_maintained("ar", mutated("ar") { |messages, _| mutate.call(messages, self) })
        expect(described_class.offered?("ar")).to eq(false)
        expect(described_class.build("ar")).to be_nil
        expect(described_class.build("en")).to be_present
      end
    end

    {
      "another schema" => ->(catalog) { catalog["schema"] = 2 },
      "another locale" => ->(catalog) { catalog["locale"] = "fr" },
      "an incomplete flag" => ->(catalog) { catalog["complete"] = false },
      "an invalid direction" => ->(catalog) { catalog["direction"] = "up" },
      "wrong plural categories" => ->(catalog) { catalog["plural_categories"] = %w[one other] },
    }.each do |name, mutate|
      it "does not offer Arabic with #{name}" do
        stub_maintained("ar", mutated("ar") { |_, catalog| mutate.call(catalog) })
        expect(described_class.offered?("ar")).to eq(false)
      end
    end

    it "does not offer a maintained catalog larger than the app accepts" do
      oversized =
        mutated("ar") do |messages, _|
          10_000.times { |i| messages["padding.key_#{i}"] = "ن" * 100 }
        end
      expect(oversized.to_json.bytesize).to be > 1_000_000
      stub_maintained("ar", oversized)
      expect(described_class.offered?("ar")).to eq(false)
    end

    it "does not serve a built payload larger than the app accepts" do
      allow(described_class).to receive(:maintained_valid?).and_return(true)
      stub_const(described_class::Validator, :MAX_PAYLOAD_BYTES, 10_000) do
        expect(described_class.build("ar")).to be_nil
      end
      expect(described_class.build("ar")).to be_present
    end

    it "offers nothing when the English reference is missing a key" do
      stub_maintained("en", mutated("en") { |messages, _| messages.delete("tab.home") })
      expect(described_class.build("en")).to be_nil
      expect(described_class.build("ar")).to be_nil
    end

    it "requires every plural form to keep the non-count placeholders" do
      key =
        described_class.maintained("en")["messages"]
          .find do |_, v|
            v.is_a?(Hash) && v.values.join.scan(/\{([a-z]\w*)\}/).flatten.uniq.size > 1
          end
          &.first
      skip "no plural with a non-count placeholder in this catalog" unless key
      stub_maintained("ar", mutated("ar") { |messages, _| messages[key]["two"] = "{count}" })
      expect(described_class.offered?("ar")).to eq(false)
    end
  end
end
