# frozen_string_literal: true

require 'phlex'

module Sourced
  module UI
    module Dashboard
      class Layout < Phlex::HTML
        def view_template
          html do
            head do
              title { "Sourced Dashboard" }
              meta charset: "utf-8"
              meta name: "viewport", content: "width=device-width, initial-scale=1.0"
              link rel: "stylesheet", href: '/stylesheets/styles.css'
            end
            body do
              header do
                h1 { "Sourced Dashboard" }
              end
              main do
                yield if block_given?
              end
              footer do
                p { "© #{Time.now.year} Sourced UI" }
              end
            end
          end
        end
      end
    end
  end
end
