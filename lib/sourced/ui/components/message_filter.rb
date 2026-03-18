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
        FilterEntry = Hash[type: MessageTypeOrClass, attributes: Hash[String, String]]
        Filters = Array[FilterEntry]
      end

      class MessageFilter < Component
        # @param filters [Array<FilterEntry>, Array<Hash>] list of filter entries
        # @param available [Enumerator, Array] message classes available to add (for the dropdown)
        # @param action [String, nil] URL to POST to when "Add" is clicked (enables Datastar interaction)
        # @param submit [String, nil] URL to POST to when "Apply" is clicked
        def initialize(filters: [], available: Sourced::CCC::Message.registry.all, action: nil, submit: nil)
          @filters = Types::Filters.parse(filters)
          @available = available.to_a
          @action = action
          @submit = submit
        end

        def view_template
          div(id: 'message-filter') do
          form do
            @filters.each_with_index do |entry, index|
              hr if index > 0
              filter_row(index, entry)
            end

            if @available.any?
              hr if @filters.any?
              div(class: 'message-filter__add') do
                select(name: 'add_filter') do
                  @available.each do |msg_class|
                    option(value: msg_class.type) { msg_class.type }
                  end
                end
                if @action
                  button(type: 'button', data: _d.click.post(@action, content_type: 'form').to_h) { 'Add' }
                else
                  button(type: 'button') { 'Add' }
                end
              end
            end

            if @filters.any? && @submit
              div(class: 'message-filter__submit') do
                button(type: 'button', data: _d.click.post(@submit, content_type: 'form').to_h) { 'Apply filters' }
              end
            end
          end
          end
        end

        private

        def filter_row(index, entry)
          message_class = entry[:type]
          values = entry[:attributes]
          type = message_class.type

          input(type: 'hidden', name: "filters[#{index}][type]", value: type)
          div(class: 'message-filter__row') do
            div(class: 'message-filter__type') do
              span { type }
            end
            div(class: 'message-filter__attrs') do
              message_class.payload_attribute_names.each do |attr_name|
                label(class: 'message-filter__field') do
                  span(class: 'message-filter__field-name') { "#{attr_name}:" }
                  input(
                    type: 'text',
                    name: "filters[#{index}][attributes][#{attr_name}]",
                    value: values.fetch(attr_name.to_s, nil),
                    placeholder: attr_name.to_s
                  )
                end
              end
            end
          end
        end
      end
    end
  end
end
