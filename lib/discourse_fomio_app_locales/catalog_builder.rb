# frozen_string_literal: true

module ::DiscourseFomioAppLocales
  # Assembles the complete native interface catalog for one locale (wire schema 2, manifest source schema 3).
  #
  # Keys come from catalogs/manifest.json (generated from the Fomio app repository). Every key is a site text that
  # administrators can override in Admin > Customize > Text: a mapped key (source "discourse") is its
  # `discourse_key`; a Fomio key (source "fomio") is its `site_text_key` in config/locales/fomio_app.<locale>.yml.
  # Per key:
  # - English (`en`): the app's bundled English (catalogs/en.json), replaced by a valid `en` override.
  # - Other locales: (1) that locale's own override, when valid; (2) that locale's own translation: Discourse's
  #   client translation of `discourse_key` (no English fallback inside Discourse) or the plugin's
  #   fomio_app.<locale>.yml (read directly, so Discourse's locale fallback never fills it); (3) otherwise English
  #   as served, listed in `fallback`.
  # A plural override is the locale's per-category overrides (key.one, key.other, ...) over its own translation.
  # Overrides of keys whose English names a topic/category noun (manifest "terminology") are ignored until
  # `fomio_app_terminology_overrides` is on, so branding is adopted for whole sentences at once.
  #
  # Every served value passes the rules the app applies (Validator below); a value that fails is skipped for the
  # next candidate, so the catalog stays complete. Plural categories are Discourse's CLDR keys for the locale;
  # English fallback plurals keep English forms and are selected by the app with English rules. Mappings are
  # reviewed per key (manifest "verified").
  class CatalogBuilder
    SCHEMA = 2
    CATALOG_DIR = File.expand_path("../../catalogs", __dir__)
    LOCALE_DIR = File.expand_path("../../config/locales", __dir__)
    NAMESPACE = "fomio_app"
    ENGLISH_CATEGORIES = %w[one other].freeze

    def self.manifest
      @manifest ||= read("manifest.json")
    end

    def self.english
      @english ||= read("en.json")
    end

    # This plugin's own translations of Fomio keys for a locale, keyed without the namespace, or {} when there is
    # none.
    def self.site_texts(locale)
      @site_texts ||= {}
      @site_texts[locale] ||= begin
        path = File.join(LOCALE_DIR, "#{NAMESPACE}.#{locale}.yml")
        data = File.exist?(path) ? YAML.safe_load_file(path) : nil
        texts = data.is_a?(Hash) && data[locale].is_a?(Hash) ? data[locale][NAMESPACE] : nil
        texts.is_a?(Hash) ? texts : {}
      end
    end

    # Keys whose English names a topic/category noun, per noun.
    def self.terminology_keys
      @terminology_keys ||=
        (manifest.dig("terminology", "keys") || {}).transform_values { |keys| keys.to_set }
    end

    def self.read(name)
      JSON.parse(File.read(File.join(CATALOG_DIR, name), encoding: "UTF-8"))
    end

    def self.reset!
      @manifest = @english = @site_texts = @terminology_keys = @english_valid = nil
    end

    def self.language(locale)
      locale.to_s.split("_").first
    end

    # The bundled English reference must be complete and valid before anything is offered.
    def self.english_valid?
      return @english_valid unless @english_valid.nil?
      reference = english
      @english_valid =
        reference.is_a?(Hash) && reference["schema"] == SCHEMA && reference["locale"] == "en" &&
          reference["messages"].is_a?(Hash) &&
          manifest["keys"].keys.all? do |key|
            Validator.message_valid?(
              reference["messages"][key],
              reference["messages"][key],
              ENGLISH_CATEGORIES,
            )
          end
    end

    # Discourse's CLDR plural keys for the locale (config/locales/plurals.rb), or nil if it has none.
    def self.plural_categories(locale)
      keys = I18n.t("i18n.plural.keys", locale: locale, default: nil)
      keys.is_a?(Array) && keys.include?(:other) ? keys.map(&:to_s) : nil
    rescue I18n::InvalidLocale
      nil
    end

    # Locales in this plugin's own allowlist (`fomio_app_locales`) that Discourse supports, in the
    # configured order. It is separate from the web interface languages (`default_locale`,
    # `allow_user_locale`) and from content translation. No language is enabled automatically.
    def self.allowed_locales
      SiteSetting.fomio_app_locales.to_s.split("|").map(&:strip).reject(&:blank?).uniq &
        LocaleSiteSetting.supported_locales
    end

    def self.offered?(locale)
      allowed_locales.include?(locale) && english_valid? && plural_categories(locale).present?
    end

    def self.build(locale)
      return nil unless offered?(locale)
      new(locale).build
    end

    def initialize(locale)
      @locale = locale
      @categories = self.class.plural_categories(locale)
      @overridable = Set.new
    end

    def build
      reference = self.class.english["messages"]
      keys = self.class.manifest["keys"]
      english = @locale == "en" ? reference : self.class.new("en").english_messages
      messages = {}
      fallback = []
      counts = Hash.new(0)

      resolutions.each do |key, found|
        if found
          messages[key] = found[:value]
          counts[keys[key]["source"]] += 1
          counts["override"] += 1 if found[:override]
          counts["outdated"] += 1 if found[:outdated]
        else
          messages[key] = english[key]
          next if @locale == "en"
          fallback << key
          counts["english"] += 1
        end
      end

      return nil unless complete?(messages, reference, fallback)
      body = {
        schema: SCHEMA,
        locale: @locale,
        direction: Rtl::LOCALES.include?(@locale) ? "rtl" : "ltr",
        complete: true,
        plural_categories: @categories,
        fallback: fallback.sort,
        # For English, `discourse` and `overlay` count overridden keys; English is never a fallback of itself.
        coverage: {
          total: keys.size,
          discourse: counts["discourse"],
          overlay: counts["fomio"],
          english_fallback: counts["english"],
          override: counts["override"],
          outdated_override: counts["outdated"],
          terminology: terminology_coverage,
        },
        messages: messages,
      }
      body = body.merge(revision: Digest::SHA1.hexdigest(body.to_json)[0, 16])
      body.to_json.bytesize <= Validator::MAX_PAYLOAD_BYTES ? body : nil
    end

    # English as served: bundled English, with valid `en` overrides.
    def english_messages
      reference = self.class.english["messages"]
      resolutions.to_h { |key, found| [key, found ? found[:value] : reference[key]] }
    end

    private

    # Per key: {value:, override:, outdated:} for the locale's own text, or nil when English applies.
    def resolutions
      @resolutions ||= self.class.manifest["keys"].to_h { |key, entry| [key, resolve(key, entry)] }
    end

    def resolve(key, entry)
      reference = self.class.english["messages"][key]
      own = own_translation(entry)
      site_text = entry["source"] == "discourse" ? entry["discourse_key"] : entry["site_text_key"]
      if (override = override_for(site_text, reference, own))
        value = convert(override[:value], entry)
        if valid_translation?(value, reference)
          @overridable << key
          return { value:, override: true, outdated: override[:outdated] } unless gated?(key)
        end
      end
      # English's own text is the bundled reference; Discourse's English wording is never served for it.
      return nil if @locale == "en" || own.nil?
      value = convert(own, entry)
      valid_translation?(value, reference) ? { value: } : nil
    end

    # The locale's own translation, unconverted: Discourse's client translation or this plugin's site text.
    def own_translation(entry)
      if entry["source"] == "discourse"
        discourse_value(entry["discourse_key"])
      else
        self.class.site_texts(@locale)[entry["site_text_key"].delete_prefix("#{NAMESPACE}.")]
      end
    end

    # This locale's override of a site text (per category for plurals, over its own translation), or nil.
    def override_for(site_text, reference, own)
      if reference.is_a?(Hash)
        forms =
          @categories.filter_map { |form| (o = overrides["#{site_text}.#{form}"]) && [form, o] }
        return nil if forms.empty?
        base = own.is_a?(Hash) ? own.to_h { |form, text| [form.to_s, text] } : {}
        {
          value: base.merge(forms.to_h { |form, (text, _)| [form, text] }),
          outdated: forms.any? { |_, (_, status)| status == "outdated" },
        }
      elsif (text, status = overrides[site_text])
        { value: text, outdated: status == "outdated" }
      end
    end

    # This locale's own overrides only; another locale's override never applies here.
    def overrides
      @overrides ||=
        TranslationOverride
          .not_deprecated
          .where(locale: @locale)
          .pluck(:translation_key, :value, :status)
          .each_with_object({}) do |(key, value, status), found|
            next if key.end_with?("_MF")
            next unless key.start_with?("js.", "#{NAMESPACE}.")
            found[key] = [value, status.to_s]
          end
    end

    def gated?(key)
      !SiteSetting.fomio_app_terminology_overrides &&
        self.class.terminology_keys.values.any? { |keys| keys.include?(key) }
    end

    # Per noun: how many of its keys have a valid override in this locale, whether or not it is applied.
    def terminology_coverage
      groups =
        self.class.terminology_keys.to_h do |noun, keys|
          [noun, { total: keys.size, overridden: (keys & @overridable).size }]
        end
      { enabled: SiteSetting.fomio_app_terminology_overrides }.merge(groups)
    end

    def valid_translation?(value, reference)
      !value.nil? && Validator.message_valid?(value, reference, @categories)
    end

    def complete?(messages, reference, fallback)
      fallback_set = fallback.to_set
      self.class.manifest["keys"].keys.all? do |key|
        categories = fallback_set.include?(key) ? ENGLISH_CATEGORIES : @categories
        Validator.message_valid?(messages[key], reference[key], categories)
      end
    end

    def discourse_value(key)
      @translations ||= JsLocaleHelper.translations_for(@locale, no_fallback: true)
      @translations.dig(@locale.to_s, *key.split("."))
    end

    # %{name} -> {name}, renamed per the manifest entry. Plural values keep their forms.
    def convert(value, entry)
      renames = entry["placeholders"] || {}
      rename = ->(text) do
        text.gsub(/%\{([A-Za-z][A-Za-z0-9_]*)\}/) { "{#{renames.fetch($1, $1)}}" }
      end
      case value
      when String
        rename.call(value)
      when Hash
        value.to_h { |form, text| [form.to_s, text.is_a?(String) ? rename.call(text) : text] }
      end
    end

    # Mirrors CatalogValidator in the Fomio app (Fomio/Localization/LocalizationCatalog.swift).
    module Validator
      MAX_PAYLOAD_BYTES = 1_000_000
      MAX_MESSAGE_LENGTH = 1200
      MAX_MESSAGES = 6000
      KEY_PATTERN = /\A[a-z][a-z0-9_]*(\.[a-z0-9_]+)+\z/
      PLACEHOLDER = /\{([a-z][A-Za-z0-9_]*)\}/
      PRINTF = /%(\d+\$)?[@dlsf]/

      module_function

      # One message against its English reference: same kind; for plurals, forms within `categories`,
      # `other` present (with {count} when English uses it) and the allowed placeholders; safe text.
      def message_valid?(value, reference, categories)
        case reference
        when String
          value.is_a?(String) && text_valid?(value) &&
            placeholders(value) == placeholders(reference)
        when Hash
          return false unless value.is_a?(Hash) && value.key?("other")
          return false unless value.keys.all? { |form| categories.include?(form) }
          allowed =
            reference.values.select { |form| form.is_a?(String) }.map { |form| placeholders(form) }
          allowed = allowed.reduce(Set.new, :|)
          required = allowed - ["count"]
          forms_valid =
            value.values.all? do |form|
              form.is_a?(String) && text_valid?(form) && placeholders(form).subset?(allowed) &&
                required.subset?(placeholders(form))
            end
          forms_valid &&
            (allowed.exclude?("count") || placeholders(value["other"]).include?("count"))
        else
          false
        end
      end

      def text_valid?(value)
        return false if value.strip.empty? || value.length > MAX_MESSAGE_LENGTH
        return false if value.each_char.any? { |char| char != "\n" && char.match?(/\p{Cc}/) }
        return false if value.match?(%r{<\s*/?\s*[A-Za-z]})
        return false if value.include?("%{") || value.match?(PRINTF)
        return false if value.strip.match?(KEY_PATTERN)
        depth = 0
        value.each_char do |char|
          depth += 1 if char == "{"
          depth -= 1 if char == "}"
          return false if depth < 0 || depth > 1
        end
        return false if depth.nonzero?
        value.scan(/\{([^{}]*)\}/).flatten.all? { |name| name.match?(/\A[a-z][A-Za-z0-9_]*\z/) }
      end

      def placeholders(value)
        value.scan(PLACEHOLDER).flatten.to_set
      end
    end
  end
end
