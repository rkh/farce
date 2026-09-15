# Publishing documentation

The Documentation workflow generates YARD on Ruby 4.0 after pushes to `main`
and tags. It publishes the complete site with `peaceiris/actions-gh-pages`:

* `main/` contains the main branch documentation.
* `version/{tag}/` contains documentation from each tag.
* `versions.json` records published versions, with main first and tags in order
  of publication, newest first.
* The site root redirects to main, or the newest published tag until main exists.

Every publication refreshes the visible version selector on all HTML pages,
including older releases. Selecting a version opens its documentation home page.
Links work under a GitHub project URL or a custom domain. Rebuilding a version
removes its obsolete pages and preserves the other versions.

## Enable publishing

After reviewing and merging the workflow, run Documentation on `main` or push
to `main`. The action creates `gh-pages` on its first successful run. In repository
Settings > Pages, select **Deploy from a branch**, **gh-pages**, and **/ (root)**.
The workflow needs permission to write repository contents.

The manual workflow can rebuild main or a tag that includes this workflow.
Existing tags are not automatically backfilled. Tags with slash-separated names
are supported, but a tag and its parent path cannot both hold documentation
(for example, `release` and `release/v1`). Conflicting paths fail before replacing
a published version.

Publishing runs share a concurrency group and queue up to GitHub's limit of
100 pending runs. This keeps site restoration and publication serialized.
GitHub also does not emit tag push events when more than three tags are pushed
at once. Push release tags individually.

## Local verification

```sh
bundle exec yard doc
GITHUB_REF_TYPE=branch GITHUB_REF_NAME=main ruby misc/docs/publish.rb yardoc tmp/pages
bundle exec ruby misc/docs/test_publish.rb
bundle exec rubocop
```

Open `tmp/pages/main/index.html` to inspect the generated site.
