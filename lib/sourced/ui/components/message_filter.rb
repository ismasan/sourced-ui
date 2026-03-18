# frozen_string_literal: true

module Sourced
  module UI
    module Components
      module Types
        include Sourced::Types

        MessageClass = Types::Any.check('must be a Sourced::Message class') { |v|
          v.is_a?(Class) && v <= Sourced::CCC::Message
        }
        MessageTypeOrClass = MessageClass | String.build(Class) { |v| Sourced::CCC::Message.registry[v]}
        MessageFilters = Hash[MessageTypeOrClass, Hash[String, String]]
      end

      class MessageFilter < Component
        # @param filters [Hash] { message_class => { attr => value, ... }, ... }
        # @param available [Enumerator, Array] message classes available to add (for the dropdown)
        def initialize(filters: {}, available: Sourced::CCC::Message.registry.all)
          @filters = Types::MessageFilters.parse(filters)
          @available = available.to_a
        end

        def view_template
          form do
            @filters.each_with_index do |(message_class, attrs), index|
              hr if index > 0
              filter_row(message_class, attrs)
            end

            if @available.any?
              hr if @filters.any?
              div(class: 'message-filter__add') do
                select(name: 'add_filter') do
                  @available.each do |msg_class|
                    option(value: msg_class.type) { msg_class.type }
                  end
                end
                button(type: 'button') { 'Add' }
              end
            end
          end
        end

        private

        def filter_row(message_class, values)
          type = message_class.type

          div(class: 'message-filter__row') do
            label { type }
            message_class.payload_attribute_names.each do |attr_name|
              input(
                type: 'text',
                name: "filters[#{type}][#{attr_name}]",
                value: values.fetch(attr_name, nil),
                placeholder: attr_name.to_s
              )
            end
          end
        end
      end
    end
  end
end
