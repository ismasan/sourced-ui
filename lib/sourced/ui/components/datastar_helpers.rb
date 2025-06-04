# frozen_string_literal: true

require 'json'

module Sourced
  module UI
    module Components
      module DatastarHelpers
        VERBS = %i[get post put delete patch].freeze

        HANDLERS = %i[
          click
          dblclick
          mousedown
          mouseup
          mouseover
          mouseout
          mousemove
          mouseenter
          mouseleave
          contextmenu
          keydown
          keyup
          keypress
          submit
          reset
          change
          input
          focus
          blur
          focusin
          focusout
          select
          invalid
          load
          unload
          beforeunload
          resize
          scroll
          error
          abort
          touchstart
          touchend
          touchmove
          touchcancel
          drag
          dragstart
          dragend
          dragover
          dragenter
          dragleave
          drop
          play
          pause
          ended
          volumechange
          timeupdate
          loadstart
          loadeddata
          loadedmetadata
          canplay
          canplaythrough
          seeking
          seeked
          stalled
          suspend
          waiting
          durationchange
          ratechange
          animationstart
          animationend
          animationiteration
          transitionstart
          transitionend
          transitionrun
          transitioncancel
          wheel
          copy
          cut
          paste
          online
          offline
          popstate
          hashchange
          storage
          message
          toggle
        ].freeze

        def _d
          Builder.new
        end

        Action = Data.define(:name, :url, :modifiers) do
          def to_data
            args = [%('#{url}')]
            if modifiers.any?
              mods = modifiers.map { |k, v| 
                v = "'#{v}'" if v.is_a?(String)
                "#{k}: #{v}" 
              }.join(', ')
              args << "{#{mods}}"
            end

            %(@#{name}(#{args.join(', ')}))
          end
        end

        # .on
        class Builder
          def initialize(event: :click, actions: {})
            @event = event
            @actions = actions
          end

          def __copy(
            event: @event, 
            actions: @actions.dup
          )
            self.class.new(event:, actions:)
          end

          def on
            __copy
          end

          HANDLERS.each do |event_name|
            define_method(event_name) do
              __copy(event: event_name)
            end
          end

          VERBS.each do |verb|
            define_method(verb) do |url, modifiers = {}|
              modifiers = camelize(modifiers)
              actions = @actions.dup
              actions[@event] = Action.new(verb, url, modifiers)
              __copy(actions:)
            end
          end

          def to_h
            @actions.each.with_object({}) do |(event_name, action), data|
              data["on-#{event_name}"] = action.to_data
            end
          end

          private def camelize(hash)
            hash.transform_keys do |key|
              # Convert key to string and split on underscores
              key.to_s.split('_').map.with_index do |word, index|
                # First word stays lowercase, subsequent words are capitalized
                index == 0 ? word.downcase : word.capitalize
              end.join
            end
          end
        end
      end
    end
  end
end
