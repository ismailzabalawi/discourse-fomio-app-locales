# discourse-fomio-app-locales

Public, read-only interface catalogs for the Fomio native iOS app. The app shows English (bundled) until a
member chooses another language in Me › Language; it then downloads only that language from this endpoint.

Status: implemented with request specs on branch `fomio/app-locale-catalog` (based on Discourse d4296c5); the
specs also pass on the deployed revision 7b4f0970 (see the app repository's validation record). Released as
`v0.1.0` (below). Installation on the meta.fomio.app host is pending host access.

## Endpoints

| Route | Response |
| --- | --- |
| `GET /fomio/app-locales/1/index.json` | `{schema, default_locale: "en", locales: [{locale, name, native_name, direction, complete: true, revision}]}` |
| `GET /fomio/app-locales/1/<locale>.json` | `{schema, locale, direction, complete: true, plural_categories, messages, revision}`; 404 when not offered |

- Anonymous, also on login-required sites (like `ExtraLocalesController`): no member data, content or permissions.
- `ETag` = revision, `If-None-Match` → 304, `Cache-Control: public, max-age=300`.
- `default_locale` is always `"en"`; the app never auto-selects a language from it, the site's
  `default_locale`, a member's locale or the device language.
- A request's session or locale never changes the catalog.

## Which languages are offered

The site setting `fomio_app_locales` is this plugin's own allowlist. **It is separate from:**

- Discourse's web interface languages (`default_locale`, `allow_user_locale`, `set_locale_from_*`), and
- content translation/localization (`content_localization_*`, AI translation).

Changing any of those does not change what the app offers, and vice versa.

A locale is listed and served only when all of these hold:

1. it is in `fomio_app_locales` and in `LocaleSiteSetting.supported_locales`;
2. the app knows its plural rules (`CatalogBuilder::PLURAL_CATEGORIES`: en, ar, ja, ko, zh);
3. its maintained catalog `catalogs/<locale>.json` and the English reference pass validation (below);
4. the built payload passes the same validation and is at most 1,000,000 bytes.

The default is **`en` only**. Arabic (`ar.json`) is complete and validates, but it has not had native-speaker
review. Enabling it (`fomio_app_locales = en|ar`) is a product decision that requires that review first;
other languages also require a reviewed catalog and plural rules in both the app and this plugin.

## Validation (mirrors the app's `CatalogValidator`)

`CatalogBuilder::Validator` applies the rules in `Fomio/Localization/LocalizationCatalog.swift`:
schema 1, matching locale, `complete: true`, `ltr`/`rtl` direction, plural categories equal to the language's;
at most 6,000 messages; every manifest key present with the same kind as English (text or plural);
plural messages with exactly the language's forms, `{count}` in `other` when English uses it, non-count
placeholders in every form and no other placeholders; text placeholders equal to English; no blank values,
values over 1,200 characters, control characters other than `\n`, markup, `%{…}` or printf formats
(`%@`, `%d`, `%1$s`, …), raw translation keys, nested/unbalanced braces or invalid placeholder names.
`spec/lib/catalog_builder_spec.rb` mutates each rule, including an oversized catalog and payload.

Discourse-sourced keys (manifest `source: "discourse"`) use the locale's own client translation and that
locale's site-text override; a value failing validation is replaced by the maintained translation.
Topic/category terminology is Fomio-owned and is not mapped to Discourse keys pending product agreement;
site branding overrides (for example Byte/Hub) are not applied.

## Compatibility: member header on public responses

Discourse 7b4f0970 (deployed) sets `X-Discourse-Username` on every signed-in response in
`ApplicationController#set_current_user_for_logs`; d4296c5 only sets it on private/no-store responses
(`set_current_user_header_for_logs`, commit 6735ce7e2b7). The sample nginx config hides it only for
asset paths such as `/extra-locales/`, not `/fomio/`. `CatalogsController` therefore removes the header
in a prepended `after_action`, for 200 and 304. Request specs simulate the deployed callback.
The native app's catalog requests send no cookies or credentials (ephemeral session, cookies disabled).

## Keeping catalogs in sync with the app

`catalogs/manifest.json`, `catalogs/en.json` and `catalogs/ar.json` are copies of the app repository's
`Localization/manifest.json`, `Fomio/Resources/Localization/fomio-catalog-en.json` and
`Localization/catalogs/ar.json`. Copy all three together whenever the app's keys change, then run:

```
LOAD_PLUGINS=1 bin/rspec plugins/discourse-fomio-app-locales/spec
bundle exec rubocop plugins/discourse-fomio-app-locales
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
