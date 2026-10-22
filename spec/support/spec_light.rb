# frozen_string_literal: true

# A small machine for the statechart and reactor page specs: a light that
# turns on, dims while on, and breaks for good.
class SpecLight < Sourced::Machine
  partition_by light_id: String
  message_prefix 'spec_light'

  On = State(:on)
  Off = State(:off)
  Broken = State(:broken)

  Install = Command(:install)
  Toggle = Command(:toggle)
  Dim = Command(:dim)
  Break = Command(:break)
  Dimmed = Event(:dimmed)

  initial do
    command Install => Off
  end

  state Off do
    command Toggle => On
    command Break => Broken
  end

  state On do
    command Toggle => Off
    command Dim do |_light, _cmd|
      event Dimmed
    end
    command Break => Broken
  end

  final Broken
end
