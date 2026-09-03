# frozen_string_literal: true
return if defined? YardPatch

require "commonmarker"

module YardPatch
  ASSETS = {
    "css/gfm-alerts.css" => <<~CSS,
      .markdown-alert {
        --alert-color: #59636e;

        margin: 1rem 0;
        padding: 0.5rem 1rem;
        color: inherit;
        border-left: 0.25rem solid var(--alert-color);
      }

      .markdown-alert > :first-child {
        margin-top: 0;
      }

      .markdown-alert > :last-child {
        margin-bottom: 0;
      }

      .markdown-alert-title {
        display: flex;
        align-items: center;
        gap: 0.5rem;

        margin: 0 0 0.5rem;
        padding: 0;

        color: var(--alert-color);
        font-weight: 500;
        line-height: 1;
      }

      /* Alert variants */

      .markdown-alert-note {
        --alert-color: #0969da;
      }

      .markdown-alert-tip {
        --alert-color: #1a7f37;
      }

      .markdown-alert-important {
        --alert-color: #8250df;
      }

      .markdown-alert-warning {
        --alert-color: #9a6700;
      }

      .markdown-alert-caution {
        --alert-color: #cf222e;
      }

      /* Simple icon approximation */

      .markdown-alert-title::before {
        display: inline-block;
        width: 1rem;
        text-align: center;
        font-size: 1rem;
        line-height: 1;
      }

      .markdown-alert-note .markdown-alert-title::before {
        content: "ⓘ";
      }

      .markdown-alert-tip .markdown-alert-title::before {
        content: "◆";
      }

      .markdown-alert-important .markdown-alert-title::before {
        content: "ⓘ";
      }

      .markdown-alert-warning .markdown-alert-title::before {
        content: "△";
      }

      .markdown-alert-caution .markdown-alert-title::before {
        content: "⊘";
      }
    CSS
  }.freeze

  module Layout
    def stylesheets = super + ASSETS.keys.grep(/\.css$/)
  end

  module FullDoc
    def file(name, ...) = ASSETS.fetch(name) { super }
  end

  module HtmlHelper
    def html_markup_markdown(text)
      Commonmarker.to_html(text, plugins: { syntax_highlighter: nil }, options: {
        render:    {
          unsafe:     true,
          hardbreaks: false,
        },
        extension: {
          tagfilter: false,
          table:     true,
          alerts:    true,
        },
      })
    end
  end
end

YARD::Templates::Engine
  .template(:default, :layout, :html)
  .prepend(YardPatch::Layout)

YARD::Templates::Engine
  .template(:default, :fulldoc, :html)
  .prepend(YardPatch::FullDoc)

YARD::Templates::Helpers::HtmlHelper
  .prepend(YardPatch::HtmlHelper)
