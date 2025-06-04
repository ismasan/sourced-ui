# frozen_string_literal: true

require 'json'

module Sourced
  module UI
    module Components
      module DatastarHelpers
        def _d
          @_d ||= Builder.new
        end

        # .on
        class Builder
          attr_reader :on

          def initialize
            @on = EventBuilder.new(self)
          end

          def to_h
            @on.to_data
          end
        end

        # .submit
        class EventBuilder
          def initialize(builder)
            @builder = builder
            @handler_specs = {}
          end

          def submit
            @handler_specs[:submit] ||= HandlerSpec.new(self, :submit)
          end

          def to_h
            @builder.to_h
          end

          def to_data
            @handler_specs.each.with_object({}) do |(event_name, spec), data|
              data["on-#{event_name}"] = spec.to_data
            end
          end
        end

        # .get(url, modifiers = {})
        class HandlerSpec
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

          def initialize(event_builder, event_name)
            @event_builder = event_builder
            @event_name = event_name
            @actions = []
          end

          def get(url, modifiers = {})
            modifiers = camelize(modifiers)
            @actions << Action.new(:get, url, modifiers)
            @event_builder
          end

          # %(@get('/sourced/correlation', {contentType: 'form'}))
          def to_data
            @actions.map(&:to_data).join('; ')
          end

          def camelize(hash)
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
