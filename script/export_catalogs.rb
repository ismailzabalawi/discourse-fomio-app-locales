# frozen_string_literal: true

# Development tool (not loaded by plugin.rb). Assembles catalogs with the real builder, without the
# allowlist and without writing settings or data. Run inside a Discourse checkout:
#
#   LOAD_PLUGINS=1 RAILS_ENV=test bin/rails runner plugins/discourse-fomio-app-locales/script/export_catalogs.rb coverage
#   LOAD_PLUGINS=1 RAILS_ENV=test bin/rails runner plugins/discourse-fomio-app-locales/script/export_catalogs.rb fixtures OUT_DIR en ar he ru pt_BR ja
#
# coverage: JSON coverage for every Discourse-supported locale (translated vs English fallback).
# fixtures: one assembled catalog per locale plus index.json, for the app's Debug fixture transport.

builder = DiscourseFomioAppLocales::CatalogBuilder
mode, *args = ARGV
abort("English reference invalid") unless builder.english_valid?

assemble = ->(locale) { builder.plural_categories(locale) ? builder.new(locale).build : nil }

case mode
when "coverage"
  report =
    LocaleSiteSetting.supported_locales.sort.to_h do |locale|
      catalog = assemble.(locale)
      entry =
        if catalog
          {
            direction: catalog[:direction],
            plural_categories: catalog[:plural_categories],
            coverage: catalog[:coverage],
            site_texts: builder.site_texts(locale).any?,
          }
        else
          { unsupported: "no Discourse plural rules or invalid assembly" }
        end
      [locale, entry]
    end
  puts JSON.pretty_generate(
         {
           discourse: Discourse.git_version,
           mapped_keys: builder.manifest["keys"].count { |_, e| e["source"] == "discourse" },
           total_keys: builder.manifest["keys"].size,
           locales: report,
         },
       )
when "fixtures"
  out, *locales = args
  FileUtils.mkdir_p(out)
  names = LocaleSiteSetting.language_names
  index =
    locales.filter_map do |locale|
      catalog = assemble.(locale) or abort("cannot assemble #{locale}")
      File.write(File.join(out, "#{locale}.json"), JSON.pretty_generate(catalog) + "\n")
      name = names[locale] || names[builder.language(locale)] || {}
      {
        locale: locale,
        name: name["name"] || locale,
        native_name: name["nativeName"] || locale,
        direction: catalog[:direction],
        complete: true,
        plural_categories: catalog[:plural_categories],
        coverage: catalog[:coverage],
        revision: catalog[:revision],
      }
    end
  File.write(
    File.join(out, "index.json"),
    JSON.pretty_generate(schema: builder::SCHEMA, default_locale: "en", locales: index) + "\n",
  )
  puts "wrote #{locales.size} catalogs and index.json to #{out} (Discourse #{Discourse.git_version})"
else
  abort("usage: export_catalogs.rb coverage | fixtures OUT_DIR LOCALE...")
end
