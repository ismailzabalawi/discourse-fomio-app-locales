# discourse-fomio-app-locales

Public, read-only interface catalogs for the Fomio native iOS app. The app shows English (bundled) until a
member chooses another language in Me › Language; it then downloads only that language from this endpoint.

Status (2026-10-21): v0.1.1 (schema 1) is deployed on meta.fomio.app. **v0.3.0 is local only** (v0.2.0 will not be
deployed): every app sentence is a Discourse site text that administrators can override in Admin › Customize › Text.
Each language is assembled per key from that language's own override, its own translation (Discourse's for mapped
keys, this plugin's `config/locales/fomio_app.<locale>.yml` for Fomio keys) and English for anything missing or
invalid (`fallback`). The wire format is still schema 2, so existing app builds read it unchanged. Not published or
deployed.

## Endpoints (schema 2)

| Route | Response |
| --- | --- |
| `GET /fomio/app-locales/2/index.json` | `{schema, default_locale: "en", locales: [{locale, name, native_name, direction, complete: true, plural_categories, coverage, revision}]}` |
| `GET /fomio/app-locales/2/<locale>.json` | `{schema, locale, direction, complete: true, plural_categories, fallback, coverage, messages, revision}`; 404 when not offered |

- Anonymous, also on login-required sites; signed-in requests get the same body and no `X-Discourse-Username`.
- `ETag` = revision, `If-None-Match` (weak comparison) → 304, `Cache-Control: public, max-age=300`.
- `default_locale` is always `"en"`; the app never auto-selects a language.

## Assembly (catalogs/manifest.json, source schema 3)

Every key is a site text: a mapped key (`source: discourse`) is its `discourse_key`; a Fomio key (`source: fomio`) is
its `site_text_key`, `fomio_app.<key with "." written "__">` (flat, because some app keys are prefixes of others), for
example `fomio_app.auth__signed_in`. Search `fomio_app` in Admin › Customize › Text to list them.

- English: catalogs/en.json (the app's bundled English); a valid `en` override replaces it.
- Other locales, per key: (1) that locale's own override, when valid; (2) that locale's own translation: Discourse's
  client translation for a mapped key (`JsLocaleHelper.translations_for(locale, no_fallback: true)`), or
  `config/locales/fomio_app.<locale>.yml` for a Fomio key (read directly, so Discourse's locale fallback never fills
  it); (3) otherwise English as served, listed in `fallback`.
- Plural overrides are saved per category (`….one`, `….few`, `….other`) and merged over the locale's own forms; a
  locale with no forms of its own needs at least `other`.
- Overrides with status `deprecated` are ignored; `outdated` ones (the English sentence changed since) are served
  and counted in `coverage.outdated_override`. Another locale's override never applies.
- `coverage`: `discourse`, `overlay` (Fomio keys in the locale's own text), `english_fallback`, plus `override`,
  `outdated_override` and `terminology` (below). The app ignores fields it does not know.
- Plural categories: Discourse's CLDR keys (`I18n.t("i18n.plural.keys", locale:)`). A translated plural needs `other`
  and only those categories; fallback plurals keep English forms.
- `%{name}` → `{name}`, renamed per the manifest entry's `placeholders`. Values are validated like the app's
  `CatalogValidator`; an invalid translation is replaced by English, never served.
- `script/export_catalogs.rb coverage` reports translated vs English per supported locale; `... fixtures DIR locales`
  writes the app's Debug fixtures.

## Which languages are offered

The site setting `fomio_app_locales` is this plugin's own allowlist. **It is separate from:**

- Discourse's web interface languages (`default_locale`, `allow_user_locale`, `set_locale_from_*`), and
- content translation/localization (`content_localization_*`, AI translation).

Changing any of those does not change what the app offers, and vice versa.

A locale is listed and served only when all of these hold:

1. it is in `fomio_app_locales` and in `LocaleSiteSetting.supported_locales`;
2. Discourse has plural rules for it (`I18n.t("i18n.plural.keys")`); the app additionally lists it only if its own
   rules for the locale match those categories (all 49 Discourse client locales today);
3. the English reference is complete and valid, and the assembled catalog validates and is at most 1,000,000 bytes.

The default is **`en` only**; nothing is enabled automatically. Without `fomio_app.<locale>.yml` (or overrides) a
language is mostly English (Fomio's own copy); `coverage` says how much, and the app marks it "Partly translated".
Arabic (`fomio_app.ar.yml`) is fully covered but has not had native-speaker review. Adding a language to `fomio_app_locales` is a product
decision; for Arabic it requires that review first.

## Validation (mirrors the app's `CatalogValidator`)

`CatalogBuilder::Validator` checks every served message against the English reference: same kind (text or
plural); text placeholders equal to English; plural forms within the locale's categories (English categories for
fallback keys), `other` present with `{count}` when English uses it, non-count placeholders in every form and no
other placeholders; no blank values, values over 1,200 characters, control characters other than `\n`, markup,
`%{…}` or printf formats (`%@`, `%d`, `%1$s`, …), raw translation keys, nested/unbalanced braces or invalid
placeholder names. A translation that fails is replaced by English (listed in `fallback`); the catalog stays complete.
`spec/lib/catalog_builder_spec.rb` covers assembly, fallback, overrides, regional locales and each rule.

## Terminology (`fomio_app_terminology_overrides`, default off)

The manifest's `terminology.keys` lists every sentence whose English names a discussion or community (117 today).
While the setting is off, overrides of those sentences are ignored and the app keeps its own wording, so a
half-finished rebrand never reaches members. To brand the app (for example Byte/Hub), override each listed sentence
for each offered language (`coverage.terminology` reports, per noun, how many have a valid override), then turn the
setting on. Words are never substituted. The web's own topic/category overrides (`js.topic.*`, `js.category.*`) are
not mapped and do not affect the app.

## Compatibility: member header on public responses

Discourse 7b4f0970 (deployed) sets `X-Discourse-Username` on every signed-in response in
`ApplicationController#set_current_user_for_logs`; d4296c5 only sets it on private/no-store responses
(`set_current_user_header_for_logs`, commit 6735ce7e2b7). The sample nginx config hides it only for
asset paths such as `/extra-locales/`, not `/fomio/`. `CatalogsController` therefore removes the header
in a prepended `after_action`, for 200 and 304. Request specs simulate the deployed callback.
The native app's catalog requests send no cookies or credentials (ephemeral session, cookies disabled).

## Keeping catalogs in sync with the app

`catalogs/manifest.json`, `catalogs/en.json` and `config/locales/fomio_app.<locale>.yml` are generated from the app
repository (`Fomio/Resources/Localization/fomio-catalog-en.json`, `Localization/manifest.json`,
`Localization/catalogs/<locale>.json`); do not edit them here. Whenever the app's keys or translations change:

```
ruby <app>/Localization/tools/site-texts.rb sync plugins/discourse-fomio-app-locales
ruby <app>/Localization/tools/site-texts.rb check plugins/discourse-fomio-app-locales   # exit 1 when out of date
LOAD_PLUGINS=1 bin/rspec plugins/discourse-fomio-app-locales/spec
bundle exec rubocop plugins/discourse-fomio-app-locales
LOAD_PLUGINS=1 RAILS_ENV=test bin/rails runner plugins/discourse-fomio-app-locales/script/export_catalogs.rb fixtures <app>/Localization/fixtures en ar he ru pt_BR ja
LOAD_PLUGINS=1 RAILS_ENV=test bin/rails runner plugins/discourse-fomio-app-locales/script/export_catalogs.rb coverage
```

An app build whose keys are newer than the server's rejects the server catalog (missing keys) and keeps
English or its last good cache, so the server must be updated before or with an app release.

## Release and deployment

Follows the Fomio plugin supply-chain runbook (Fomio monorepo,
`apps/mobile/docs/20-implementation/discourse-plugin-supply-chain-runbook.md`): one standalone repository per
plugin whose root is `plugin.rb`, produced by `git subtree split`, installed pinned to a tag.

- Standalone repository: `https://github.com/ismailzabalawi/discourse-fomio-app-locales` (public: the server
  clones it without credentials; it contains no secrets), branch `main`, tag `v0.1.0`.
- Source: `git subtree split --prefix=plugins/discourse-fomio-app-locales` of branch `fomio/app-locale-catalog`
  in the Discourse reference checkout. The split commit is recorded in the app repository's validation record.

Install on the host that serves `meta.fomio.app` (a standard `/var/discourse` install), next to the existing
plugin clones in `containers/app.yml`:

```yaml
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          # (existing clones stay as they are)
          - git clone --branch v0.1.0 --depth 1 https://github.com/ismailzabalawi/discourse-fomio-app-locales.git
```

```
cd /var/discourse
cp containers/app.yml containers/app.yml.before-fomio-app-locales   # rollback copy
./launcher rebuild app
```

- No migrations, no writes, no new jobs. Defaults: `fomio_app_locales_enabled` true, `fomio_app_locales` `en`
  (English only). Do not change web interface languages or content translation settings.
- Health after rebuild: `/srv/status` returns `ok`; the generator meta still shows the expected Discourse
  revision; `/admin/plugins` lists `discourse-fomio-app-locales` 0.1.0.
- Verify (anonymous and signed in): index lists only `en`; `/1/en.json` 200 with `ETag` and
  `Cache-Control: public, max-age=300`; repeat with `If-None-Match` → 304; no `X-Discourse-Username`;
  `/1/ar.json`, `/2/index.json`, `/1/xx.json` → 404.
- Stop switch without a rebuild: set `fomio_app_locales_enabled` false (every route then 404s and the app keeps
  English). Rollback: restore `app.yml.before-fomio-app-locales` (or remove the clone line) and rebuild; there
  is no data to clean up.
- Adding a language (`fomio_app_locales = en|ar`) requires the recorded native-speaker review first.
