# frozen_string_literal: true

require 'sourced/ui/components'

module Sourced
  module UI
    module Dashboard
      module Components
        # A message's name that opens its payload schema (MessageSchema) in a
        # floating dialog beside it, when clicked. The dialog is the layout's
        # popover (MessageSchema::Dialog): the click shows it by the name, with
        # message_schema.js's showMessageSchema (declared as an asset, which
        # keeps it there), and has Datastar fetch the schema into it from GET
        # /messages/schema. Being a popover, a click outside it, or Escape,
        # closes it.
        #
        # An app linking it installs the component (Dashboard::Service:
        # +component MessageName+); its layout links the script on every page.
        class MessageName < Component
          javascript 'messages/message_schema.js', path: 'message_schema.js'


          # The +data-+ attributes opening +type+'s schema in the dialog,
          # beside the element they're on (not below it, covering what's
          # under it), on a click or Enter: for elements other than the name,
          # such as a FlowDiagram's boxes.
          # @param helpers [#url] the request's helpers
          def self.opener(helpers, type)
            url = helpers.url("/messages/schema?type=#{Rack::Utils.escape(type)}")
            open = "showMessageSchema(el, 'side'); @get(#{url.to_json})"
            { 'message-type' => type, 'indicator:message-schema-loading' => true,
              'on:click' => open, 'on:keydown' => "evt.key === 'Enter' && (#{open})" }
          end

          # @param type [String] the message's type, as Sourced::Message.registry has it
          # @param text [String, nil] what to show; its class's name by default
          # @param kind [Symbol, String, nil] :command or :event, for its colour
          # @param classes [String, nil] its classes, instead of bm-message's
          def initialize(type:, text: nil, kind: nil, classes: nil)
            @type = type
            @text = text || Sourced::Message.registry[type]&.name || type
            @classes = classes || "bm-message bm-message--#{kind || 'event'}"
          end

          def view_template
            url = helpers.url("/messages/schema?type=#{Rack::Utils.escape(@type)}")
            button(type: 'button', class: "message-name #{@classes}", title: "#{@type}: its schema",
                   data: {
                     'message-type' => @type,
                     'indicator:message-schema-loading' => true,
                     'on:click' => "showMessageSchema(el); @get(#{url.to_json})"
                   }) do
              @text
            end
          end
        end

        # A message's payload, as its schema describes it: what MessageName's
        # dialog shows, patched into it by id.
        class MessageSchema < Component
          DIALOG = 'message-schema'
          BODY = 'message-schema-body'

          # The dialog the layout holds, empty, for MessageName to open: a
          # popover, dimmed while a schema loads.
          class Dialog < Component
            def view_template
              div(id: DIALOG, class: 'message-schema', popover: 'auto', role: 'dialog', aria: { label: 'Message schema' },
                  data: { 'class:is-loading' => '$messageSchemaLoading' }) do
                div(id: BODY) { p(class: 'message-schema__loading') { 'Loading…' } }
              end
            end
          end

          # What's patched in for a type no message has.
          class Missing < Component
            def view_template = div(id: BODY) { p(class: 'message-schema__loading') { 'No schema for this message.' } }
          end

          # @param klass [Class<Sourced::Message>]
          def initialize(klass)
            @klass = klass
            @schema = payload_schema(klass)
          end

          def view_template
            command = @klass < Sourced::Command
            div(id: BODY, class: 'message-schema__body') do
              header(class: 'message-schema__head') do
                span(class: "kind-badge kind-badge--#{command ? 'command' : 'event'}") { command ? 'command' : 'event' }
                strong(class: 'message-schema__name') { @klass.name.to_s.split('::').last(2).join('::') }
              end
              dl(class: 'message-schema__facts') do
                dt { 'Class' }
                dd { code { @klass.name.to_s } }
                dt { 'Type' }
                dd { code { @klass.type } }
              end
              render_fields
            end
          end

          private

          def render_fields
            fields = flatten(@schema)
            return p(class: 'muted message-schema__none') { 'No payload attributes.' } if fields.empty?

            table(class: 'message-schema__fields') do
              thead do
                tr do
                  th { 'Attribute' }
                  th { 'Type' }
                  th { '' }
                end
              end
              tbody do
                fields.each do |name, prop, required|
                  tr do
                    td do
                      code(class: 'message-schema__attr') { name }
                      p(class: 'message-schema__desc') { prop['description'] } if prop['description']
                    end
                    td do
                      type, nullable = type_of(prop)
                      code(class: 'message-schema__type') { type }
                      span(class: 'message-schema__nullable') { 'nullable' } if nullable
                    end
                    td(class: 'muted') { required ? 'required' : 'optional' }
                  end
                end
              end
            end
          end

          # [name, property, required] for each attribute, an object's own
          # attributes after it, as +address.city+, and those of an array's
          # objects as +lines[].sku+.
          def flatten(schema, prefix = nil, parent_required = true)
            required = Array(schema['required'])
            (schema['properties'] || {}).flat_map do |name, prop|
              path = prefix ? "#{prefix}.#{name}" : name
              own = [path, prop, parent_required && required.include?(name)]
              nested = if prop['properties']
                         flatten(prop, path, own.last)
                       elsif prop.dig('items', 'properties')
                         flatten(prop['items'], "#{path}[]", own.last)
                       else
                         []
                       end
              [own, *nested]
            end
          end

          # An attribute's type, and whether it may be null: a null among its
          # alternatives (+anyOf+, or a list of types) is said apart, so a
          # nullable string reads string, not null.
          def type_of(prop)
            label = ->(p) { Sourced::UI::Components::EventModel.type_label(p) }
            variants = prop['anyOf'] || prop['oneOf']
            if variants
              nulls, rest = variants.partition { it['type'] == 'null' }
              return [rest.map { label.(it) }.uniq.join(' | '), true] if nulls.any? && rest.any?
            end
            types = Array(prop['type'])
            return [label.(prop.merge('type' => types - ['null'])), true] if types.include?('null') && types.size > 1

            [label.(prop), false]
          end

          def payload_schema(klass)
            return {} unless klass.const_defined?(:Payload, false)

            payload = klass::Payload
            payload.respond_to?(:to_json_schema) ? payload.to_json_schema : {}
          rescue StandardError
            {}
          end
        end
      end
    end
  end
end
