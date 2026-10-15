# frozen_string_literal: true

module ::DiscourseFomioAppLocales
  # Builds the complete native interface catalog for one locale.
  #
  # Keys come from catalogs/manifest.json (kept in sync with the Fomio app repository):
  # - source "discourse": the locale's own Discourse client translation of `discourse_key`, with that
  #   locale's site-text override applied. English is never used as a fallback for another locale, and
  #   a value that fails validation (markup, a raw key, unexpected placeholders) is replaced by the
  #   maintained translation for that locale.
  # - source "fomio": the maintained translation in catalogs/<locale>.json.
  #
  # The maintained catalog and every served message pass the same rules the app applies before it
  # activates a catalog (Validator below). A locale that fails is incomplete: not listed, not served.
  #
  # Topic/category nouns are not mapped to Discourse keys: the terminology policy is explicit in the
  # manifest and pending product agreement; site branding overrides such as Byte/Hub are not applied.
  class CatalogBuilder
    SCHEMA = 1
    CATALOG_DIR = File.expand_path("../../catalogs", __dir__)
    # Plural categories the native app can validate, by language. A language is offered only if listed.
    PLURAL_CATEGORIES = {
      "en" => %w[one other],
      "ar" => %w[zero one two few many other],
      "ja" => %w[other],
      "ko" => %w[other],
      "zh" => %w[other],
    }.freeze

    def self.manifest
      @manifest ||=
        JSON.parse(File.read(File.join(CATALOG_DIR, "manifest.json"), encoding: "UTF-8"))
    end

    def self.maintained(locale)
      @maintained ||= {}
      return @maintained[locale] if @maintained.key?(locale)
      path = File.join(CATALOG_DIR, "#{locale}.json")
      @maintained[locale] = File.exist?(path) ? JSON.parse(File.read(path, encoding: "UTF-8")) : nil
    end

    # Whether a maintained catalog passes the app's validation; memoized with the file it checks.
    def self.maintained_valid?(locale)
      @maintained_valid ||= {}
      return @maintained_valid[locale] if @maintained_valid.key?(locale)
      @maintained_valid[locale] = Validator.catalog_valid?(
        maintained(locale),
        locale,
        maintained("en"),
      )
    end

    def self.reset!
      @manifest = @maintained = @maintained_valid = nil
    end

    def self.language(locale)
      locale.to_s.split("_").first
    end

    # Locales in this plugin's own allowlist (`fomio_app_locales`) that Discourse supports, in the
    # configured order. It is separate from the web interface languages (`default_locale`,
    # `allow_user_locale`) and from content translation.
    def self.allowed_locales
      SiteSetting.fomio_app_locales.to_s.split("|").map(&:strip).reject(&:blank?).uniq &
        LocaleSiteSetting.supported_locales
    end

    def self.offered?(locale)
      allowed_locales.include?(locale) && PLURAL_CATEGORIES.key?(language(locale)) &&
        maintained_valid?("en") && maintained_valid?(locale)
    end

    def self.build(locale)
      return nil unless offered?(locale)
      new(locale).build
    end

    def initialize(locale)
      @locale = locale
    end

    def build
      reference = self.class.maintained("en")["messages"]
      own = self.class.maintained(@locale)["messages"]
      keys = self.class.manifest["keys"]
      overrides = discourse_overrides(keys)
      categories = PLURAL_CATEGORIES[self.class.language(@locale)]
      messages = {}

      keys.each do |key, entry|
        value = nil
        if entry["source"] == "discourse" && reference[key].is_a?(String)
          candidate = overrides[entry["discourse_key"]] || discourse_value(entry["discourse_key"])
          value = normalize(candidate) if candidate.is_a?(String)
          value = nil unless Validator.message_valid?(value, reference[key], categories)
        end
        value = own[key] if value.nil?
        return nil unless Validator.message_valid?(value, reference[key], categories)
        messages[key] = value
      end

      body = {
        schema: SCHEMA,
        locale: @locale,
        direction: Rtl::LOCALES.include?(@locale) ? "rtl" : "ltr",
        complete: true,
        plural_categories: categories,
        messages: messages,
      }
      body = body.merge(revision: Digest::SHA1.hexdigest(body.to_json)[0, 16])
      body.to_json.bytesize <= Validator::MAX_PAYLOAD_BYTES ? body : nil
    end

    private

    # This locale's own overrides only; another locale's override never applies here.
    def discourse_overrides(keys)
      wanted = keys.values.filter_map { |entry| entry["discourse_key"] }
      TranslationOverride
        .client_locales(@locale)
        .where(translation_key: wanted)
        .pluck(:translation_key, :value)
        .to_h
    end

    def discourse_value(key)
      translations = JsLocaleHelper.translations_for(@locale, no_fallback: true)
      translations.dig(@locale.to_s, *key.split("."))
    end

    def normalize(value)
      value.gsub(/%\{([a-z][A-Za-z0-9_]*)\}/) { "{#{$1}}" }
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

      # A maintained catalog file: size, metadata and every manifest key against the English reference.
      def catalog_valid?(catalog, locale, reference)
        return false unless catalog.is_a?(Hash) && reference.is_a?(Hash)
        return false if catalog.to_json.bytesize > MAX_PAYLOAD_BYTES
        categories = CatalogBuilder::PLURAL_CATEGORIES[CatalogBuilder.language(locale)]
        return false if categories.nil?
        return false if catalog["schema"] != CatalogBuilder::SCHEMA || catalog["locale"] != locale
        return false if catalog["complete"] != true || %w[ltr rtl].exclude?(catalog["direction"])
        return false if Array(catalog["plural_categories"]).sort != categories.sort
        messages = catalog["messages"]
        reference_messages = reference["messages"]
        return false unless messages.is_a?(Hash) && reference_messages.is_a?(Hash)
        return false if messages.size > MAX_MESSAGES
        CatalogBuilder.manifest["keys"].keys.all? do |key|
          message_valid?(messages[key], reference_messages[key], categories)
        end
      end

      # One message: the same kind as English, every plural form, allowed placeholders, safe text.
      def message_valid?(value, reference, categories)
        case reference
        when String
          value.is_a?(String) && text_valid?(value) &&
            placeholders(value) == placeholders(reference)
        when Hash
          return false unless value.is_a?(Hash) && value.keys.sort == categories.sort
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
